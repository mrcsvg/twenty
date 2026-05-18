#!/usr/bin/env bash
# One-time GCP provisioning for Twenty CRM deploy.
# Idempotent — re-running is a no-op.
#
# Prereqs:
#   - gcloud authenticated as a user with roles/owner on the project
#   - run from this directory (infra/) so vm-startup.sh is at ./vm-startup.sh

set -euo pipefail

# ---------- Config ----------
PROJECT_ID="${CIM_PROJECT_ID:-s0c7-dev-crm-seed}"
REGION="${CIM_REGION:-southamerica-east1}"
ZONE="${CIM_ZONE:-southamerica-east1-a}"
VM_NAME="${CIM_VM_NAME:-twenty-crm}"
MACHINE_TYPE="${CIM_MACHINE_TYPE:-e2-standard-2}"
DISK_SIZE_GB="${CIM_DISK_SIZE_GB:-50}"
DISK_TYPE="${CIM_DISK_TYPE:-pd-balanced}"
GH_REPO="${CIM_GH_REPO:-mrcsvg/twenty}"
WIF_POOL="github-actions-pool"
WIF_PROVIDER="github"
SA_DEPLOY="gh-deploy"
SA_VM="twenty-vm"
IP_NAME="${VM_NAME}-ip"
SECRET_APP="twenty-app-secret"
SECRET_PG="twenty-pg-password"

