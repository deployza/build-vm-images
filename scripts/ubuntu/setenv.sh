#!/bin/bash
# Tomcat environment configuration
# This file is sourced by catalina.sh during Tomcat startup

# Set JAVA_HOME
export JAVA_HOME=/opt/java/latest

# Set CATALINA_HOME and CATALINA_BASE
export CATALINA_HOME=/home/tomcat/instance

# Externalized application directories under the tomcat user's home (outside the
# WAR/install tree). WARs are dropped into the default appBase
# ($CATALINA_HOME/webapps). Config and logs are exported both as environment
# variables AND as JVM -D properties below, so the app can read them via
# System.getenv("CONFIG_DIR") or System.getProperty("config.dir") — never the
# JVM working directory.
export CONFIG_DIR=/home/tomcat/apps/conf    # externalized app config directory
export LOGS_DIR=/home/tomcat/apps/logs      # application log directory

# Calculate 75% of available RAM for Java heap
# Get total RAM in KB, calculate 75%, convert to MB
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HEAP_SIZE_MB=$((TOTAL_RAM_KB * 75 / 100 / 1024))

# Set initial heap to 50% of max heap for better performance
INITIAL_HEAP_MB=$((HEAP_SIZE_MB * 50 / 100))

# Java options for Tomcat. The -D properties are how the app locates its config
# and log directories — never the JVM working directory (non-deterministic under
# systemd).
export JAVA_OPTS="-server -Xms${INITIAL_HEAP_MB}M -Xmx${HEAP_SIZE_MB}M -Dconfig.dir=$CONFIG_DIR -Dlogs.dir=$LOGS_DIR"

