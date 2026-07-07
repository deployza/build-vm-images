#!/bin/bash
# Script to install tomcat
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export JAVA_HOME=/opt/java/latest

# The tomcat user gets a normal home directory (/home/tomcat) like any user.
# Tomcat itself is installed into a fixed instance dir under that home
# (CATALINA_HOME), so no version string leaks into any path — a Tomcat version
# bump only changes which archive versions.env points at, not this layout.
TOMCAT_USER_HOME=/home/tomcat
export TOMCAT_HOME=$TOMCAT_USER_HOME/instance
TOMCAT_ARCHIVE="${TOMCAT_TAR_FILE}"

groupadd tomcat

# Create tomcat user without password and with a standard home directory.
useradd -m -d $TOMCAT_USER_HOME -g tomcat -s /bin/bash tomcat

# Lock the password so no password-based login is allowed
passwd -l tomcat

# Fixed instance dir for the Tomcat install (CATALINA_HOME), owned by the user.
mkdir -p $TOMCAT_HOME
chown -R tomcat:tomcat $TOMCAT_USER_HOME

echo "Tomcat user created. Downloading and extracting Tomcat as tomcat user..."

# Download and extract Tomcat as tomcat user to maintain ownership
runuser -l tomcat -c "cd $TOMCAT_HOME && wget -q ${FILES_BASE_URL}/installables/$TOMCAT_ARCHIVE"
runuser -l tomcat -c "cd $TOMCAT_HOME && tar -xzf $TOMCAT_ARCHIVE --strip-components=1"
runuser -l tomcat -c "cd $TOMCAT_HOME && rm -f $TOMCAT_ARCHIVE"

# Disable Tomcat's per-request access log. The stock conf/server.xml enables an
# AccessLogValve that writes rotating daily files (localhost_access_log.*.txt) to
# $TOMCAT_HOME/logs. We turn the access log OFF fleet-wide (matching the nginx/
# apisix/tomcat docker images) by commenting the valve out of server.xml. Tomcat's
# other logs are unaffected (juli under $TOMCAT_HOME/logs, app logs under
# $LOGS_DIR with the logrotate rule below).
sed -i '/className="org.apache.catalina.valves.AccessLogValve"/,/\/>/{s/<Valve/<!-- Valve/; s/\/>/\/ -->/}' \
        $TOMCAT_HOME/conf/server.xml
! grep -q '<Valve className="org.apache.catalina.valves.AccessLogValve"' $TOMCAT_HOME/conf/server.xml
chown tomcat:tomcat $TOMCAT_HOME/conf/server.xml

# Copy setenv.sh to Tomcat's bin directory
cp "$SCRIPT_DIR/setenv.sh" $TOMCAT_HOME/bin/setenv.sh
chown tomcat:tomcat $TOMCAT_HOME/bin/setenv.sh

# Set permissions for Tomcat directories
chmod +x $TOMCAT_HOME/bin/*.sh

# --- Externalized app config + log directories --------------------------------
# WARs are dropped into Tomcat's default appBase ($TOMCAT_HOME/webapps). App
# config and logs live under the tomcat user's home (outside the install tree)
# and are passed to Tomcat as both env vars (CONFIG_DIR/LOGS_DIR) and JVM
# properties (-Dconfig.dir/-Dlogs.dir); see setenv.sh.
CONFIG_DIR=$TOMCAT_USER_HOME/apps/conf
LOGS_DIR=$TOMCAT_USER_HOME/apps/logs

# App config + log roots, owned by the service user.
mkdir -p "$CONFIG_DIR" "$LOGS_DIR"
chown -R tomcat:tomcat "$TOMCAT_USER_HOME/apps"
chmod 750 "$CONFIG_DIR" "$LOGS_DIR"

# Rotate application logs (we are off the distro default path, so ship our own
# logrotate rule).
cat > /etc/logrotate.d/tomcat-apps <<EOF
$LOGS_DIR/*.log {
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