#!/bin/bash
# Install MySQL Server as a systemd service.
#
# Installs mysql-server + mysql-client from Ubuntu's own apt repository (the
# distro packages, MySQL 8.0.x on Ubuntu 24.04) rather than the dev.mysql.com
# repo. This keeps the baked version pinned to what the LTS distro ships, so the
# image stays stable across rebuilds instead of tracking dev.mysql.com's latest.
# The server is installed with no root password set and left enabled; the
# build-time start is harmless — the boot-time deploy script configures the
# actual root password / app database and (re)starts the service. See
# build-design.md §3.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y mysql-server mysql-client

# Listen only on localhost in the baked image; the deploy step opens it up if a
# remote bind is required.
sed -i 's/^#\?\s*bind-address.*/bind-address = 127.0.0.1/' /etc/mysql/mysql.conf.d/mysqld.cnf || true

systemctl daemon-reload
systemctl enable mysql
systemctl start mysql

mysql --version

rm -rf /var/lib/apt/lists/*

echo "MySQL ${MYSQL_VERSION} installed and started as a systemd service"
echo "Check status with: systemctl status mysql"
