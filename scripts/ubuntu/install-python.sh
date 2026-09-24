#!/bin/bash
# Install CPython under /opt/python/<version> and symlink /opt/python/latest,
# mirroring install-java.sh's /opt/<tool>/latest layout.
#
# INVOKED AS ITS OWN PACKER PROVISIONER LINE BY EVERY FLAVOR, and kept LAST in
# that list, immediately before write-manifest.sh. It used to be chained from
# the end of install-basics.sh; it is called explicitly now so that a template
# says what the flavor installs and so a failure here names this script rather
# than "basics". Last, because it is by far the slowest step in a bake: every
# cheap failure in every other installer surfaces before the compile rather than
# 15 minutes after it. Python is baseline fleet-wide, not a per-flavor opt-in.
# Nothing else in a bake depends on it -- install-mkdocs.sh and install-mcp.sh
# build their venvs from the DISTRO python3 that install-basics.sh puts down --
# so running it last is free.
#
# It is also why every template carries machine_type = "e2-standard-8" and
# disk_size = 20, and every cloudbuild.yaml a timeout of 3600s -- the compile
# below does not fit Cloud Build's 10-minute default. A new flavor that omits
# those three will fail its first bake on the clock.
#
# BUILT FROM SOURCE, ON PURPOSE. The other installers prefer a package repo
# (nginx.org, Ubuntu's own) or a published binary (JDK, Gitea) and this one
# cannot: Ubuntu 24.04 ships Python 3.12 and carries no 3.14 package at all,
# and the usual backport (the deadsnakes PPA) publishes "latest 3.14.x" rather
# than a named patch — an apt-based image would silently acquire a different
# interpreter on every rebuild. python.org's source tarball is the only
# official artifact for an exact X.Y.Z, so PYTHON_VERSION in versions.env is a
# full patch version and this script compiles it. Like install-java.sh and
# install-gitea.sh, the download is trusted on HTTPS from the vendor with no
# separate checksum step.
#
# THE SYSTEM PYTHON IS LEFT ALONE. Ubuntu's /usr/bin/python3 stays 3.12 and is
# never redirected: apt, unattended-upgrades and the gcloud CLI from
# install-gcloud.sh all run against it by absolute path or by `#!/usr/bin/python3`,
# and repointing it is the classic way to leave a box unable to run apt. This
# script therefore installs into a private prefix, adds only VERSIONED names to
# /usr/local/bin (python3.14, pip3.14 — never a bare python3/pip3, which would
# shadow the system one for every root process), and puts the unversioned names
# on PATH through /etc/profile.d for interactive and login shells only.
#
# PEP 668 does not apply inside this prefix: it is our own interpreter, not an
# externally-managed distro one, so `pip install` works directly. Applications
# should still build their own venv from it (`/opt/python/latest/bin/python3 -m
# venv ...`) the way install-mkdocs.sh and install-mcp.sh do, so one app's
# dependency set cannot break another's.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

PYTHON_PREFIX="/opt/python/${PYTHON_VERSION}"
# X.Y — the name CPython gives its own binaries (python3.14, pip3.14).
PYTHON_MM="${PYTHON_VERSION%.*}"

# Build toolchain + the headers each optional stdlib module probes for. These
# are silent dependencies: configure does not fail when one is missing, it just
# omits the module, so a missing libssl-dev yields an interpreter that cannot
# `import ssl` and a missing libsqlite3-dev one that cannot `import sqlite3`.
# The verification block at the end of this script exists to catch exactly that.
apt-get update -y
apt-get install -y \
    build-essential \
    pkg-config \
    xz-utils \
    zlib1g-dev \
    libbz2-dev \
    liblzma-dev \
    libssl-dev \
    libffi-dev \
    libsqlite3-dev \
    libreadline-dev \
    libncursesw5-dev \
    libgdbm-dev \
    libgdbm-compat-dev \
    uuid-dev \
    tk-dev

mkdir -p /opt/python /usr/local/src
cd /usr/local/src

wget -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/${PYTHON_TAR_FILE}"
tar -xf "${PYTHON_TAR_FILE}"
rm "${PYTHON_TAR_FILE}"
cd "Python-${PYTHON_VERSION}"

