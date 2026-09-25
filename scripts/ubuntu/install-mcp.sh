#!/bin/bash
# Install the MCP server's RUNTIME: graphify and fastmcp in a venv at /opt/mcp/venv.
#
# THAT IS ALL THIS BAKES. The application — the service user, /etc/mcp/mcp.env,
# the /usr/local/bin/mcp-* helpers, the OAuth gateway (mcp_auth_app.py), the
# Markdown pass (mcp-md-graph and its vendored extractor), the sudoers drop-in and
# every systemd unit — is PUSHED to a running VM by build-ops
# (vm/mcp-vm/mcp.sh, `ansible-playbook playbooks/mcp-vm.yml --tags mcp`). Same
# split as every other flavor: the image carries the software, the deploy
# carries the app and its config. Until image 1-3 this script baked both, so a
# one-line mcp.env change meant a rebake and a VM replacement (image 1-2 existed
# for exactly that).
#
# A VM BOOTED FROM THIS IMAGE SERVES NOTHING until that push has run. There is no
# unit to start: nothing on the image knows it is the Deployza MCP server.
#
# WHY THE VENV IS STILL BAKED rather than pip-installed by the push: it is ~191 MB
# of wheels with every tree-sitter grammar. Installing it at deploy time would
# make PyPI's availability a deploy-time dependency and cost minutes per push on
# a shared-core e2-micro. It is the runtime, in the same sense Tomcat is on the
# tomcat flavors.
#
# The bake-time checks that used to live here — the gateway's import check against
# fastmcp and the vendored extractor's drift check against graphify — moved with
# the code they check. build-ops/vm/mcp-vm/mcp.sh runs both BEFORE it installs
# anything, so a GRAPHIFY_VERSION or FASTMCP_VERSION bump that breaks either now
# fails the first push against the new image rather than the bake.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

# python3 is in the Ubuntu base image; python3-venv is not, and is required.
apt-get update -y
apt-get install -y python3 python3-venv
rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# The venv.
#
# Not optional, and not a style choice: Ubuntu's system Python is externally
# managed (PEP 668), so `pip3 install` into it is refused outright.
#
# Extras, and why each is there:
#   mcp        the HTTP transport — without it there is no server at all
#   terraform  HCL is NOT in the default grammar set. Measured: build-terraform
#              produces 0 nodes without this extra and 338 nodes / 777 edges with
#              it. Silent, not an error.
#   sql        schema files; warns "tree_sitter_sql not installed" until added
#
# There is no extra for HTML or CSS — no such grammar exists, even under [all].
# Static-UI repos index their JavaScript and nothing else. That is a real gap,
# not an oversight.
#
# SECOND PACKAGE: fastmcp. It is the OAuth gateway's framework — DCR, PKCE, token
# issuance and the Google bridge, none of which we want to own. Pinned in
# versions.env for the same reason graphifyy is: it sits in the authentication path,
# so a bump is a deliberate act followed by re-validating the whole browser login
# flow, never an automatic upgrade.
#
# It shares the venv rather than getting its own. Two venvs would double ~200 MB of
# wheels on a 20 GB boot disk for no isolation that matters — both processes run as
# the same unprivileged user on the same box.
#
# py-key-value-aio[disk] is stated explicitly, not left to arrive as somebody's
# transitive dependency: fastmcp's OAuth provider takes an AsyncKeyValue store for
# the client registrations, and the disk-backed one raises "DiskStore requires
# py-key-value-aio[disk]" at construction without this extra. That failure would
# happen at gateway START.
# ---------------------------------------------------------------------------
mkdir -p /opt/mcp
python3 -m venv /opt/mcp/venv
/opt/mcp/venv/bin/pip install --no-cache-dir --upgrade pip
/opt/mcp/venv/bin/pip install --no-cache-dir \
    "graphifyy[mcp,terraform,sql]==${GRAPHIFY_VERSION}" \
    "fastmcp==${FASTMCP_VERSION}" \
    "py-key-value-aio[disk]"

# ---------------------------------------------------------------------------
# Smoke test: the runtime is importable. Only what THIS script owns — the
# application's own checks run at push time, against the code being pushed.
# ---------------------------------------------------------------------------
/opt/mcp/venv/bin/graphify --version
/opt/mcp/venv/bin/python -c 'import graphify.serve, fastmcp, key_value.aio.stores.disk'

echo "graphify ${GRAPHIFY_VERSION} + fastmcp ${FASTMCP_VERSION} installed (venv /opt/mcp/venv)"
echo "No app, no units: push build-ops' vm/mcp-vm/ to make this VM serve."
