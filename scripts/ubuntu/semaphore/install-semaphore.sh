#!/bin/bash
# Install Semaphore UI (a web UI and API for running Ansible) as a systemd service.
# ops flavor.
#
# WHAT THIS BAKES IS ONLY THE MECHANISM: the binary, a `semaphore` user, the
# data directory and the unit. There is NO /etc/semaphore/config.json. That
# file holds three secrets (cookie_hash, cookie_encryption,
# access_key_encryption — the last encrypts every SSH key and password stored
# in Semaphore), and secrets never live in an image. The deploy step writes it
# and creates the admin user. /etc/semaphore/config.json.example beside it shows
# the shape.
#
# THE UNIT IS INSTALLED BUT NOT ENABLED — same reasoning as
# install-cloud-sql-proxy.sh. With no config file Semaphore exits non-zero at
# once, so an enabled unit would boot every VM into restart backoff. Turning it
# on is at the bottom of this file.
#
# THE .deb FROM THE GITHUB RELEASE, and specifically the semaphore_community_*
# asset (see versions.env). Semaphore has no apt repo. The deb installs a
# single static binary at /usr/bin/semaphore and depends on git, which
# install-basics.sh already put down. It installs no unit and no user, which is
# why both are here. No checksum step, matching the otelcol /
# cloud-sql-proxy installs.
#
# ANSIBLE IS NOT INSTALLED HERE. install-ansible.sh is its own provisioner line
# (no installer calls another). Semaphore only needs `ansible-playbook` on PATH
# when a task runs, not at bake time.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

export DEBIAN_FRONTEND=noninteractive

SEMAPHORE_DEB="semaphore_community_${SEMAPHORE_VERSION}_linux_amd64.deb"
SEMAPHORE_URL="https://github.com/semaphoreui/semaphore/releases/download/v${SEMAPHORE_VERSION}/${SEMAPHORE_DEB}"
SEMAPHORE_CONF_DIR=/etc/semaphore
SEMAPHORE_DATA_DIR=/var/lib/semaphore


echo "== Install the Semaphore ${SEMAPHORE_VERSION} package =="
wget -q "$SEMAPHORE_URL" -O "/tmp/${SEMAPHORE_DEB}"
apt-get update -y
# `apt-get install ./file.deb`, not `dpkg -i`: apt resolves the deb's own
# dependencies (git) instead of leaving a half-configured package.
apt-get install -y "/tmp/${SEMAPHORE_DEB}"
rm -f "/tmp/${SEMAPHORE_DEB}"
rm -rf /var/lib/apt/lists/*


echo "== Create the semaphore service user =="
# A REAL HOME, unlike csqlproxy/otelcol. Semaphore runs ansible-playbook as this
# user, and Ansible writes ~/.ansible (its tmp dir, collections, galaxy cache)
# and ssh writes ~/.ssh/known_hosts. A home-less system user makes every task
# fail on its first write there.
adduser --system --group --shell /usr/sbin/nologin \
    --gecos 'Semaphore UI' --disabled-password \
    --home /home/semaphore --create-home semaphore


echo "== Directory layout =="
# The SQLite database, and the tmp_path where Semaphore clones each project's
# playbook repository. Both are under /var/lib rather than /tmp: the unit has
# PrivateTmp=, and a clone that vanishes on every restart is re-downloaded on
# every task.
install -d -o semaphore -g semaphore -m 750 "$SEMAPHORE_DATA_DIR" "$SEMAPHORE_DATA_DIR/tmp"

# 750 root:semaphore: the service reads its config; only root writes it.
install -d -o root -g semaphore -m 750 "$SEMAPHORE_CONF_DIR"
install -o root -g semaphore -m 640 \
    "$SCRIPT_DIR/config.example.json" "$SEMAPHORE_CONF_DIR/config.json.example"


echo "== Install the systemd unit (NOT enabled) =="
install -m 644 "$SCRIPT_DIR/semaphore.service" /etc/systemd/system/semaphore.service
systemctl daemon-reload
# NO `systemctl enable` — see the header.

semaphore version

cat <<'EOF'
Semaphore installed. It is INERT: there is no /etc/semaphore/config.json and the
unit is installed but not enabled.

Turning it on (deploy time):

  # 1. The config, with freshly generated secrets. Start from the example:
  #      /etc/semaphore/config.json.example
  #    cookie_hash / cookie_encryption / access_key_encryption are each
  #      head -c32 /dev/urandom | base64
  #    Keep access_key_encryption somewhere durable: losing it makes every
  #    stored SSH key and password in the database unreadable.
  install -o root -g semaphore -m 640 config.json /etc/semaphore/config.json

  # 2. The first admin user (runs against the SQLite file, as the service user).
  sudo -u semaphore semaphore user add --admin \
    --login admin --name Admin --email admin@example.com --password '...' \
    --config /etc/semaphore/config.json

  # 3. Start it.
  systemctl enable --now semaphore.service

It listens on :3001, NOT Semaphore's default :3000, which is Grafana's on this
flavor. The port is set in semaphore.service (SEMAPHORE_PORT), and an
environment variable overrides config.json, so a "port" in the config is ignored.
EOF
exit 0
