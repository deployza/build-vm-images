#!/bin/bash
# Basic apt tools. Run FIRST by every flavor, and nothing here reaches outside
# Ubuntu's own package repositories.
#
# THIS SCRIPT NO LONGER INSTALLS gcloud OR THE PINNED CPYTHON. Both are still
# baseline on every flavor, but each is now its own file invoked as its own
# Packer provisioner line, the same way install-otel.sh and
# install-cloud-sql-proxy.sh are:
#
#   install-gcloud.sh   # third-party apt repo + signing key
#   install-python.sh   # pinned CPython, compiled from source
#
# WHY THE SPLIT. Chaining them from here hid two steps with distinct failure
# modes -- an upstream repo key, and a 15-minute source build -- behind one
# "install-basics.sh" line in the build log, and it meant the templates did not
# say what a flavor actually installs. A new flavor now lists all three lines
# explicitly; leaving one out is visible in the diff, where a missing chained
# call was not. Order in the template is basics -> gcloud -> (flavor installers)
# -> python, and install-python.sh is kept LAST because it is by far the slowest
# step: every cheap failure surfaces before the compile rather than 15 minutes
# after it.
#
# THE DISTRO PYTHON STAYS HERE, AND IS A DIFFERENT THING. python3 is already in
# the Ubuntu base image; python3-venv and python3-pip below are not, and without
# them a VM cannot build a venv at all -- install-mkdocs.sh and install-mcp.sh
# both build theirs from THIS interpreter, not from the pinned one. This layer
# is /usr/bin/python3 and is what apt, unattended-upgrades and the gcloud CLI
# run against; install-python.sh adds a second interpreter under /opt/python and
# never repoints it. A venv is still the right way to install anything on either
# -- Ubuntu's interpreter is externally managed (PEP 668) and refuses a bare pip
# install, and on the pinned one a shared site-packages just lets one app break
# another.
set -euxo pipefail

apt-get update -y
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    dos2unix \
    dnsutils \
    git \
    gnupg2 \
    htop \
    iproute2 \
    iputils-ping \
    jq \
    lsb-release \
    netcat-openbsd \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    rsync \
    sed \
    software-properties-common \
    traceroute \
    tree \
    unzip \
    vim \
    wget \
    libfreetype6 \
    libfreetype6-dev

# Package lists are ~40MB of cache that would otherwise be captured into the
# image; every later installer that needs apt refreshes them for itself.
rm -rf /var/lib/apt/lists/*
