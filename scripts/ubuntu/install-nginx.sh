#!/bin/bash
# Install nginx as a systemd service, fronting Tomcat on port 80.
#
# This bakes the MECHANISM only: the :80 server block, a Tomcat upstream, a
# reusable proxy snippet, and an empty /etc/nginx/app.d/ drop-in dir. It bakes NO
# routing — which paths are static and which proxy to Tomcat is an application
# decision, supplied at deploy time by build-app-install/vm/<app>.sh, exactly as
# MySQL is baked without credentials.
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

# --- Server block + app routing seam ------------------------------------------
# The stock nginx.org package ships conf.d/default.conf serving its own welcome
# page on :80. Remove it so our server block is the only listener on that port —
# two default_server blocks on :80 is a hard config error at start.
rm -f /etc/nginx/conf.d/default.conf

# WHAT IS BAKED vs. WHAT THE APP INSTALLER SUPPLIES
#
# The image owns the mechanism, not the policy — the same split MySQL follows
# (baked with no credentials; the deploy step provisions them). WHICH paths are
# static and which proxy to Tomcat is an application decision, so it is NOT baked
# here. This installer bakes:
#
#   * the :80 server block, the Tomcat upstream, and the proxy header/timeout
#     boilerplate as a reusable snippet (proxy-to-tomcat.conf)
#   * an EMPTY /etc/nginx/app.d/ that the server block includes
#
# The per-app deploy script (build-app-install/vm/<app>.sh) drops its own
# location blocks into /etc/nginx/app.d/<app>.conf and reloads nginx. Nothing in
# this image dictates the URL layout.
#
# Snippet, so an app's location block gets correct proxying with one line:
#   location /api/ { include snippets/proxy-to-tomcat.conf; }
# X-Forwarded-* let the app reconstruct the original request — without them
# Tomcat sees every client as 127.0.0.1 over plain http.
mkdir -p /etc/nginx/snippets
cat >/etc/nginx/snippets/proxy-to-tomcat.conf <<'EOF'
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
EOF

# The app routing drop-in dir. Empty in the baked image: with no <app>.conf the
# server block below has no location / at all, so nginx answers 404 on every path
# except /nginx-health. That is intentional — a VM with no app deployed should not
# pretend to serve one. The static root is created (empty) so an installer can
# populate it without needing root to mkdir first.
mkdir -p /etc/nginx/app.d
mkdir -p /var/www/app
chown -R www-data:www-data /var/www/app

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

    # Local-only health endpoint: answers without touching Tomcat, so it reports
    # nginx liveness rather than app liveness. Declared before the app include so
    # it cannot be shadowed (an exact-match location wins over any prefix anyway).
    location = /nginx-health {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    # Per-app routing, written by the app deploy script. Empty in the baked image.
    # The wildcard matches zero files without error, so nginx starts fine either
    # way. See /etc/nginx/app.d/README for the contract.
    include /etc/nginx/app.d/*.conf;
}
EOF

# Document the contract next to the dir it governs, so it is discoverable from a
# running VM and not only from the repo.
cat >/etc/nginx/app.d/README <<'EOF'
Per-app nginx routing drop-ins.

The baked image deliberately ships NO routing: which paths are static and which
proxy to Tomcat is an application decision, supplied at deploy time by
build-app-install/vm/<app>.sh — the same way MySQL credentials are.

Drop a <app>.conf here containing ONLY location blocks (no server{} wrapper —
these are included inside the :80 server block) and reload:

    sudo nginx -t && sudo systemctl reload nginx

To proxy a path to Tomcat, include the baked snippet rather than repeating the
X-Forwarded-* headers:

    location /api/ {
        include snippets/proxy-to-tomcat.conf;
    }

To serve static content, e.g. an SPA bundle installed under /var/www/app:

    location / {
        root /var/www/app;
        try_files $uri $uri/ /index.html;   # SPA fallback; drop for plain static
    }

With this dir empty, every path except /nginx-health returns 404.
EOF
# -----------------------------------------------------------------------------

# --- Tomcat's RemoteIpValve is NOT enabled here -------------------------------
# Telling Tomcat to trust this proxy's X-Forwarded-* headers is a separate step,
# in scripts/ubuntu/nginx-tomcat.sh, invoked as its own line in each flavor's
# image.pkr.hcl AFTER this installer. See that script for the rationale (why it
# belongs to the nginx side rather than install-tomcat.sh, and why
# internalProxies stays at loopback only).
#
# It is deliberately not called from here: on the tomcat-nginx-mysql flavor the
# valve is required, but keeping it a distinct provisioner line means a flavor
# that fronts Tomcat differently can install nginx without granting that trust,
# and the step can be re-run on a live VM on its own.
# -----------------------------------------------------------------------------

# Rotate nginx's own logs. The nginx.org package ships /etc/logrotate.d/nginx,
# but this drop-in pins the retention to the same 14-day/compressed policy the
# tomcat and mysql installers use, so all three services age out together.
# USR1 makes the master reopen its log files after rotation.
#
# `size 100M` alongside `daily` is an OR, not an AND: logrotate rotates on
# whichever trips first. Without it, a traffic burst or a scanner hammering :80
# grows a single day's access.log unbounded until the next daily run. Note this
# only bounds the file at the moments logrotate actually runs — stock
# logrotate.timer fires once a day, so a same-day spike is capped at retention
# time, not in flight. Raising the timer frequency is what would close that gap.
cat >/etc/logrotate.d/nginx-custom <<'EOF'
/var/log/nginx/*.log {
    daily
    size 100M
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
echo "Listening on :80 with an EMPTY app routing dir (/etc/nginx/app.d/) — every"
echo "path except /nginx-health returns 404 until an app deploy script drops in"
echo "its own location blocks. See /etc/nginx/app.d/README."
echo "Check with: systemctl status nginx"
