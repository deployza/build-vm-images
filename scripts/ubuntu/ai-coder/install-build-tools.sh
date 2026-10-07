#!/bin/bash
# apt tools that AI agents and their sandboxed builds expect to find. ai-coder
# flavor.
#
# The JDK, Maven and the distro Python come from their own installers. This adds
# what those builds and the agents themselves reach for:
#
#   build-essential, python3-dev, pkg-config
#       pip builds any package without a manylinux wheel from source. Without a
#       compiler and the Python headers, a Python repo fails its build check on
#       its first native dependency.
#   ripgrep
#       Claude Code's search tools and srt's deny-path detection both use it.
#       install-sandbox.sh installs it too, so that installer stands alone.
#   acl
#       setfacl/getfacl. Worktrees are created by the service user and written
#       by the agent user through a shared group, so build-ops sets default
#       ACLs and the setgid bit on them.
#   patch, diffutils, file, xz-utils, zip, less, make
#       small tools agents call while working.
#
# Nothing here reaches outside Ubuntu's own repositories, like install-basics.sh.
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y \
    acl \
    build-essential \
    diffutils \
    file \
    less \
    make \
    patch \
    pkg-config \
    python3-dev \
    ripgrep \
    xz-utils \
    zip
rm -rf /var/lib/apt/lists/*

gcc --version
rg --version
setfacl --version
