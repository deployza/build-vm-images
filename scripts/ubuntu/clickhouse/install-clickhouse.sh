#!/bin/bash
# Install ClickHouse server + client as a systemd service.
# ops flavor.
#
# FROM packages.clickhouse.com, NOT UBUNTU. Ubuntu's own clickhouse package is
# years behind. The vendor repo's `lts` channel is used, and apt is given the
# exact version from versions.env for ALL THREE packages: ClickHouse requires
# server, client and common-static at the same version, and a bare
# `apt-get install clickhouse-server` would take whatever is newest today.
#
# ENABLED AND SAFE AS BAKED, like install-mysql.sh. It is an ordinary database
# that runs happily with no configuration, so, unlike Semaphore and Grafana, it
# is enabled and comes up on first boot. What keeps that safe is config.d /
# users.d, installed from files next to this script: loopback only, and the
# password-less `default` user restricted to loopback as well. The deploy step
# sets passwords, creates databases, and widens the listener if it must.
#
# STARTED ONCE AT BAKE, THEN WIPED. The bake starts the server to prove the
# config actually loads. A config ClickHouse rejects should fail here, not at
# first boot. Then it stops the server and empties /var/lib/clickhouse. That
# last step is NOT tidiness: first start writes /var/lib/clickhouse/uuid, the
# server's identity, and an image that captured it would give every VM booted
# from it the SAME server UUID. It would also bake system tables stamped with
# the bake VM's hostname. ClickHouse recreates the whole tree on the real first
# boot.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

export DEBIAN_FRONTEND=noninteractive

CH_ETC=/etc/clickhouse-server
CH_DATA=/var/lib/clickhouse
CH_LOGS=/var/log/clickhouse-server


echo "== Add the ClickHouse apt repository =="
curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/clickhouse-keyring.gpg
# `>` not `>>`: re-runnable on a live VM without duplicating the repo line.
echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=amd64] https://packages.clickhouse.com/deb lts main" \
    > /etc/apt/sources.list.d/clickhouse.list


echo "== Install ClickHouse ${CLICKHOUSE_VERSION} =="
apt-get update -y
# Non-interactive: the server package's postinst would ask for a `default`
# password on a TTY. With none it leaves the password empty, which the users.d
# file below confines to loopback.
apt-get install -y \
    "clickhouse-common-static=${CLICKHOUSE_VERSION}" \
    "clickhouse-server=${CLICKHOUSE_VERSION}" \
    "clickhouse-client=${CLICKHOUSE_VERSION}"
# Hold them, so an unattended-upgrades run on a live VM cannot move one of the
# three and leave them at mismatched versions.
apt-mark hold clickhouse-common-static clickhouse-server clickhouse-client
rm -rf /var/lib/apt/lists/*


echo "== Install the repo-owned config overrides =="
# Files, not heredocs, for the same reason as server.xml and otelcol-base.yaml:
# XML that is reviewed and diffed as a file cannot be corrupted by a shell
# quoting bug.
install -o root -g clickhouse -m 640 \
    "$SCRIPT_DIR/clickhouse-config.xml" "$CH_ETC/config.d/deployza.xml"
install -o root -g clickhouse -m 640 \
    "$SCRIPT_DIR/clickhouse-users.xml" "$CH_ETC/users.d/deployza.xml"

# Assert the MERGED config says what the override files say. extract-from-config
# runs ClickHouse's own config preprocessor, so this also catches an override
# that parses as XML but does not land where it was meant to.
test "$(clickhouse extract-from-config --config-file="$CH_ETC/config.xml" --key=logger.level)" = "information"
test "$(clickhouse extract-from-config --config-file="$CH_ETC/config.xml" --key=listen_host)" = "127.0.0.1"


echo "== Prove it starts, then stop it and wipe its state =="
systemctl daemon-reload
systemctl enable clickhouse-server
systemctl restart clickhouse-server

for _ in $(seq 1 60); do
  if clickhouse-client --query 'SELECT 1' >/dev/null 2>&1; then break; fi
  sleep 1
done
# Not the bare version(): the server must report exactly the pinned version,
# which also proves the client and server packages agree.
test "$(clickhouse-client --query 'SELECT version()')" = "${CLICKHOUSE_VERSION}"
# The system log tables picked up their TTLs.
clickhouse-client --query 'SYSTEM FLUSH LOGS'
# Captured, not piped into `grep -q`: grep exits at the first match, and under
# pipefail the client's resulting SIGPIPE would fail the bake.
query_log_ddl="$(clickhouse-client --query 'SHOW CREATE TABLE system.query_log')"
[[ "$query_log_ddl" == *'TTL event_date + toIntervalDay(30)'* ]]

systemctl stop clickhouse-server

# See the header: an identity (uuid) and bake-time system tables must not ship.
# Only the contents go; the directories and their clickhouse ownership, created
# by the package, stay.
find "$CH_DATA" -mindepth 1 -delete
find "$CH_LOGS" -mindepth 1 -delete
test ! -e "$CH_DATA/uuid"

clickhouse-server --version

cat <<EOF
ClickHouse ${CLICKHOUSE_VERSION} installed and ENABLED. It listens on 127.0.0.1
only (:9000 native, :8123 HTTP), and its password-less \`default\` user is also
confined to loopback. Data under ${CH_DATA} is empty until first boot.

Deploy time: set a password for \`default\` (or create named users) in a new file
in ${CH_ETC}/users.d/, then \`systemctl restart clickhouse-server\`.
EOF
