#!/bin/bash
# Install Grafana OSS and the ClickHouse datasource plugin.
# ops flavor.
#
# FROM apt.grafana.com, pinned exactly (versions.env) and held, the same way
# install-clickhouse.sh pins its packages. The plugin comes from grafana.com
# through Grafana's own CLI at a pinned version, into the default plugins dir.
#
# INSTALLED BUT NOT ENABLED. Unlike ClickHouse, Grafana's out-of-the-box state
# is not safe to boot into: it listens on every interface on :3000 with the
# well-known admin/admin, and whoever reaches it first sets the real password.
# The deploy step sets the admin password and provisions the ClickHouse
# datasource (which carries ClickHouse credentials, so it is deploy-time too),
# then enables the unit. Nothing that holds a secret is baked.
#
# NO grafana.db IN THE IMAGE. Grafana creates its SQLite database, admin user
# included, on first start. The bake never starts it, and asserts that below.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

GRAFANA_PLUGINS_DIR=/var/lib/grafana/plugins
CH_PLUGIN=grafana-clickhouse-datasource


echo "== Add the Grafana apt repository =="
mkdir -p /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
# `>` not `>>`: re-runnable without duplicating the repo line.
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list


echo "== Install Grafana ${GRAFANA_VERSION} =="
apt-get update -y
apt-get install -y "grafana=${GRAFANA_VERSION}"
apt-mark hold grafana
rm -rf /var/lib/apt/lists/*


echo "== Install the ClickHouse datasource plugin ${GRAFANA_CLICKHOUSE_PLUGIN_VERSION} =="
grafana cli --pluginsDir "$GRAFANA_PLUGINS_DIR" \
    plugins install "$CH_PLUGIN" "$GRAFANA_CLICKHOUSE_PLUGIN_VERSION"
# The CLI ran as root; the server runs as grafana and must own what it loads.
chown -R grafana:grafana "$GRAFANA_PLUGINS_DIR"

# Assert what was installed is what was pinned. Captured rather than piped into
# grep, so pipefail cannot trip on grep's early exit.
plugins="$(grafana cli --pluginsDir "$GRAFANA_PLUGINS_DIR" plugins ls)"
echo "$plugins"
[[ "$plugins" == *"${CH_PLUGIN} @ ${GRAFANA_CLICKHOUSE_PLUGIN_VERSION}"* ]]


echo "== Leave the unit installed but NOT enabled =="
systemctl daemon-reload
# The package does not enable it today. Said explicitly so a packaging change
# upstream cannot quietly ship an image that boots into admin/admin.
systemctl disable grafana-server.service
test ! -e /var/lib/grafana/grafana.db

grafana --version

cat <<'EOF'
Grafana installed with the ClickHouse datasource plugin. It is INERT: the unit is
installed but not enabled, and no admin user or database exists yet.

Turning it on (deploy time):

  # 1. The admin password, in the service's environment file (never in the image).
  #    Read only when the admin user is created, i.e. on the FIRST start. Later
  #    changes go through `grafana cli admin reset-admin-password`.
  echo 'GF_SECURITY_ADMIN_PASSWORD=...' >> /etc/default/grafana-server

  # 2. The ClickHouse datasource, as a provisioning file (it holds ClickHouse
  #    credentials). Plugin type: grafana-clickhouse-datasource. Server
  #    127.0.0.1, native port 9000 (or HTTP 8123 with protocol: http).
  install -o root -g grafana -m 640 clickhouse.yaml \
    /etc/grafana/provisioning/datasources/clickhouse.yaml

  # 3. Start it.
  systemctl enable --now grafana-server.service

It listens on :3000. Semaphore is on :3001 on this flavor.
EOF
