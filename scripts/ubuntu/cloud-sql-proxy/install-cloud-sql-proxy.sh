#!/bin/bash
# Cloud SQL Auth Proxy. Runs on EVERY flavor, like install-basics.sh,
# install-otel.sh and write-manifest.sh.
#
# WHAT THIS BAKES IS ONLY THE MECHANISM. The proxy installed here connects to
# nothing: /etc/cloud-sql-proxy/env ships with an EMPTY CSP_INSTANCES and the
# unit is installed but deliberately NOT enabled. Which Cloud SQL instance a VM
# talks to is a deploy-time decision (it differs per app and per environment),
# exactly like the otel collector's real config and like MySQL's credentials.
#
# THE UNIT IS NOT ENABLED, AND THAT IS THE DIFFERENCE FROM install-otel.sh.
# The collector has a valid inert config, so it can run healthily with nothing
# to do. The proxy has no such state: with no instance connection name it exits
# non-zero immediately, so enabling it at bake would give every VM in the fleet
# a unit in permanent restart-backoff. Turning it on is one line at deploy time
# (see "Turning it on" at the bottom of this file).
#
# WHY THE GCS MIRROR AND NOT apt. Google publishes the proxy as a single static
# binary at storage.googleapis.com/cloud-sql-connectors/; there is no apt repo
# for it. A pinned URL into a fixed path keeps this the same shape as the JDK,
# Tomcat, Gitea and otelcol installs.
#
# WHY NOT THE JDBC SOCKET FACTORY INSTEAD. The Java connector library would
# cover Tomcat apps only. The proxy is a process, so it serves the Python
# flavours, a psql/mysql shell during an incident, and any future runtime, with
# one mechanism and one IAM path.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

CSP_HOME=/opt/cloud-sql-proxy
CSP_CONF_DIR=/etc/cloud-sql-proxy
CSP_URL="https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v${CLOUD_SQL_PROXY_VERSION}/cloud-sql-proxy.linux.amd64"

# NO CHECKSUM VERIFICATION, deliberately — matching install-java.sh,
# install-tomcat.sh and install-otel.sh. TLS to the release
# host is the trust boundary and the pin in versions.env is what makes the bake
# reproducible. (Upstream publishes no .sha256 next to this object.)


echo "== Create the cloud-sql-proxy service user =="
# System account, no home, no login shell. It owns nothing and needs no group
# membership: unlike the otelcol user it reads no files on this box — its only
# inputs are the env file and the VM's own service-account credentials from the
# metadata server.
groupadd --system csqlproxy
useradd --system --gid csqlproxy --no-create-home \
        --shell /usr/sbin/nologin \
        --comment "Cloud SQL Auth Proxy" csqlproxy


echo "== Download cloud-sql-proxy ${CLOUD_SQL_PROXY_VERSION} =="
mkdir -p "$CSP_HOME/bin"
wget -q "$CSP_URL" -O "$CSP_HOME/bin/cloud-sql-proxy"

chown -R root:root "$CSP_HOME"
chmod 755 "$CSP_HOME/bin/cloud-sql-proxy"

# Assert the binary runs before anything depends on it, so a truncated download
# or a wrong-architecture object fails the bake here rather than at first boot.
"$CSP_HOME/bin/cloud-sql-proxy" --version


echo "== Install the (empty) instance configuration =="
# Shipped as a FILE rather than a heredoc, for the same reason otelcol-base.yaml
# and server.xml are: config that is reviewed and diffed as a file cannot be
# silently malformed by a quoting bug in a shell script.
#
# 640 root:csqlproxy — it holds no secret today (the proxy authenticates as the
# VM's service account, there is no key file), but it is the file a future
# operator would be tempted to put one in.
mkdir -p "$CSP_CONF_DIR"
install -o root -g csqlproxy -m 640 \
        "$SCRIPT_DIR/cloud-sql-proxy.env" "$CSP_CONF_DIR/env"


echo "== Install the systemd unit (NOT enabled) =="
install -m 644 "$SCRIPT_DIR/cloud-sql-proxy.service" \
        /etc/systemd/system/cloud-sql-proxy.service
systemctl daemon-reload

# NO `systemctl enable`. See the header: with CSP_INSTANCES empty the proxy
# exits immediately, and an enabled unit would put every VM into restart
# backoff at boot. The deploy step that knows the instance enables it.

cat <<'EOF'
cloud-sql-proxy installed. It is INERT: no instance is configured and the unit
is installed but not enabled, so a VM booted from this image connects to no
database.

Turning it on (deploy time, once the instance is known):

  printf 'CSP_INSTANCES=%s\n' "my-project:asia-east1:my-instance" \
    >> /etc/cloud-sql-proxy/env
  systemctl enable --now cloud-sql-proxy.service
  systemctl is-active cloud-sql-proxy.service

It then listens on 127.0.0.1:3307 — NOT 3306, which is left to a local MySQL
daemon on the mysql / tomcat-mysql / tomcat-nginx-mysql flavors. An app's JDBC
URL for Cloud SQL is jdbc:mysql://127.0.0.1:3307/<db>.

The VM's service account needs roles/cloudsql.client on the target instance.
EOF
exit 0
