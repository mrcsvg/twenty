# Twenty CRM on GCP — Deploy Design

**Date:** 2026-05-17
**Owner:** mrcsvg
**GCP project:** `s0c7-dev-crm-seed`
**GitHub fork:** `mrcsvg/twenty` (fork of `twentyhq/twenty`)
**Status:** Approved — ready for implementation

## Goal

Stand up Twenty CRM (`github.com/twentyhq/twenty`) running on GCP project
`s0c7-dev-crm-seed`, with a GitHub Actions CI/CD pipeline that redeploys on
push to `main`.

Success criteria:
1. CRM reachable over HTTPS and serving the Twenty UI
2. CI/CD pipeline in the fork redeploys on `main` push without manual steps

This is a **dev/discovery environment**. Choices favor simplicity and cost
over high availability.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ GitHub: mrcsvg/twenty (fork of twentyhq/twenty)                 │
│  └─ .github/workflows/deploy.yml                                │
│     on: push → main (paths: infra/**)                           │
│     ├─ auth via WIF (no JSON key)                               │
│     └─ SSH-to-VM via IAP, runs docker compose pull + up         │
└──────────────────────────┬──────────────────────────────────────┘
                           │ OIDC token exchange
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ GCP project: s0c7-dev-crm-seed                                  │
│  ├─ Workload Identity Pool + Provider (GitHub OIDC)             │
│  ├─ SA: gh-deploy@…    (compute admin, IAP tunnel, secrets)     │
│  ├─ SA: twenty-vm@…    (attached to VM, reads secrets, logs)    │
│  ├─ Secret Manager: twenty-app-secret, twenty-pg-password       │
│  └─ Compute Engine VM `twenty-crm`                              │
│      zone: southamerica-east1-a                                 │
│      machine: e2-standard-2 (2 vCPU, 8 GB), pd-balanced 50 GB   │
│      tags: http-server, https-server                            │
│      └─ Docker + compose stack:                                 │
│         ├─ caddy        (TLS via Let's Encrypt + nip.io)        │
│         ├─ twenty-server (twentycrm/twenty:latest)              │
│         ├─ twenty-worker (same image, worker command)           │
│         ├─ postgres:16                                          │
│         └─ redis:7-alpine                                       │
└─────────────────────────────────────────────────────────────────┘
```

## Decisions

| # | Decision | Why |
|---|----------|-----|
| 1 | Single VM with docker-compose | Cheapest path that runs the full stack. Dev env — HA not required. Vertical scaling is one `gcloud` command. |
| 2 | Fork `twentyhq/twenty` (not separate infra repo) | User chose fork to allow future code customization. Infra lives in `infra/` subdir; CI path-filters keep workflow lean. |
| 3 | `nip.io` + Caddy for HTTPS | Zero DNS config for dev. Caddy handles Let's Encrypt automatically. Production swap = update one env var. |
| 4 | Workload Identity Federation | No long-lived JSON keys in GitHub Secrets. Best practice per Google. |
| 5 | Push to `main` trigger, paths-filter on `infra/**` | Continuous deploy for fast iteration; avoids redeploys on doc-only commits. |
| 6 | Secrets in Secret Manager, not GitHub | App secrets stay in GCP; GitHub only holds the WIF binding. VM SA reads them at boot. |
| 7 | SSH only via IAP tunnel | Port 22 closed to internet. No bastion needed. |
| 8 | Postgres + Redis as containers (not Cloud SQL / Memorystore) | ~$30-50/mo savings; acceptable risk in dev. Migration to managed services is `pg_dump` + reconnect. |
| 9 | Snapshot disco diário | Cheap backup (~$0.50/mo). Restores entire VM in one command. |
| 10 | `concurrency: deploy-prod, cancel-in-progress: false` | Never cancel an in-flight deploy. Serializes deploys. |

## Cost estimate

São Paulo region (`southamerica-east1`), sustained-use discount applied,
egress excluded (typically <$5/mo in dev):

| Item | Monthly |
|---|---:|
| VM `e2-standard-2` 24/7 | ~$63 |
| `pd-balanced` 50 GB | ~$6.50 |
| External static IP | ~$3 |
| Secret Manager | <$1 |
| Daily snapshots (incremental) | ~$0.50 |
| **Total** | **~$75** |

Stop the VM nights/weekends (12h × 5d/week) and the bill drops to ~$30/mo.

## Repository layout

```
mrcsvg/twenty (fork)
├── (upstream twenty source — untouched)
├── infra/
│   ├── README.md                # how to bootstrap + operate
│   ├── bootstrap.sh             # one-time GCP setup, idempotent
│   ├── vm-startup.sh            # runs on VM boot (metadata startup-script)
│   ├── docker-compose.yml       # the stack
│   ├── Caddyfile                # reverse proxy + TLS config
│   └── .env.template            # non-secret defaults
└── .github/workflows/
    └── deploy.yml               # WIF auth → IAP SSH → compose pull/up
```

## Component details

### `infra/bootstrap.sh` (one-time, run locally with admin creds)

Idempotent. Re-running is a no-op. Steps:

1. `gcloud config set project s0c7-dev-crm-seed`
2. Enable APIs: `compute`, `iam`, `iamcredentials`, `secretmanager`, `iap`, `sts`
3. Create service accounts `gh-deploy` and `twenty-vm` with the roles above
4. Create Workload Identity Pool `github-actions-pool` + provider `github`
5. Bind `gh-deploy` SA to `attribute.repository=mrcsvg/twenty`
6. Generate random secrets and store in Secret Manager
7. Reserve static external IP `twenty-crm-ip`
8. Create firewall rules: allow 80/443 from `0.0.0.0/0` with tag `http-server`/`https-server`; allow 22 only from IAP range `35.235.240.0/20`
9. Create VM `twenty-crm` with `vm-startup.sh` as `startup-script` metadata, attaching `twenty-vm` SA
10. Print the WIF provider resource name and project number — these go into GitHub Variables

### `infra/vm-startup.sh` (runs on every VM boot)

```bash
#!/bin/bash
set -euxo pipefail

# Install docker + git if missing
which docker || apt-get update && apt-get install -y docker.io docker-compose-plugin git

# Clone or refresh fork
if [ ! -d /opt/twenty ]; then
  git clone https://github.com/mrcsvg/twenty.git /opt/twenty
else
  git -C /opt/twenty pull --ff-only
fi

cd /opt/twenty/infra

# Build .env from Secret Manager + computed values
IP=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
CRM_DOMAIN="crm.${IP//./-}.nip.io"

APP_SECRET=$(gcloud secrets versions access latest --secret=twenty-app-secret)
PG_PASSWORD=$(gcloud secrets versions access latest --secret=twenty-pg-password)

cat > .env <<EOF
CRM_DOMAIN=${CRM_DOMAIN}
APP_SECRET=${APP_SECRET}
PG_PASSWORD=${PG_PASSWORD}
EOF
chmod 600 .env

docker compose pull
docker compose up -d --remove-orphans
```

### `infra/docker-compose.yml`

See Section 3 of the brainstorm transcript. Five services: `caddy`, `server`,
`worker`, `db`, `redis`. Named volumes for persistence. Healthcheck on db so
server waits for it.

### `infra/Caddyfile`

```
{$CRM_DOMAIN} {
    reverse_proxy server:3000
    encode gzip
}
```

Caddy automatically obtains a Let's Encrypt cert for `crm.<IP>.nip.io` on first
request.

### `.github/workflows/deploy.yml`

Triggers on push to `main` when `infra/**` or the workflow file changes, plus
`workflow_dispatch` for manual reruns. Uses WIF for auth, syncs `infra/` via
`gcloud compute scp --tunnel-through-iap`, SSHes via IAP to run
`docker compose pull && up -d`, then curls `/healthz` until it passes (max 2.5
min).

`concurrency: deploy-prod, cancel-in-progress: false` ensures deploys are
serialized and never killed mid-flight.

GitHub Variables required (not secrets — they're public):
- `GCP_PROJECT_NUMBER` (numeric, from `gcloud projects describe`)

GitHub Secrets: **none**.

## Out of scope (parking lot)

Things explicitly **not** in this design — defer until needed:

- Cloud SQL / Memorystore (managed Postgres / Redis)
- Multi-environment (staging vs prod)
- PR preview environments
- HA / multi-zone
- Backup beyond disk snapshots (e.g. logical pg_dump to GCS)
- Monitoring beyond Cloud Logging default
- Custom domain (swap `CRM_DOMAIN` env var when needed)
- VPC / private networking (VM is on default network)
- Vertical / horizontal autoscaling
- Cost-cap automation (auto-stop outside business hours)

## Open risks

1. **`twentycrm/twenty:latest` tag drift.** Latest image is reproduced as
   "whatever is current at deploy time." For a stable dev env this is fine; for
   prod, pin to a digest. Not changing now — flagged for later.
2. **Single VM = single point of failure.** Accepted for dev.
3. **`startup-script` runs on every boot, including manual restarts.** It's
   idempotent (`git pull --ff-only`, `compose up -d`), so restarts are safe but
   may pull newer images than expected. Mitigation: pin image tag in compose.
4. **Cloud Run Job dispatch from CI uses `gcloud ssh` over IAP.** If IAP API
   has an outage, no deploys. Not a real concern for dev.

## Verification plan

Post-implementation, these must pass:

1. `gcloud compute instances describe twenty-crm` → status `RUNNING`
2. `gcloud compute ssh twenty-crm --tunnel-through-iap -- 'docker compose ps'` → all 5 services `Up (healthy)`
3. `curl -fsS https://crm.<IP>.nip.io/healthz` → HTTP 200
4. Browser loads `https://crm.<IP>.nip.io` and shows Twenty signup page
5. Push a trivial change to `infra/Caddyfile` on `main` → GitHub Actions run completes green within ~3 min, and the change is reflected on the live site
