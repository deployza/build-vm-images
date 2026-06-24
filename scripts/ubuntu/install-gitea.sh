#!/bin/bash
# Install Gitea (self-hosted Git service + web UI) as a systemd service.
#
# Gitea ships as a single static binary pulled from dl.gitea.com. Git itself is
# already installed by install-basics.sh; this script adds sqlite3 (Gitea's
# default embedded DB backend), a dedicated unprivileged `git` system user, the
# binary, and the systemd unit. Gitea is left enabled but NOT first-run
# configured — there is no baked app.ini, so the boot-time deploy step writes
# /etc/gitea/app.ini and completes install (admin user, DB, secrets never live
# in the image). See build-design.md §3.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y sqlite3
rm -rf /var/lib/apt/lists/*

# Dedicated unprivileged system user that owns the repositories and runs Gitea.
# --home + --create-home gives the user a real /home/git so Gitea can write
# ~/.ssh/authorized_keys (HOME=/home/git in gitea.service). --system users get
# no home dir by default, which makes RewriteAllPublicKeys() fail at MkdirAll.
adduser --system --shell /bin/bash --gecos 'Git Version Control' \
    --group --disabled-password --home /home/git --create-home git

# Fetch the pinned static binary.
curl -fsSL "https://dl.gitea.com/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-amd64" \
    -o /usr/local/bin/gitea
chmod 755 /usr/local/bin/gitea

# Gitea directory layout (build-design.md §3): work dir + config dir, owned by
# the git user. app.ini is written by the deploy step, not baked here.
mkdir -p /var/lib/gitea/custom /var/lib/gitea/data /var/lib/gitea/log
mkdir -p /etc/gitea

chown -R git:git /var/lib/gitea/
chown git:git /etc/gitea
chmod -R 750 /var/lib/gitea/
chmod 770 /etc/gitea

# systemd unit (installer-owned copy uploaded alongside the scripts).
cp "$SCRIPT_DIR/gitea.service" /etc/systemd/system/gitea.service
chmod 644 /etc/systemd/system/gitea.service

systemctl daemon-reload
systemctl enable gitea

gitea --version

echo "Gitea ${GITEA_VERSION} installed as a systemd service (web UI on :3000)"
echo "Check status with: systemctl status gitea"
