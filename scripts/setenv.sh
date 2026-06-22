#!/bin/bash
# Tomcat environment configuration
# This file is sourced by catalina.sh during Tomcat startup

# Set JAVA_HOME
export JAVA_HOME=/opt/java/latest

# Set CATALINA_HOME and CATALINA_BASE
export CATALINA_HOME=/opt/tomcat
export APPS_DIR=$CATALINA_HOME/apps

# Calculate 75% of available RAM for Java heap
# Get total RAM in KB, calculate 75%, convert to MB
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HEAP_SIZE_MB=$((TOTAL_RAM_KB * 75 / 100 / 1024))

# Set initial heap to 50% of max heap for better performance
INITIAL_HEAP_MB=$((HEAP_SIZE_MB * 50 / 100))

# Java options for Tomcat
export JAVA_OPTS="-server -Xms${INITIAL_HEAP_MB}M -Xmx${HEAP_SIZE_MB}M -Dapps.dir=$APPS_DIR"

