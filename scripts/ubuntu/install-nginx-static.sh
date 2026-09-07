#!/bin/bash
# Install nginx as a systemd service on a Tomcat-free box.
#
# This bakes the MECHANISM only: the :80 server block, an empty
# /etc/nginx/app.d/ drop-in dir, and the /nginx-health endpoint. It bakes NO
# routing — which paths are static and which serve what content is an
# application decision, supplied at deploy time by
# build-app-install/vm/<app>.sh, exactly as MySQL is baked without
# credentials.
#
# This is install-nginx.sh's Tomcat-free sibling, not a reuse of it:
# install-nginx.sh's header literally says "fronting Tomcat on port 80" and
# bakes an `upstream tomcat { server 127.0.0.1:8080; }` block plus a
# proxy-to-tomcat.conf snippet — both meaningless dead weight on a flavor that
# will never run Tomcat. This installer mirrors it structurally (same nginx.org
# apt repo, same version pin from versions.env, same access-log-on + logrotate
# policy, same empty /etc/nginx/app.d/ + /nginx-health seam and README
# contract) but drops the upstream and the proxy snippet, and names its baked
# conf.d file static.conf rather than tomcat.conf.
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
# served and what they serve is an application decision, so it is NOT baked
# here. This installer bakes:
#
#   * the :80 server block and the /nginx-health endpoint
#   * an EMPTY /etc/nginx/app.d/ that the server block includes
#
# The per-app deploy script (build-app-install/vm/<app>.sh) drops its own
# location blocks into /etc/nginx/app.d/<app>.conf and reloads nginx (or, for a
# per-HOST app that wants the whole server block to itself, writes into
# /etc/nginx/site.d/ instead — that directory is created by the deploy script,
# not baked here; see build-app-install's ziniapps-*.sh for the contract).
# Nothing in this image dictates the URL layout.
mkdir -p /etc/nginx/app.d
mkdir -p /var/www/app
chown -R www-data:www-data /var/www/app

cat >/etc/nginx/conf.d/static.conf <<'EOF'
server {
    listen      80 default_server;
    listen      [::]:80 default_server;
    server_name _;

    # Let the app tier decide its own body limit; 0 disables nginx's 1m default
    # so large uploads are not rejected before they reach the app.
    client_max_body_size 0;

    # Local-only health endpoint: answers without touching anything else, so it
    # reports nginx liveness rather than app liveness. Declared before the app
    # include so it cannot be shadowed (an exact-match location wins over any
    # prefix anyway).
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

The baked image deliberately ships NO routing: which paths are served and what
they serve is an application decision, supplied at deploy time by
build-app-install/vm/<app>.sh — the same way MySQL credentials are.

Drop a <app>.conf here containing ONLY location blocks (no server{} wrapper —
these are included inside the :80 server block) and reload:

    sudo nginx -t && sudo systemctl reload nginx

To serve static content, e.g. an unpacked site under /var/www/app:

    location / {
        root /var/www/app;
        try_files $uri $uri/ =404;
    }

With this dir empty, every path except /nginx-health returns 404.

A per-HOST app that wants the whole server block to itself (rather than a
location dropped into this shared default server) writes to
/etc/nginx/site.d/ instead — that directory does not exist in the baked image;
the deploy script creates it and adds the include to nginx.conf on first run.
EOF
# -----------------------------------------------------------------------------

# This flavor never runs Tomcat, so there is no equivalent of
# scripts/ubuntu/nginx-tomcat.sh here and none should be added — RemoteIpValve
# only makes sense in front of a Tomcat connector.

# Rotate nginx's own logs. The nginx.org package ships /etc/logrotate.d/nginx,
# but this drop-in pins the retention to the same 14-day/compressed policy the
# other installers use, so all services age out together.
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
echo "its own location blocks (or its own /etc/nginx/site.d/ server block)."
echo "See /etc/nginx/app.d/README."
echo "Check with: systemctl status nginx"
