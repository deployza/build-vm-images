#!/bin/bash
# Basic tools + gcloud CLI. Run first by every flavor.
set -euxo pipefail

apt-get update -y
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    dos2unix \
    git \
    gnupg2 \
    lsb-release \
    sed \
    software-properties-common \
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