# ---------- Helpers ----------
log()   { printf '\033[1;36m▶ %s\033[0m\n' "$*" >&2; }
ok()    { printf '\033[1;32m✓ %s\033[0m\n' "$*" >&2; }
warn()  { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

require_cmd gcloud
require_cmd openssl

# Ensure the active project is the one we expect.
gcloud config set project "$PROJECT_ID" >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
ok "project: $PROJECT_ID (number: $PROJECT_NUMBER)"

# ---------- 1. Enable APIs ----------
log "enabling APIs (idempotent)"
gcloud services enable \
  compute.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  sts.googleapis.com \
  serviceusage.googleapis.com \
  --quiet
ok "APIs enabled"

# ---------- 2. Service accounts ----------
create_sa() {
  local name="$1" display="$2"
  if gcloud iam service-accounts describe "${name}@${PROJECT_ID}.iam.gserviceaccount.com" >/dev/null 2>&1; then
    ok "SA exists: $name"
  else
    gcloud iam service-accounts create "$name" --display-name="$display" --quiet
    ok "SA created: $name"
  fi
}

add_role() {
  local sa_email="$1" role="$2"
  # Only adds if missing — but `add-iam-policy-binding` is idempotent server-side.
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${sa_email}" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
}

create_sa "$SA_DEPLOY" "GitHub Actions deploy SA"
create_sa "$SA_VM"     "Twenty VM runtime SA"

SA_DEPLOY_EMAIL="${SA_DEPLOY}@${PROJECT_ID}.iam.gserviceaccount.com"
SA_VM_EMAIL="${SA_VM}@${PROJECT_ID}.iam.gserviceaccount.com"

log "binding roles"
add_role "$SA_DEPLOY_EMAIL" "roles/compute.instanceAdmin.v1"
add_role "$SA_DEPLOY_EMAIL" "roles/iap.tunnelResourceAccessor"
add_role "$SA_DEPLOY_EMAIL" "roles/secretmanager.secretAccessor"
# Needed so the deploy SA can SSH-as a Linux user on the VM via OS Login or metadata-based SSH.
add_role "$SA_DEPLOY_EMAIL" "roles/compute.osAdminLogin"
# Needed for `gcloud compute ssh/scp` to act as the SA attached to the VM.
gcloud iam service-accounts add-iam-policy-binding "$SA_VM_EMAIL" \
  --member="serviceAccount:${SA_DEPLOY_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --quiet >/dev/null

add_role "$SA_VM_EMAIL" "roles/secretmanager.secretAccessor"
add_role "$SA_VM_EMAIL" "roles/logging.logWriter"
ok "roles bound"

# ---------- 3. Workload Identity Federation ----------
log "configuring WIF pool + provider"
if ! gcloud iam workload-identity-pools describe "$WIF_POOL" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$WIF_POOL" \
    --location=global --display-name="GitHub Actions" --quiet
  ok "WIF pool created: $WIF_POOL"
else
  ok "WIF pool exists: $WIF_POOL"
fi

if ! gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
      --location=global --workload-identity-pool="$WIF_POOL" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
    --location=global --workload-identity-pool="$WIF_POOL" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository=='${GH_REPO}'" \
    --quiet
  ok "WIF provider created: $WIF_PROVIDER (bound to ${GH_REPO})"
else
  ok "WIF provider exists: $WIF_PROVIDER"
fi

# Bind the GitHub repo to impersonate the deploy SA.
gcloud iam service-accounts add-iam-policy-binding "$SA_DEPLOY_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GH_REPO}" \
  --quiet >/dev/null
ok "WIF binding: ${GH_REPO} → ${SA_DEPLOY_EMAIL}"

# ---------- 4. Secrets ----------
create_secret() {
  local name="$1" value="$2"
  if gcloud secrets describe "$name" >/dev/null 2>&1; then
    ok "secret exists: $name (keeping current value)"
  else
    printf '%s' "$value" | gcloud secrets create "$name" --replication-policy=automatic --data-file=- --quiet
    ok "secret created: $name"
  fi
}

create_secret "$SECRET_APP" "$(openssl rand -hex 32)"
create_secret "$SECRET_PG"  "$(openssl rand -hex 24)"

# Allow the VM SA to read these specific secrets (project-level role above also works,
# but per-secret binding is tighter).
for s in "$SECRET_APP" "$SECRET_PG"; do
  gcloud secrets add-iam-policy-binding "$s" \
    --member="serviceAccount:${SA_VM_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" \
    --quiet >/dev/null
done

# ---------- 5. Reserve external IP ----------
if gcloud compute addresses describe "$IP_NAME" --region="$REGION" >/dev/null 2>&1; then
  ok "static IP exists: $IP_NAME"
else
  gcloud compute addresses create "$IP_NAME" --region="$REGION" --quiet
  ok "static IP created: $IP_NAME"
fi
IP_ADDR="$(gcloud compute addresses describe "$IP_NAME" --region="$REGION" --format='value(address)')"
CRM_DOMAIN="crm.${IP_ADDR//./-}.nip.io"
ok "external IP: $IP_ADDR  (domain: $CRM_DOMAIN)"

# ---------- 6. Firewall ----------
ensure_fw() {
  local name="$1"; shift
  if gcloud compute firewall-rules describe "$name" >/dev/null 2>&1; then
    ok "firewall rule exists: $name"
  else
    gcloud compute firewall-rules create "$name" "$@" --quiet
    ok "firewall rule created: $name"
  fi
}

ensure_fw "allow-http-twenty"  --network=default --allow=tcp:80  --target-tags=http-server  --source-ranges=0.0.0.0/0
ensure_fw "allow-https-twenty" --network=default --allow=tcp:443 --target-tags=https-server --source-ranges=0.0.0.0/0
ensure_fw "allow-iap-ssh"      --network=default --allow=tcp:22  --source-ranges=35.235.240.0/20

# ---------- 7. VM ----------
log "ensuring VM $VM_NAME"
if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
  ok "VM exists: $VM_NAME (not modifying; delete to recreate)"
else
  gcloud compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size="${DISK_SIZE_GB}GB" --boot-disk-type="$DISK_TYPE" \
    --tags=http-server,https-server \
    --address="$IP_ADDR" \
    --service-account="$SA_VM_EMAIL" \
    --scopes=cloud-platform \
    --metadata=enable-oslogin=TRUE,twenty-fork-url=https://github.com/${GH_REPO}.git \
    --metadata-from-file=startup-script=./vm-startup.sh \
    --quiet
  ok "VM created: $VM_NAME"
fi

# Schedule a daily snapshot for the boot disk ($0.50/mo for incremental snapshots).
SNAPSHOT_POLICY="twenty-daily"
if ! gcloud compute resource-policies describe "$SNAPSHOT_POLICY" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute resource-policies create snapshot-schedule "$SNAPSHOT_POLICY" \
    --region="$REGION" \
    --max-retention-days=7 \
    --start-time=07:00 --daily-schedule \
    --on-source-disk-delete=apply-retention-policy \
    --quiet
  ok "snapshot policy created: $SNAPSHOT_POLICY (daily, 7d retention)"
else
  ok "snapshot policy exists: $SNAPSHOT_POLICY"
fi
gcloud compute disks add-resource-policies "$VM_NAME" \
  --zone="$ZONE" --resource-policies="$SNAPSHOT_POLICY" --quiet >/dev/null 2>&1 || true

# ---------- 8. Output for GitHub setup ----------
cat <<EOF

╔══════════════════════════════════════════════════════════════════╗
║                   BOOTSTRAP COMPLETE                             ║
╠══════════════════════════════════════════════════════════════════╣

  Project number      : $PROJECT_NUMBER
  WIF provider        : projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}
  Deploy SA           : $SA_DEPLOY_EMAIL
  VM SA               : $SA_VM_EMAIL
  External IP         : $IP_ADDR
  CRM domain          : https://$CRM_DOMAIN

  Set the following GitHub Variable on the fork (mrcsvg/twenty):

    gh variable set GCP_PROJECT_NUMBER --body $PROJECT_NUMBER --repo $GH_REPO

  No GitHub Secrets are required (auth is via WIF).

  The VM is booting and the startup script is running. First boot
  pulls Docker images and may take 3-5 minutes. Track progress:

    gcloud compute ssh $VM_NAME --tunnel-through-iap --zone=$ZONE \\
      --command 'sudo journalctl -u google-startup-scripts.service -f'

╚══════════════════════════════════════════════════════════════════╝
EOF
