#!/bin/bash
# Tomcat environment configuration
# This file is sourced by catalina.sh during Tomcat startup

# Set JAVA_HOME
export JAVA_HOME=/opt/java/latest

# CATALINA_HOME / CATALINA_BASE are intentionally NOT set here. catalina.sh
# computes both (from the location of its own bin/ dir) BEFORE it sources this
# file, so anything we set would be redundant. systemd (tomcat.service) also
# injects them for the service path. setenv.sh owns only what catalina.sh does
# not compute for us: JAVA_HOME and the runtime-sized JAVA_OPTS below.

# NOTE: config and log locations are NOT passed as JVM -D properties anymore.
# Each webapp resolves its own config/log paths from its per-webapp Tomcat
# context.xml ($CATALINA_HOME/conf/Catalina/localhost/<app>.xml) via its
# ServletContextListener (e.g. assess-server's AppServletContextListener reads
# <Parameter> entries such as assess-server.config / assess-server.logs.dir and
# promotes them to system properties). A JVM-wide -Dconfig.dir/-Dlogs.dir would
# be shared by every co-hosted webapp, so the app deploy script installs those
# context files per app instead. See <app>.sh in build-vm-scripts/vm.

# Calculate 75% of available RAM for Java heap
# Get total RAM in KB, calculate 75%, convert to MB
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HEAP_SIZE_MB=$((TOTAL_RAM_KB * 75 / 100 / 1024))

# Set initial heap to 50% of max heap for better performance
INITIAL_HEAP_MB=$((HEAP_SIZE_MB * 50 / 100))

# Java options for Tomcat. Config/log locations are supplied per webapp through
# its context.xml (see the note above), not via JVM -D properties here.
export JAVA_OPTS="-server -Xms${INITIAL_HEAP_MB}M -Xmx${HEAP_SIZE_MB}M"

