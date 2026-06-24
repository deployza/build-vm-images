#!/bin/bash
# Script to install tomcat
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

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

# --- Externalized config + log directories (FHS-correct) ----------------------
# WARs are dropped into Tomcat's default appBase ($TOMCAT_HOME/webapps). Config
# and logs live OUTSIDE the install tree and are passed to Tomcat as both env
# vars (CONFIG_DIR/LOG_DIR) and JVM properties (-Dconfig.dir/-Dlog.dir); see
# setenv.sh.
CONFIG_DIR=/etc/apps
LOG_DIR=/var/log/apps

# Externalized config + log roots, owned by the service user.
mkdir -p "$CONFIG_DIR" "$LOG_DIR"
chown tomcat:tomcat "$CONFIG_DIR" "$LOG_DIR"
chmod 750 "$CONFIG_DIR" "$LOG_DIR"

# Rotate application logs (we are off the distro default path, so ship our own
# logrotate rule).
cat > /etc/logrotate.d/tomcat-apps <<EOF
$LOG_DIR/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su tomcat tomcat
}
EOF
chmod 644 /etc/logrotate.d/tomcat-apps
# -----------------------------------------------------------------------------


# Copy systemd service file for Tomcat
cp "$SCRIPT_DIR/tomcat.service" /etc/systemd/system/tomcat.service

# Reload systemd and enable/start Tomcat service
systemctl daemon-reload
systemctl enable tomcat
systemctl start tomcat

echo "Tomcat installed and started as a systemd service"
echo "Check status with: systemctl status tomcat"

exit 0