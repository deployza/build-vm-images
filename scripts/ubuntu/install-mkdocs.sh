#!/bin/bash
# Install MkDocs + its plugins into a venv, for the nginx flavor's
# docs-on-the-box design.
#
# The VM clones www-apidocs from GitHub at deploy time and runs
# `mkdocs build --strict` locally (the on-demand docs-refresh service installed
# by build-ops' vm/deployza-vm/www-apidocs.sh) — this script bakes the ONLY
# part of that which belongs at image-build time: the Python toolchain mkdocs
# needs. It does not clone www-apidocs, does not run a build, and bakes no
# repo-specific config; that is all deploy-time work, owned by build-ops, same
# split the WAR/conf.d pull follows.
#
# BAKE-TIME, NOT DEPLOY-TIME. Chosen the same way install-mcp.sh bakes
# graphify's venv rather than installing it from a boot script: PyPI
# availability becomes a boot-time dependency otherwise, and a broken
# `pip install` would surface on a live, hard-to-SSH-into VM instead of
# failing the image build.
#
# PINNED TO MATCH www-apidocs/requirements.txt exactly (see versions.env) —
# the VM's build must use the same mkdocs/plugin versions as whoever last
# verified the site with `mkdocs serve` locally, or a doc that renders fine
# in dev could fail `--strict` on the VM (or vice versa) for a plugin-version
# reason nobody can see from the markdown.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

# python3 + python3-venv both come from install-basics.sh now, so this is
# redundant in every flavor that runs it first. Kept anyway, the same way
# install-nginx-static.sh re-installs its own gnupg2/lsb-release: an
# installer must stand on its own if the flavor's ordering ever changes.
# The venv itself is not optional - Ubuntu's system Python is externally
# managed (PEP 668), so a bare `pip install` against it is refused
# outright; same reasoning as install-mcp.sh's venv.
apt-get update -y
apt-get install -y python3 python3-venv
rm -rf /var/lib/apt/lists/*

mkdir -p /opt/mkdocs
python3 -m venv /opt/mkdocs/venv
/opt/mkdocs/venv/bin/pip install --no-cache-dir --upgrade pip
/opt/mkdocs/venv/bin/pip install --no-cache-dir \
    "mkdocs==${MKDOCS_VERSION}" \
    "mkdocs-material==${MKDOCS_MATERIAL_VERSION}" \
    "mkdocs-awesome-pages-plugin==${MKDOCS_AWESOME_PAGES_VERSION}"

/opt/mkdocs/venv/bin/mkdocs --version

echo "mkdocs ${MKDOCS_VERSION} + mkdocs-material ${MKDOCS_MATERIAL_VERSION} + mkdocs-awesome-pages-plugin ${MKDOCS_AWESOME_PAGES_VERSION} installed (venv /opt/mkdocs/venv)"
echo "No repo is cloned and no build runs here — that is website-vm's"
echo "docs-refresh timer, at deploy time. This only bakes the toolchain."
