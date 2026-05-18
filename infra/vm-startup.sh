#!/usr/bin/env bash
# Runs on every VM boot via the `startup-script` metadata key.
# Installs docker + git, clones (or refreshes) the fork, and calls deploy.sh.

set -euxo pipefail

REPO_DIR=/opt/twenty

# ---------- 1. Install docker + git if missing ----------
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
if ! command -v git >/dev/null 2>&1; then
  apt-get update && apt-get install -y git
fi
systemctl enable --now docker

# ---------- 2. Clone or refresh fork ----------
FORK_URL="$(curl -fsSH 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/twenty-fork-url)"

if [ ! -d "$REPO_DIR/.git" ]; then
  git clone --depth=1 "$FORK_URL" "$REPO_DIR"
else
  git -C "$REPO_DIR" fetch --depth=1 origin main
  git -C "$REPO_DIR" reset --hard origin/main
fi

# Make infra files writable by the OS Login deploy group so CI can update them
# without sudo on each file. The deploy.sh itself still runs with root via sudo.
chgrp -R google-sudoers "$REPO_DIR/infra" 2>/dev/null || true
chmod -R g+rw "$REPO_DIR/infra" 2>/dev/null || true

# ---------- 3. Hand off to deploy.sh ----------
bash "$REPO_DIR/infra/deploy.sh"
