#!/bin/bash
# OpenTelemetry Collector (contrib). Runs on EVERY flavor, like install-basics.sh
# and write-manifest.sh.
#
# WHAT THIS BAKES IS ONLY THE MECHANISM. The collector installed here watches
# nothing and sends nowhere: /etc/otelcol/config.yaml is an inert nop pipeline
# (otelcol-base.yaml). Real configuration is PUSHED to a running VM over SSH by
# build-ops' vm/<vm>/install-otel.sh (run by Ansible), which validates it, swaps
# that file and restarts the service. Nothing on the VM pulls, clones or polls
# for config.
#
# See ../../../../build-docs/ops-execution.md for the full design and the
# reasoning behind the push-only split. The short version: a log path or a
# parser regex is iterated on weekly and a collector binary is replaced
# quarterly, so config does not belong in an image.
#
# WHY THE TARBALL AND NOT THE .deb. The official otelcol-contrib .deb creates
# its own `otelcol-contrib` user, its own unit, and reads
# /etc/otelcol-contrib/config.yaml. Taking the tarball instead keeps the user,
# the paths and the unit ours, and matches how the JDK and Tomcat are installed
# on these images (tarball into a fixed dir, no version string in any path).
#
# WHY CONTRIB AND NOT CORE. The filelog and journald receivers and the
# googlecloudpubsub exporter the pushed configs use are all contrib-only. Core
# cannot do this job.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

OTELCOL_HOME=/opt/otelcol
OTELCOL_CONF_DIR=/etc/otelcol
OTELCOL_TAR="otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.tar.gz"
OTELCOL_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/${OTELCOL_TAR}"

# NO CHECKSUM VERIFICATION, deliberately — matching install-java.sh
# and install-tomcat.sh, which both fetch a pinned tarball over
# HTTPS and extract it. TLS to the release host is the trust boundary, and the
# pinned version in versions.env is what makes the bake reproducible.
# (install-python.sh is the one exception in this directory.)


echo "== Create the otelcol service user =="
# System account, no home, no login shell. It owns nothing except the ability to
# read the log sources it is later granted.
#
# GROUP MEMBERSHIP IS DELIBERATELY NOT SET HERE. Which groups this user needs
# (adm for nginx/mysql, tomcat for Tomcat) depends on what the VM ends up
# running, which is a push-time decision, not a bake-time one. build-ops'
# install-otel.sh adds them (OTEL_GROUPS) with `getent group X && usermod -aG X
# otelcol` and restarts the service — supplementary groups only take effect at
# process start.
#
# THIS IS THE NUMBER ONE SILENT FAILURE in a collector deployment: without the
# right group the receiver gets EACCES on a log directory, logs it exactly once,
# and then looks perfectly healthy forever while shipping nothing.
groupadd --system otelcol
useradd --system --gid otelcol --no-create-home \
        --shell /usr/sbin/nologin \
        --comment "OpenTelemetry Collector" otelcol


echo "== Download otelcol-contrib ${OTELCOL_VERSION} =="
mkdir -p "$OTELCOL_HOME/bin"
cd /tmp
wget -q "$OTELCOL_URL" -O "$OTELCOL_TAR"

tar -xzf "$OTELCOL_TAR" -C "$OTELCOL_HOME/bin" otelcol-contrib
rm -f "$OTELCOL_TAR"

chown -R root:root "$OTELCOL_HOME"
chmod 755 "$OTELCOL_HOME/bin/otelcol-contrib"

# Assert the binary actually runs before anything depends on it, so a truncated
# download or a wrong-architecture tarball fails the bake here rather than at
# first boot.
"$OTELCOL_HOME/bin/otelcol-contrib" --version


echo "== Install the inert base config =="
# THERE IS NO conf.d DIRECTORY. Nothing merges on the target: build-ops keeps
# one complete config per VM (vm/<vm>/otel.yaml) and pushes it whole.
#
# otelcol-base.yaml is shipped as a FILE rather than written by a heredoc here,
# for the same reason server.xml is (see install-tomcat.sh): a config that is
# reviewed and diffed as a file cannot be silently malformed by a quoting bug in
# a shell script.
mkdir -p "$OTELCOL_CONF_DIR"
install -o root -g otelcol -m 640 \
        "$SCRIPT_DIR/otelcol-base.yaml" "$OTELCOL_CONF_DIR/config.yaml"

# Backup slot used by build-ops' install-otel.sh: it copies the live config here
# before swapping, and restores from it if the restarted collector does not stay
# up.
# Created empty at bake so the directory permissions are set once, here.
mkdir -p "$OTELCOL_CONF_DIR/backup"
chown root:otelcol "$OTELCOL_CONF_DIR/backup"
chmod 750 "$OTELCOL_CONF_DIR/backup"

# Validate what we just installed, at bake time, where a failure costs a
# rebuild instead of a silent dead collector on every VM. The push side
# validates each pushed config the same way, against this same binary, before
# it swaps it in.
"$OTELCOL_HOME/bin/otelcol-contrib" validate --config "$OTELCOL_CONF_DIR/config.yaml"


echo "== Install and enable the systemd unit =="
install -m 644 "$SCRIPT_DIR/otelcol.service" /etc/systemd/system/otelcol.service

systemctl daemon-reload
# Enabled so it starts on boot of instances created from this image. NOT started
# here: the bake VM has no telemetry to collect, and starting it would only add
# a process to the image capture.
systemctl enable otelcol.service

echo "otelcol-contrib ${OTELCOL_VERSION} installed and enabled (inert until a"
echo "config is pushed). It collects NOTHING and exports NOWHERE as baked —"
echo "see build-ops/otel/ for the push side."
exit 0
