#!/bin/bash
# Install the Reposilite jar at /opt/reposilite/reposilite.jar. ai-coding
# flavor.
#
# WHAT IT IS FOR. Deployza Java repos inherit deployza-parent-pom from the
# private Artifact Registry. Sandboxed builds hold no registry credential, so
# the agent user's settings.xml mirrors everything to a read-only Maven proxy on
# localhost, and only the proxy holds the Artifact Registry Reader key.
#
# THE JAR ONLY. This is software, like the Semaphore binary on the ops flavor.
# Everything else is configured by build-ops: the proxy's own OS user (the only
# one that can read the key), its config (a proxied repo for Artifact Registry
# plus Maven Central, read-only, loopback only), the credential from Secret
# Manager, and its systemd unit. There is no unit here, so nothing starts on
# boot.
#
# ITS DEFAULT PORT IS 8080, which is Tomcat's. build-ops' config must move it,
# for example to 127.0.0.1:8081.
#
# Runs on the image's JDK (Reposilite needs 17+). No checksum step, matching
# install-java.sh / install-tomcat.sh.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

REPOSILITE_HOME=/opt/reposilite
REPOSILITE_URL="https://maven.reposilite.com/releases/com/reposilite/reposilite/${REPOSILITE_VERSION}/reposilite-${REPOSILITE_VERSION}-all.jar"

install -d -o root -g root -m 755 "$REPOSILITE_HOME"
wget -q "$REPOSILITE_URL" -O "$REPOSILITE_HOME/reposilite.jar"
chmod 644 "$REPOSILITE_HOME/reposilite.jar"

# Read the whole archive, so a truncated download fails the bake. Starting
# Reposilite here would write a data dir into the image.
/opt/java/latest/bin/jar tf "$REPOSILITE_HOME/reposilite.jar" >/dev/null

# The jar's own version, for the manifest.
echo "$REPOSILITE_VERSION" > "$REPOSILITE_HOME/VERSION"

echo "Reposilite ${REPOSILITE_VERSION} jar installed at ${REPOSILITE_HOME}/reposilite.jar."
echo "No user, config, credential or unit: build-ops sets those up."
