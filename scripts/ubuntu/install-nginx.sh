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

# --- Tell Tomcat to trust this proxy (enable the RemoteIpValve) ---------------
# nginx reaches Tomcat over loopback, so without a RemoteIpValve every request
# looks like it came from 127.0.0.1 over plain http: request.getRemoteAddr()
# returns loopback (corrupting audit logs and defeating IP-based rate limiting or
# allowlists) and request.isSecure() stays false even once TLS terminates at
# nginx. The valve rewrites both from the X-Forwarded-* headers the proxy snippet
# sets.
#
# This lives in the NGINX installer, not install-tomcat.sh, on purpose: the valve
# makes Tomcat BELIEVE forwarded headers, which is only safe because nginx is the
# sole path to the connector. On the plain `tomcat` / `tomcat-mysql` flavors
# Tomcat IS the front door, so enabling it there would let any client that
# reaches :8080 forge its own client IP and claim X-Forwarded-Proto: https. The
# component that creates the trust relationship configures the trust.
#
# internalProxies is deliberately ONLY loopback — narrower than Tomcat's default
# (all RFC1918), which on a GCP VM would trust the entire VPC rather than just
# local nginx.
#
# The valve is NOT inserted here — it is already present in the repo-owned
# scripts/ubuntu/server.xml that install-tomcat.sh installs, wrapped in an XML
# comment between DEPLOYZA-REMOTEIP-BEGIN/END markers. This installer only
# UNCOMMENTS it, by deleting the two marker lines that form the comment.
#
# That keeps the valve's XML in the config file where it is readable and
# reviewable, and reduces this step to removing two lines — no XML generation,
# no escaping, and nothing that can produce malformed output.
#
# Idempotent: the markers are gone after the first run, so a re-run finds
# nothing to do.
TOMCAT_SERVER_XML=/home/tomcat/instance/conf/server.xml

if [ ! -f "$TOMCAT_SERVER_XML" ]; then
  echo "ERROR: $TOMCAT_SERVER_XML not found — install-nginx.sh must run AFTER install-tomcat.sh." >&2
  exit 1
fi

if grep -q 'DEPLOYZA-REMOTEIP-BEGIN' "$TOMCAT_SERVER_XML"; then
  # Delete the comment-open marker line and the comment-close marker line. What
  # sat between them — the <Valve> element — becomes live XML.
  sed -i \
    -e '/<!-- DEPLOYZA-REMOTEIP-BEGIN$/d' \
    -e '/^[[:space:]]*DEPLOYZA-REMOTEIP-END -->$/d' \
    "$TOMCAT_SERVER_XML"

  # Verify: the valve must now be live (not inside a comment) and both markers
  # gone. A half-applied edit would leave server.xml malformed and Tomcat would
  # fail to start at first boot rather than here.
  grep -q '^[[:space:]]*<Valve className="org.apache.catalina.valves.RemoteIpValve"' "$TOMCAT_SERVER_XML"
  ! grep -q 'DEPLOYZA-REMOTEIP' "$TOMCAT_SERVER_XML"

  chown tomcat:tomcat "$TOMCAT_SERVER_XML"

  # Tomcat is already running (install-tomcat.sh started it); restart so the
  # valve takes effect in the baked image rather than only after first boot.
  systemctl restart tomcat
  echo "RemoteIpValve enabled in server.xml (nginx is the trusted proxy)."
else
  echo "No DEPLOYZA-REMOTEIP markers in server.xml — valve already enabled or file customised; leaving as is."
fi
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
echo "Listening on :80 with an EMPTY app routing dir (/etc/nginx/app.d/) — every"
echo "path except /nginx-health returns 404 until an app deploy script drops in"
echo "its own location blocks. See /etc/nginx/app.d/README."
echo "Check with: systemctl status nginx"
