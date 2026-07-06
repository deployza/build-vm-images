#!/bin/bash
# Installs the boot-time app launcher into a VM image:
#   /usr/local/bin/vm-startup.sh   — the launcher (clone APP_REPO, run <APP_NAME>.sh)
#   vm-startup.service             — systemd unit that runs it on every boot
#
# Runs on every flavor (like install-basics.sh), so any VM booted from our images
# self-deploys its app from git metadata. git + curl are provided by
# install-basics.sh, which must run before this.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 755 "$SCRIPT_DIR/vm-startup.sh"      /usr/local/bin/vm-startup.sh
install -m 644 "$SCRIPT_DIR/vm-startup.service" /etc/systemd/system/vm-startup.service

systemctl daemon-reload
# Enable so it runs on boot of instances created from this image. It is NOT
# started here — the image bake VM has no app metadata and no need to deploy.
systemctl enable vm-startup.service

echo "vm-startup launcher installed and enabled (runs on next boot)"
exit 0
