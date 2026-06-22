#!/bin/bash
# Script to install tomcat
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

FILES_BASE_URL=${FILES_BASE_URL:-https://storage.googleapis.com/files.deployza.com}

export JAVA_HOME=/opt/java/latest
export TOMCAT_HOME=/opt/tomcat
TOMCAT_ARCHIVE="${TOMCAT_TAR_FILE}"

groupadd tomcat

# Create tomcat user without password and with home directory
useradd -m -d $TOMCAT_HOME -g tomcat -s /bin/bash tomcat

# Lock the password so no password-based login is allowed
passwd -l tomcat

chown -R tomcat:tomcat $TOMCAT_HOME

echo "Tomcat user created. Downloading and extracting Tomcat as tomcat user..."

# Download and extract Tomcat as tomcat user to maintain ownership
runuser -l tomcat -c "cd $TOMCAT_HOME && wget -q ${FILES_BASE_URL}/installables/$TOMCAT_ARCHIVE"
runuser -l tomcat -c "cd $TOMCAT_HOME && tar -xzf $TOMCAT_ARCHIVE --strip-components=1"
runuser -l tomcat -c "cd $TOMCAT_HOME && rm -f $TOMCAT_ARCHIVE"

# Copy setenv.sh to Tomcat's bin directory
cp "$SCRIPT_DIR/setenv.sh" $TOMCAT_HOME/bin/setenv.sh
chown tomcat:tomcat $TOMCAT_HOME/bin/setenv.sh

# Set permissions for Tomcat directories
chmod +x $TOMCAT_HOME/bin/*.sh


# Copy systemd service file for Tomcat
cp "$SCRIPT_DIR/tomcat.service" /etc/systemd/system/tomcat.service

# Reload systemd and enable/start Tomcat service
systemctl daemon-reload
systemctl enable tomcat
systemctl start tomcat

echo "Tomcat installed and started as a systemd service"
echo "Check status with: systemctl status tomcat"

exit 0