#!/usr/bin/env bash
set -euo pipefail
# Install two on-VM disk helpers:
#   /usr/local/sbin/disk-audit  - interactive report of where disk is going
#   /usr/local/sbin/disk-alert  - cron-driven check that logs when a mount is full
# and clean the apt cache to reclaim space up front.

DISK_ALERT_THRESHOLD="${DISK_ALERT_THRESHOLD:-85}"
ADMIN_EMAIL="${ADMIN_EMAIL:-root}"

echo "== Clean package cache safely =="

sudo apt-get clean || true


echo "== Install disk audit helper =="

sudo tee /usr/local/sbin/disk-audit >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "===== Filesystem usage ====="
df -h

echo
echo "===== systemd journal usage ====="
journalctl --disk-usage || true

echo
echo "===== Largest top-level dirs under /var ====="
sudo du -xh /var --max-depth=1 2>/dev/null | sort -h | tail -20

echo
echo "===== Largest dirs under /opt ====="
sudo du -xh /opt --max-depth=2 2>/dev/null | sort -h | tail -20 || true

echo
echo "===== Largest dirs under /var/lib ====="
sudo du -xh /var/lib --max-depth=2 2>/dev/null | sort -h | tail -30

echo
echo "===== Large files over 500MB ====="
sudo find / -xdev -type f -size +500M -exec ls -lh {} \; 2>/dev/null | sort -k5 -h || true

echo
echo "===== Common dangerous files ====="
sudo find / -xdev \( -name "*.hprof" -o -name "core.*" -o -name "*.dump" -o -name "*.dmp" \) -exec ls -lh {} \; 2>/dev/null || true
EOF

sudo chmod +x /usr/local/sbin/disk-audit


echo "== Install simple disk alert cron =="

sudo tee /usr/local/sbin/disk-alert >/dev/null <<EOF
#!/usr/bin/env bash
THRESHOLD="${DISK_ALERT_THRESHOLD}"
EMAIL="${ADMIN_EMAIL}"

df -P | awk -v threshold="\$THRESHOLD" '
NR > 1 {
  usage=\$5
  gsub("%", "", usage)
  if (usage >= threshold) {
    print "Disk alert: " \$6 " is " usage "% full"
  }
}'
EOF

sudo chmod +x /usr/local/sbin/disk-alert

sudo tee /etc/cron.d/disk-alert >/dev/null <<'EOF'
*/30 * * * * root /usr/local/sbin/disk-alert | logger -t disk-alert
EOF

echo
echo "Done. Run this anytime to inspect disk usage:"
echo "sudo disk-audit"
