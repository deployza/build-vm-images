#!/bin/bash
# Install Node.js under /opt/node and put node/npm/npx on PATH. ai-coder flavor.
#
# THE nodejs.org TARBALL, NOT apt. Ubuntu's own nodejs is a version line behind
# LTS, and NodeSource's apt repo can only pin a major. The tarball pins an exact
# release and installs into a fixed dir, the same way the JDK, Tomcat and otelcol
# are installed on these images. No checksum step, matching those installers.
#
# GLOBAL npm PACKAGES LAND IN /opt/node (npm's default prefix is the install
# dir), root-owned. That is where install-sandbox.sh and install-playwright.sh
# put `srt` and `playwright`. A user cannot `npm install -g` over them.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

NODE_HOME=/opt/node
NODE_TAR="node-v${NODE_VERSION}-linux-x64.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TAR}"

cd /tmp
wget -q "$NODE_URL" -O "$NODE_TAR"

mkdir -p "$NODE_HOME"
tar -xJf "$NODE_TAR" -C "$NODE_HOME" --strip-components=1
rm -f "$NODE_TAR"
chown -R root:root "$NODE_HOME"

for bin in node npm npx; do
  ln -sfn "$NODE_HOME/bin/$bin" "/usr/local/bin/$bin"
done

node --version
test "$(node --version)" = "v${NODE_VERSION}"
npm --version

echo "Node.js ${NODE_VERSION} installed in ${NODE_HOME}; node/npm/npx are in /usr/local/bin."
