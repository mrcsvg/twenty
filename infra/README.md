# `infra/` — Twenty CRM on GCP

Self-hosted Twenty CRM on a single Compute Engine VM running docker-compose,
with a GitHub Actions CI/CD pipeline that redeploys on `push` to `main`.

See `docs/plans/2026-05-17-twenty-crm-gcp-deploy-design.md` for the full design
and rationale.

## Files

| File | Purpose |
|------|---------|
| `bootstrap.sh` | One-time GCP provisioning. Idempotent. Run from this dir. |
| `vm-startup.sh` | Runs on every VM boot. Installs docker, clones the fork, calls `deploy.sh`. |
| `deploy.sh` | Renders `.env` from Secret Manager + runs `docker compose up -d`. Called by `vm-startup.sh` and by the CI workflow. |
| `docker-compose.yml` | The stack: caddy, server, worker, postgres, redis. |
| `Caddyfile` | Reverse proxy + Let's Encrypt for `crm.<IP>.nip.io`. |
| `.env.template` | Documents the variables `docker-compose.yml` consumes. The real `.env` is generated on the VM and never committed. |

## Bootstrap (once, locally)

```bash
gcloud config set project s0c7-dev-crm-seed
cd infra
chmod +x bootstrap.sh vm-startup.sh deploy.sh
./bootstrap.sh
```

Prints the GitHub variable to set:

```bash
gh variable set GCP_PROJECT_NUMBER --body <NUMBER> --repo mrcsvg/twenty
```

After bootstrap, the VM is booting and the startup script is pulling images.
First boot takes 3-5 min. Track with:

```bash
gcloud compute ssh twenty-crm --tunnel-through-iap --zone=southamerica-east1-a \
  --command 'sudo journalctl -u google-startup-scripts.service -f'
```

When `/healthz` returns 200 on `https://crm.<IP>.nip.io/healthz`, open the URL
in a browser to see Twenty's signup page.

## Day-to-day

### Deploy
Push to `main` (or click "Run workflow" in the Actions tab). Done.

### SSH into the VM
```bash
gcloud compute ssh twenty-crm --tunnel-through-iap --zone=southamerica-east1-a
```

### View app logs
```bash
gcloud compute ssh twenty-crm --tunnel-through-iap --zone=southamerica-east1-a \
  --command 'cd /opt/twenty/infra && sudo docker compose logs -f --tail=200 server'
```

### Restart a single service
```bash
gcloud compute ssh twenty-crm --tunnel-through-iap --zone=southamerica-east1-a \
  --command 'cd /opt/twenty/infra && sudo docker compose restart server'
```

### Stop the VM to save cost (~$30/mo when stopped overnight)
```bash
gcloud compute instances stop twenty-crm --zone=southamerica-east1-a
# To resume:
gcloud compute instances start twenty-crm --zone=southamerica-east1-a
```
Startup script reruns on boot; stack comes back up automatically in ~1-2 min.

### Rotate a secret
```bash
NEW=$(openssl rand -hex 32)
printf '%s' "$NEW" | gcloud secrets versions add twenty-app-secret --data-file=-
gcloud compute ssh twenty-crm --tunnel-through-iap --zone=southamerica-east1-a \
  --command 'sudo bash /opt/twenty/infra/deploy.sh'
```
Rotating `twenty-pg-password` requires also updating the Postgres user —
remember to keep the running container's `POSTGRES_PASSWORD` in sync or it will
refuse the new connection string.

### Restore from a snapshot
```bash
gcloud compute snapshots list --filter='sourceDisk:twenty-crm'
# Find the snapshot you want, then:
gcloud compute disks create twenty-crm-restore --source-snapshot=<NAME> --zone=southamerica-east1-a
# Stop VM, detach old disk, attach restore disk, start VM.
```

### Pin to a specific Twenty version
Edit `.env.template`'s `TAG=` line and commit. The VM also reads it via the
generated `.env`; you'll need to also set it in Secret Manager or hard-code in
`docker-compose.yml`. The simplest: set `image: twentycrm/twenty:v0.40.0` directly.

## Cost

~$75/mo running 24/7; ~$30/mo if you stop the VM nights/weekends. See design doc
for the breakdown.

## Tear down

```bash
gcloud compute instances delete twenty-crm --zone=southamerica-east1-a --quiet
gcloud compute addresses delete twenty-crm-ip --region=southamerica-east1 --quiet
gcloud compute firewall-rules delete allow-http-twenty allow-https-twenty allow-iap-ssh --quiet
gcloud compute resource-policies delete twenty-daily --region=southamerica-east1 --quiet
gcloud secrets delete twenty-app-secret --quiet
gcloud secrets delete twenty-pg-password --quiet
gcloud iam service-accounts delete gh-deploy@s0c7-dev-crm-seed.iam.gserviceaccount.com --quiet
gcloud iam service-accounts delete twenty-vm@s0c7-dev-crm-seed.iam.gserviceaccount.com --quiet
gcloud iam workload-identity-pools delete github-actions-pool --location=global --quiet
```
