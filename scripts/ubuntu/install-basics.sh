#!/bin/bash
# Basic tools + gcloud CLI. Run first by every flavor.
#
# PYTHON IS BASELINE ON EVERY FLAVOR, IN TWO LAYERS.
#
#   1. The distro's python3 (3.12 on noble) plus python3-venv and python3-pip,
#      from the apt list below. python3 itself is already in the Ubuntu base
#      image; the other two are not, so without them a VM cannot build a venv
#      or install anything. This layer stays /usr/bin/python3 and is what apt,
#      unattended-upgrades and the gcloud CLI run against.
#
#   2. The pinned CPython from install-python.sh, invoked at the end of this
#      script, into /opt/python/<version> with an /opt/python/latest symlink.
#
# LAYER 2 IS EXPENSIVE AND THAT IS A DELIBERATE, ACCEPTED COST. There is no
# apt package for an exact 3.14.z (see install-python.sh's header), so it is
# compiled with PGO+LTO -- 10-20 minutes added to EVERY flavor's bake,
# including flavors that will never run a line of Python. Every template
# therefore carries `machine_type = "e2-standard-8"` and `disk_size = 20`, and
# every cloudbuild.yaml a `timeout: 3600s`, because Cloud Build's 10-minute
# default cannot fit this build. If you add a new flavor, copy those three
# settings or its first bake will time out and strand a Packer VM.
#
# The two layers do not collide: install-python.sh uses its own prefix and
# never repoints /usr/bin/python3, so `python3-venv` below keeps belonging to
# the distro interpreter and the pinned one carries its own ensurepip venv.
# A venv is still the right way to install anything on either -- Ubuntu's
# interpreter is externally managed (PEP 668) and refuses a bare pip install,
# and on the pinned one a shared site-packages just lets one app break another.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Install gcloud CLI

curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

apt-get update -y

apt-get install -y google-cloud-cli

rm -rf /var/lib/apt/lists/*

# Pinned CPython, last: it is by far the slowest step here, so every cheap
# failure above surfaces before the compile rather than 15 minutes after it.
# Kept as its own script rather than inlined -- it is long, it is the only
# part of basics that builds from source, and it must stay runnable on its
# own against a live VM.
bash "$SCRIPT_DIR/install-python.sh"
