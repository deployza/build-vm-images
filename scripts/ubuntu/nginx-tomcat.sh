#!/bin/bash
# Tell Tomcat to trust nginx as a proxy: enable the RemoteIpValve in server.xml.
#
# Split out of install-nginx.sh into its own provisioner step. Each flavor's
# image.pkr.hcl invokes it as its own line, AFTER install-nginx.sh — install-nginx.sh
# does NOT call it. That keeps granting Tomcat this trust an explicit, per-flavor
# decision rather than a side effect of installing nginx.
#
# Ordering requirement: install-tomcat.sh must have run (the file it edits is
# Tomcat's). It does not depend on nginx being installed, but it is only correct
# where nginx is the sole path to the connector — hence it runs after both.
#
# Runnable standalone on a live VM, to repair a server.xml that was replaced or
# reset to the pristine (valve-commented) file by a Tomcat reinstall:
#
#     sudo bash nginx-tomcat.sh
#
# WHY THIS IS AN NGINX-SIDE STEP, NOT A TOMCAT ONE
#
# nginx reaches Tomcat over loopback, so without a RemoteIpValve every request
# looks like it came from 127.0.0.1 over plain http: request.getRemoteAddr()
# returns loopback (corrupting audit logs and defeating IP-based rate limiting or
# allowlists) and request.isSecure() stays false even once TLS terminates at
# nginx. The valve rewrites both from the X-Forwarded-* headers the proxy snippet
# sets.
#
# The valve makes Tomcat BELIEVE forwarded headers, which is only safe because
# nginx is the sole path to the connector. On the plain `tomcat` / `tomcat-mysql`
# flavors Tomcat IS the front door, so enabling it there would let any client
# that reaches :8080 forge its own client IP and claim X-Forwarded-Proto: https.
# The component that creates the trust relationship configures the trust — hence
# this ships with nginx and is never invoked by install-tomcat.sh.
#
# internalProxies is deliberately ONLY loopback — narrower than Tomcat's default
# (all RFC1918), which on a GCP VM would trust the entire VPC rather than just
# local nginx.
#
# HOW THE EDIT WORKS
#
# The valve is NOT inserted here — it is already present in the repo-owned
# scripts/ubuntu/server.xml that install-tomcat.sh installs, wrapped in an XML
# comment between DEPLOYZA-REMOTEIP-BEGIN/END markers. This script only
# UNCOMMENTS it, by deleting the two marker lines that form the comment.
#
# That keeps the valve's XML in the config file where it is readable and
# reviewable, and reduces this step to removing two lines — no XML generation,
# no escaping, and nothing that can produce malformed output.
#
# Idempotent: the markers are gone after the first run, so a re-run finds
# nothing to do.
set -euxo pipefail

TOMCAT_SERVER_XML=/home/tomcat/instance/conf/server.xml

if [ ! -f "$TOMCAT_SERVER_XML" ]; then
  echo "ERROR: $TOMCAT_SERVER_XML not found — this must run AFTER install-tomcat.sh." >&2
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
