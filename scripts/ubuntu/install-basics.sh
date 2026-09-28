#!/bin/bash
# Basic apt tools. Run FIRST by every flavor, and nothing here reaches outside
# Ubuntu's own package repositories.
#
# THIS SCRIPT DOES NOT INSTALL gcloud. It is baseline on every flavor, but it is
# its own file (install-gcloud.sh) invoked as its own Packer provisioner line,
# the same way install-otel.sh and install-cloud-sql-proxy.sh are. Chaining it
# from here hid a step with a distinct failure mode -- an upstream repo key --
# behind one "install-basics.sh" line in the build log, and it meant the
# templates did not say what a flavor actually installs.
#
# THE DISTRO PYTHON (3.12) IS THE ONLY PYTHON ON THE FLEET. python3 is already
# in the Ubuntu base image; python3-venv and python3-pip below are not, and
# without them a VM cannot build a venv at all -- install-mkdocs.sh,
# install-mcp.sh and install-ansible.sh all build theirs from this interpreter.
# It is /usr/bin/python3 and is what apt, unattended-upgrades and the gcloud CLI
# run against. There is deliberately no second, pinned interpreter: nothing
# needed one, and compiling it dominated every bake. Install anything into a
# venv -- Ubuntu's interpreter is externally managed (PEP 668) and refuses a
# bare pip install.
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
