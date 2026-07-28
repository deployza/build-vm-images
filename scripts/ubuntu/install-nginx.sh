#!/bin/bash
# Install nginx as a systemd service, fronting Tomcat as a reverse proxy.
#
# nginx comes from the official nginx.org stable apt repository rather than
# Ubuntu's own `nginx` package, matching the sibling docker image
# (build-docker/nginx/dockerfile) so the version tracks upstream stable rather
# than the distro snapshot. The two repos keep independent copies of this install
# step by design — see CLAUDE.md, "Self-contained installers".
#
# Logging differs deliberately from the docker image: a VM owns its own disk, so
# the access log stays ON and is rotated by logrotate here. The container image
# turns it off instead, because containers get no in-image logrotate. See
# CLAUDE.md, "Log & disk hygiene (VM-only)".
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

# gnupg2 dearmors the signing key; lsb-release supplies the distro codename the
# repo line is pinned to. Both are already present from install-basics.sh, but
# this installer must stand on its own if the flavor ordering ever changes.
apt-get update -y
apt-get install -y ca-certificates curl gnupg2 lsb-release

curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list

apt-get update -y
apt-get install -y nginx

# --- Reverse proxy to Tomcat --------------------------------------------------
# The stock nginx.org package ships conf.d/default.conf serving its own welcome
# page on :80. Remove it so our server block is the only listener on that port —
# two default_server blocks on :80 is a hard config error at start.
rm -f /etc/nginx/conf.d/default.conf

# Proxy everything to Tomcat on localhost:8080. Tomcat's connector is left on its
# default port; nothing binds :8080 publicly (the VM firewall governs that), so
# nginx is the front door. X-Forwarded-* let the app reconstruct the original
# request — without them Tomcat sees every client as 127.0.0.1 over plain http.
cat >/etc/nginx/conf.d/tomcat.conf <<'EOF'
upstream tomcat {
    server 127.0.0.1:8080;
    keepalive 32;
}

server {
    listen      80 default_server;
    listen      [::]:80 default_server;
    server_name _;

    # Let the app tier decide its own body limit; 0 disables nginx's 1m default
    # so large uploads are not rejected by the proxy before reaching Tomcat.
    client_max_body_size 0;

    location / {
        proxy_pass http://tomcat;
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  $server_port;

        # Empty Connection header keeps the upstream keepalive pool usable
        # (proxy_http_version 1.1 alone still sends "Connection: close").
        proxy_set_header Connection "";

        proxy_connect_timeout 5s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }

    # Local-only health endpoint: answers without touching Tomcat, so it reports
    # nginx liveness rather than app liveness.
    location = /nginx-health {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}
EOF
# -----------------------------------------------------------------------------

# Rotate nginx's own logs. The nginx.org package ships /etc/logrotate.d/nginx,
# but this drop-in pins the retention to the same 14-day/compressed policy the
# tomcat and mysql installers use, so all three services age out together.
# USR1 makes the master reopen its log files after rotation.
cat >/etc/logrotate.d/nginx-custom <<'EOF'
/var/log/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        test -s /var/run/nginx.pid && kill -USR1 "$(cat /var/run/nginx.pid)" || true
    endscript
}
EOF
chmod 644 /etc/logrotate.d/nginx-custom

# Fail the bake here rather than at first boot if the config is malformed.
nginx -t

systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

nginx -v

rm -rf /var/lib/apt/lists/*

echo "nginx ${NGINX_VERSION} installed and started as a systemd service"
echo "Proxying :80 -> 127.0.0.1:8080 (Tomcat). Check with: systemctl status nginx"
