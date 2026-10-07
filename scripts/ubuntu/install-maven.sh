#!/bin/bash
# Install Apache Maven under /opt/maven and put `mvn` on PATH. ai-coder flavor.
#
# THE EXCEPTION TO "NO MAVEN ON A VM". Everywhere else WARs are built by the
# docker maven image, and a runtime VM never compiles anything. The ai-coder VM
# is different: its agents build and test the code they write, on the VM,
# inside the sandbox. Repos with `mvnw` still bring their own Maven version.
#
# FROM MAVEN CENTRAL, NOT dlcdn.apache.org. The Apache CDN drops a release as
# soon as the next one ships, so a pinned URL there breaks the next rebake.
# Central keeps every version forever. No checksum step, matching
# install-java.sh / install-tomcat.sh.
#
# JAVA IS NOT ON PATH on these images (install-java.sh only links
# /opt/java/latest). `mvn` finds the JDK through JAVA_HOME, which build-ops sets
# for whoever runs builds. The bake check below sets it for itself.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

MAVEN_HOME=/opt/maven
MAVEN_TAR="apache-maven-${MAVEN_VERSION}-bin.tar.gz"
MAVEN_URL="https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/${MAVEN_TAR}"

cd /tmp
wget -q "$MAVEN_URL" -O "$MAVEN_TAR"

# Into the fixed dir, with no version in the path, like Tomcat's `instance`: a
# version bump changes nothing that build-ops points at.
mkdir -p "$MAVEN_HOME"
tar -xzf "$MAVEN_TAR" -C "$MAVEN_HOME" --strip-components=1
rm -f "$MAVEN_TAR"
chown -R root:root "$MAVEN_HOME"

ln -sfn "$MAVEN_HOME/bin/mvn" /usr/local/bin/mvn

# Fail the bake on a truncated download or a version that is not the pin.
JAVA_HOME=/opt/java/latest mvn --version
JAVA_HOME=/opt/java/latest mvn --version | grep -q "Apache Maven ${MAVEN_VERSION} "

echo "Maven ${MAVEN_VERSION} installed in ${MAVEN_HOME}; mvn is in /usr/local/bin."
echo "Callers must set JAVA_HOME=/opt/java/latest."
