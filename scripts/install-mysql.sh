#!/bin/bash
# Install MySQL Community Server as a systemd service.
#
# Installs from the official MySQL apt repository (dev.mysql.com). The server is
# installed with no root password set and left enabled but the build-time start
# is harmless; the boot-time deploy script configures the actual root password /
# app database and (re)starts the service. See build-design.md §3.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

# Pin the MySQL apt repo to the desired major.minor series so unattended
# installs don't prompt and the version is reproducible.
MYSQL_APT_DEB="mysql-apt-config_0.8.34-1_all.deb"

curl -fsSL "https://repo.mysql.com/${MYSQL_APT_DEB}" -o "/tmp/${MYSQL_APT_DEB}"

# Preseed the apt-config package: select the pinned server series, suppress the
# interactive menu so the install is fully non-interactive.
debconf-set-selections <<EOF
mysql-apt-config mysql-apt-config/select-server select mysql-${MYSQL_VERSION}-lts
mysql-apt-config mysql-apt-config/select-product select Ok
EOF

dpkg -i "/tmp/${MYSQL_APT_DEB}"
rm -f "/tmp/${MYSQL_APT_DEB}"

apt-get update -y
apt-get install -y mysql-server

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