# --enable-optimizations (PGO) + --with-lto cost roughly 10-20 minutes of bake
# time and buy ~10-20% runtime speed. That trade is right here because it is
# paid once per image and recovered on every VM the image ever boots.
# Not --enable-shared: nothing on these VMs embeds libpython, and a shared
# build needs ldconfig wiring that would only add a way for the interpreter to
# stop resolving its own runtime.
./configure \
    --prefix="${PYTHON_PREFIX}" \
    --enable-optimizations \
    --with-lto \
    --with-ensurepip=install

make -j"$(nproc)"
# `make install` and not `altinstall`: the well-known reason to prefer
# altinstall is that install overwrites /usr/bin/python3 — which cannot happen
# here, because the prefix is private. Inside it, install is what creates the
# convenient unversioned python3/pip3 that /etc/profile.d puts on PATH.
make install

cd /
rm -rf "/usr/local/src/Python-${PYTHON_VERSION}"

ln -sfn "${PYTHON_PREFIX}" /opt/python/latest

# Versioned names only — see the header. `python3.14` is unambiguous and
# resolves to this build from any shell, cron job or systemd unit without
# putting anything on a search path ahead of the distro's interpreter.
ln -sfn "/opt/python/latest/bin/python${PYTHON_MM}" "/usr/local/bin/python${PYTHON_MM}"
ln -sfn "/opt/python/latest/bin/pip${PYTHON_MM}"    "/usr/local/bin/pip${PYTHON_MM}"

# Login/interactive shells get the unversioned names. This is a PATH entry, not
# a symlink: it affects a human's shell and anything sourcing /etc/profile, and
# leaves apt's and gcloud's `#!/usr/bin/python3` shebangs untouched.
cat >/etc/profile.d/python.sh <<'EOF'
# CPython from /opt/python/latest (see /etc/image-manifest.txt for the version).
# Ahead of /usr/bin on purpose, so `python3` in a shell is this interpreter;
# the system Python remains at /usr/bin/python3 for the OS's own tooling.
export PATH="/opt/python/latest/bin:${PATH}"
EOF
chmod 644 /etc/profile.d/python.sh

"${PYTHON_PREFIX}/bin/pip${PYTHON_MM}" install --no-cache-dir --upgrade pip setuptools wheel

# Fail the bake, not a live VM, if configure quietly dropped a module. Each of
# these is a stdlib import that depends on a -dev package above, and each one
# is the kind of thing an app discovers at 3am rather than at build time: no
# ssl means no HTTPS at all, no sqlite3/lzma/bz2/zlib/ctypes/readline means a
# library that imports them fails on import.
"${PYTHON_PREFIX}/bin/python${PYTHON_MM}" -c \
    'import ssl, sqlite3, lzma, bz2, zlib, ctypes, readline, uuid, decimal; print(ssl.OPENSSL_VERSION)'

# Guard the whole point of the previous block: that we built what was pinned.
"${PYTHON_PREFIX}/bin/python${PYTHON_MM}" - "${PYTHON_VERSION}" <<'EOF'
import platform, sys
want = sys.argv[1]
got = platform.python_version()
if got != want:
    raise SystemExit(f"version mismatch: built {got}, expected {want}")
EOF

# The system interpreter must still be the distro's, or apt and gcloud are
# broken in an image that otherwise looks fine.
test "$(readlink -f /usr/bin/python3)" != "$(readlink -f "${PYTHON_PREFIX}/bin/python3")"

rm -rf /var/lib/apt/lists/*

"${PYTHON_PREFIX}/bin/python${PYTHON_MM}" --version

echo "Python ${PYTHON_VERSION} installed at ${PYTHON_PREFIX} (symlink /opt/python/latest)"
echo "Versioned commands: python${PYTHON_MM}, pip${PYTHON_MM} (via /usr/local/bin)"
echo "Login shells also get bare python3/pip3 via /etc/profile.d/python.sh."
echo "System python3 ($(/usr/bin/python3 --version 2>&1)) is untouched and still serves apt/gcloud."
echo "Apps should build their own venv: /opt/python/latest/bin/python3 -m venv /opt/<app>/venv"
