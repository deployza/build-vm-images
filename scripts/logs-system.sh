#!/usr/bin/env bash
set -euo pipefail
# Host-wide OS log/disk hygiene: systemd journal retention, core-dump size
# caps, and generic logrotate for /opt apps. All settings that differ from the
# OS defaults; only what's needed is set.
#
# Note: service-specific log rotation lives with each installer at image build:
# Tomcat app logs (/home/tomcat/apps/logs) in install-tomcat.sh, MySQL logs (/var/log/mysql)
# and binlog retention in install-mysql.sh.

JOURNAL_MAX_RETENTION="${JOURNAL_MAX_RETENTION:-14day}"


echo "== Configure systemd journal retention =="
# journald caps its size by default but does NOT expire by age unless told to.

sudo mkdir -p /etc/systemd/journald.conf.d

sudo tee /etc/systemd/journald.conf.d/99-log-limits.conf >/dev/null <<EOF
[Journal]
MaxRetentionSec=${JOURNAL_MAX_RETENTION}
EOF

sudo systemctl restart systemd-journald

echo "Vacuuming journal logs older than ${JOURNAL_MAX_RETENTION}..."
sudo journalctl --vacuum-time="${JOURNAL_MAX_RETENTION}" || true


echo "== Limit systemd core dump storage =="
# Default lets core dumps use up to 10% of the filesystem; a crashing JVM can
# eat gigabytes fast. The other coredump.conf knobs already match the defaults,
# so we set only what differs. systemd-coredump reads this at dump time, so
# nothing needs reloading.

sudo mkdir -p /etc/systemd/coredump.conf.d

sudo tee /etc/systemd/coredump.conf.d/99-size-limits.conf >/dev/null <<'EOF'
[Coredump]
MaxUse=2G
KeepFree=2G
EOF


echo "== Configure generic /opt application log rotation =="

sudo tee /etc/logrotate.d/opt-app-logs >/dev/null <<'EOF'
/opt/*/logs/*.log /opt/*/log/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF


echo "== Test logrotate configs =="
# Dry-run last, so it validates every logrotate rule on the image (including
# the ones written by the service installers), not just the one above.

sudo logrotate -d /etc/logrotate.conf >/tmp/logrotate-test.out 2>&1 || {
  echo "Logrotate test had warnings/errors. See:"
  echo "/tmp/logrotate-test.out"
}
