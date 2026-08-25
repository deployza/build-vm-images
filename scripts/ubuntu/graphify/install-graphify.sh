#!/bin/bash
# Install graphify (code knowledge-graph MCP server) as systemd services.
#
# graphify ships as the PyPI package `graphifyy`. This bakes it into a
# self-contained venv under /opt/graphify, creates the unprivileged service user,
# and installs both units plus their helper binaries. Nothing is configured for a
# specific deployment and no secret is baked — same contract as install-gitea.sh:
# the units are ENABLED but cannot come up until the VM's boot script mounts the
# data disk. See build-design.md §3.
#
# THE SPLIT THIS SCRIPT EXISTS TO ENFORCE:
#
#   boot disk (baked here)      the venv, ~191 MB with every tree-sitter grammar
#   data disk (created at boot) the clones, the graphs, swap, the service HOME
#
# Baking the venv is the entire point of the flavor. The alternative — installing
# it from a VM startup script — re-downloads 191 MB of wheels from PyPI on every
# single boot and makes PyPI's availability a boot-time dependency.
#
# Unlike the other installers this one lives in its own subdirectory with its
# units, helper scripts and graphify.env, because none of them are shared with
# any other flavor. scripts/ubuntu/ proper holds the SHARED installers.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# versions.env is one level up: it is the repo-wide pinned-version file, shared
# with every other installer.
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

export DEBIAN_FRONTEND=noninteractive

# python3 and git are already present (git via install-basics.sh, python3 in the
# Ubuntu base image); python3-venv is not, and is required.
apt-get update -y
apt-get install -y python3 python3-venv
rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Service user.
#
# --no-create-home is deliberate. The home is /data/graphify, on a disk that does
# not exist at bake time; the boot script creates and chowns it. That location is
# not a preference — graphify's `global add` writes to Path.home()/".graphify",
# hardcoded upstream with no flag to redirect it, so a home on the boot disk
# would silently put the merged graph somewhere an image swap destroys.
# ---------------------------------------------------------------------------
adduser --system --group --disabled-password --no-create-home \
    --home /data/graphify --shell /usr/sbin/nologin graphify

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
# ---------------------------------------------------------------------------
mkdir -p /opt/graphify
python3 -m venv /opt/graphify/venv
/opt/graphify/venv/bin/pip install --no-cache-dir --upgrade pip
/opt/graphify/venv/bin/pip install --no-cache-dir \
    "graphifyy[mcp,terraform,sql]==${GRAPHIFY_VERSION}"

# ---------------------------------------------------------------------------
# Configuration and helper binaries (installer-owned copies, uploaded alongside
# this script).
# ---------------------------------------------------------------------------
mkdir -p /etc/graphify
install -m 644 "$SCRIPT_DIR/graphify.env" /etc/graphify/graphify.env

for helper in gcp-secret graphify-serve graphify-refresh \
              graphify-git-askpass graphify-log-failure; do
    install -m 755 "$SCRIPT_DIR/$helper" "/usr/local/bin/$helper"
done

# The per-instance boot script. Named without its .sh extension on the target,
# matching the other helpers, since it is invoked as a command by its unit.
install -m 755 "$SCRIPT_DIR/graphify-boot.sh" /usr/local/bin/graphify-boot

# ---------------------------------------------------------------------------
# The one privileged operation the refresh needs.
#
# graphify-refresh runs as the unprivileged graphify user but must restart the
# server when the graph changes — the server reads the graph into memory at
# startup and holds it, so a restart is the only way to pick up a new one. This
# grants exactly that command and nothing else.
#
# visudo -cf validates before the file is live: a malformed sudoers drop-in
# breaks sudo for every user on the box, and doing it here fails the image build
# rather than a production VM.
# ---------------------------------------------------------------------------
cat > /etc/sudoers.d/graphify <<'SUDOERS'
graphify ALL=(root) NOPASSWD: /usr/bin/systemctl restart graphify-mcp.service
SUDOERS
chmod 440 /etc/sudoers.d/graphify
visudo -cf /etc/sudoers.d/graphify

# ---------------------------------------------------------------------------
# systemd units.
# ---------------------------------------------------------------------------
for unit in graphify-boot.service graphify-mcp.service graphify-refresh.service \
            graphify-refresh.timer graphify-refresh-failed.service; do
    install -m 644 "$SCRIPT_DIR/$unit" "/etc/systemd/system/$unit"
done

systemctl daemon-reload

# Enabled, NOT started — there is no /data at bake time.
#
# The whole boot sequence is expressed in the units, so a VM needs no startup
# script and no manual step:
#
#   graphify-boot.service    mounts /data, adds swap, creates the service home
#     -> graphify-mcp.service     Requires= + After= it, so it starts once /data
#                                 is there (and crash-loops harmlessly for the
#                                 first ~2 min until a graph exists)
#     -> graphify-refresh.timer   OnBootSec=2min fires the first refresh, which
#                                 produces that graph
#
# Two units are deliberately NOT enabled:
#   graphify-refresh.service        pulled in by its timer
#   graphify-refresh-failed.service an OnFailure= target, activated on demand
systemctl enable graphify-boot.service
systemctl enable graphify-mcp.service
systemctl enable graphify-refresh.timer

/opt/graphify/venv/bin/graphify --version

echo "graphify ${GRAPHIFY_VERSION} installed (venv /opt/graphify/venv)"
echo "Units enabled but not started - they need /data, mounted by the VM boot script."
