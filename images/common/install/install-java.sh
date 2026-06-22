#!/bin/bash
# Install the JDK under /opt/java and symlink /opt/java/latest.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

FILES_BASE_URL=${FILES_BASE_URL:-https://storage.googleapis.com/files.deployza.com}

mkdir -p /opt/java
cd /opt/java

wget -q ${FILES_BASE_URL}/installables/${JDK_TAR_FILE}
tar -xzf ${JDK_TAR_FILE}
rm ${JDK_TAR_FILE}
ln -sfn /opt/java/jdk-${JDK_VERSION}* /opt/java/latest

export JAVA_HOME=/opt/java/latest
export PATH="${JAVA_HOME}/bin:${PATH}"

java -version
