#!/bin/bash
# Basic tools + gcloud CLI. Run first by every flavor.
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
