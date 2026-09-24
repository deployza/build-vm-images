#!/bin/bash
set -euo pipefail
# Host-wide OS log/disk hygiene: systemd journal retention, core-dump size
# caps, and generic logrotate for /opt apps. All settings that differ from the
# OS defaults; only what's needed is set.
#
# Runs on every flavor, via the provisioner's `sudo -E bash`, so nothing here
# calls sudo itself (same convention as the install-*.sh siblings). It lived at
# scripts/ root until 2026-09-24, which meant the file provisioner
# (source = "scripts/ubuntu/") never shipped it and it had never actually run.
#
# Note: service-specific log rotation lives with each installer at image build:
# Tomcat app logs (/home/tomcat/instance/logs) in install-tomcat.sh, MySQL logs (/var/log/mysql)
# and binlog retention in install-mysql.sh.

JOURNAL_MAX_RETENTION="${JOURNAL_MAX_RETENTION:-14day}"


echo "== Configure systemd journal retention =="
# journald caps its size by default but does NOT expire by age unless told to.

mkdir -p /etc/systemd/journald.conf.d

tee /etc/systemd/journald.conf.d/99-log-limits.conf >/dev/null <<EOF
[Journal]
MaxRetentionSec=${JOURNAL_MAX_RETENTION}
EOF

systemctl restart systemd-journald

echo "Vacuuming journal logs older than ${JOURNAL_MAX_RETENTION}..."
journalctl --vacuum-time="${JOURNAL_MAX_RETENTION}" || true


echo "== Limit systemd core dump storage =="
# Default lets core dumps use up to 10% of the filesystem; a crashing JVM can
# eat gigabytes fast. The other coredump.conf knobs already match the defaults,
# so we set only what differs. systemd-coredump reads this at dump time, so
# nothing needs reloading.

mkdir -p /etc/systemd/coredump.conf.d

tee /etc/systemd/coredump.conf.d/99-size-limits.conf >/dev/null <<'EOF'
[Coredump]
MaxUse=2G
KeepFree=2G
EOF


echo "== Configure generic /opt application log rotation =="

tee /etc/logrotate.d/opt-app-logs >/dev/null <<'EOF'
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
#
# THIS GATES THE BAKE. A broken rule used to print a note and ship the image
# anyway, which made this step decoration rather than validation. A logrotate
# rule that does not parse silently stops rotating the logs it names, and you
# find out when the disk fills months later.
if ! logrotate -d /etc/logrotate.conf >/tmp/logrotate-test.out 2>&1; then
  echo "ERROR: logrotate config test failed. Output follows:" >&2
  cat /tmp/logrotate-test.out >&2
  exit 1
fi
echo "logrotate config test passed"

