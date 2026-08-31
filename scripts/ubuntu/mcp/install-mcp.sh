#!/bin/bash
# Install the MCP code knowledge-graph server (graphify) as systemd services.
#
# graphify ships as the PyPI package `graphifyy`. This bakes it into a
# self-contained venv under /opt/mcp, creates the unprivileged service user,
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
# units, helper scripts and mcp.env, because none of them are shared with
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
# --no-create-home is deliberate. The home is /data/mcp, which does not exist at
# bake time; mcp-boot creates and chowns it per instance. That location is not a
# preference — graphify's `global add` writes to Path.home()/".graphify",
# hardcoded upstream with no flag to redirect it, so the home has to be inside
# /data alongside the rest of the state.
# ---------------------------------------------------------------------------
adduser --system --group --disabled-password --no-create-home \
    --home /data/mcp --shell /usr/sbin/nologin mcp

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
mkdir -p /opt/mcp
python3 -m venv /opt/mcp/venv
/opt/mcp/venv/bin/pip install --no-cache-dir --upgrade pip
/opt/mcp/venv/bin/pip install --no-cache-dir \
    "graphifyy[mcp,terraform,sql]==${GRAPHIFY_VERSION}"

# ---------------------------------------------------------------------------
# Configuration and helper binaries (installer-owned copies, uploaded alongside
# this script).
# ---------------------------------------------------------------------------
mkdir -p /etc/mcp
install -m 644 "$SCRIPT_DIR/mcp.env" /etc/mcp/mcp.env

# Every one of these is invoked as a command — by a systemd unit, by git's
# GIT_ASKPASS, or by another helper — so each is named in-tree exactly as it is
# installed, with no extension. See CLAUDE.md, "Why some scripts have no .sh".
for helper in gcp-secret mcp-serve mcp-refresh mcp-md-graph \
              mcp-git-askpass mcp-log-failure mcp-boot; do
    install -m 755 "$SCRIPT_DIR/$helper" "/usr/local/bin/$helper"
done

# The vendored Markdown extractor, imported by mcp-md-graph from its own
# directory (the script puts its realpath on sys.path). Installed 644, not 755:
# it is a module, never executed directly.
#
# Vendored rather than imported from the venv because reaching graphify's
# extractor needs four PRIVATE symbols, one of which failed silently when absent.
# See the file's header. It does NOT move when GRAPHIFY_VERSION changes — after
# any upgrade, run the drift check:
#
#   /opt/mcp/venv/bin/python /usr/local/bin/mcp-md-graph \
#       /data/repos/<repo> --self-test
install -m 644 "$SCRIPT_DIR/mcp_md_extract.py" \
    /usr/local/bin/mcp_md_extract.py

# ---------------------------------------------------------------------------
# The one privileged operation the refresh needs.
#
# mcp-refresh runs as the unprivileged mcp user but must restart the
# server when the graph changes — the server reads the graph into memory at
# startup and holds it, so a restart is the only way to pick up a new one. This
# grants exactly that command and nothing else.
#
# visudo -cf validates before the file is live: a malformed sudoers drop-in
# breaks sudo for every user on the box, and doing it here fails the image build
# rather than a production VM.
# ---------------------------------------------------------------------------
cat > /etc/sudoers.d/mcp <<'SUDOERS'
mcp ALL=(root) NOPASSWD: /usr/bin/systemctl restart mcp.service
SUDOERS
chmod 440 /etc/sudoers.d/mcp
visudo -cf /etc/sudoers.d/mcp

# ---------------------------------------------------------------------------
# systemd units.
# ---------------------------------------------------------------------------
for unit in mcp-boot.service mcp.service mcp-refresh.service \
            mcp-refresh.timer mcp-refresh-failed.service; do
    install -m 644 "$SCRIPT_DIR/$unit" "/etc/systemd/system/$unit"
done

systemctl daemon-reload

# Enabled, NOT started — there is no /data at bake time.
#
# The whole boot sequence is expressed in the units, so a VM needs no startup
# script and no manual step:
#
#   mcp-boot.service    mounts /data, adds swap, creates the service home
#     -> mcp.service     Requires= + After= it, so it starts once /data
#                                 is there (and crash-loops harmlessly for the
#                                 first ~2 min until a graph exists)
#     -> mcp-refresh.timer   OnBootSec=2min fires the first refresh, which
#                                 produces that graph
#
# Two units are deliberately NOT enabled:
#   mcp-refresh.service        pulled in by its timer
#   mcp-refresh-failed.service an OnFailure= target, activated on demand
systemctl enable mcp-boot.service
systemctl enable mcp.service
systemctl enable mcp-refresh.timer

/opt/mcp/venv/bin/graphify --version

# ---------------------------------------------------------------------------
# Vendored-extractor drift check — FAILS THE IMAGE BUILD, deliberately.
#
# mcp_md_extract.py is a frozen copy of graphify's Markdown extractor. It
# does not move when GRAPHIFY_VERSION does, so without this an upgrade would
# silently ship stale extraction behaviour — and "silently" is the failure mode
# this whole helper exists to avoid.
#
# The fixture is written here rather than pointed at a repo so the check is
# self-contained and identical on every build. It exercises the parts most likely
# to drift: frontmatter, nested headings, a fenced block, and all three link
# forms (inline, reference-style, wikilink).
# ---------------------------------------------------------------------------
FIXTURE="$(mktemp -d)"
cat > "$FIXTURE/index.md" <<'FIX'
---
title: "Index"
tags: [a, b]
nested:
  key: value
---
# Index
Inline [link](./other.md), a [[wikilink]], and a ref [label].

[label]: ./other.md

## Section
```
# not a heading
```
### Deeper
FIX
cat > "$FIXTURE/other.md" <<'FIX'
# Other
Back to [Index](./index.md).
FIX
# The [[wikilink]] above resolves to this file, so the check covers the wikilink
# path rather than only its dangling-target branch.
cat > "$FIXTURE/wikilink.md" <<'FIX'
# Wikilink target
FIX

/opt/mcp/venv/bin/python /usr/local/bin/mcp-md-graph \
    "$FIXTURE" --self-test
rm -rf "$FIXTURE"

echo "graphify ${GRAPHIFY_VERSION} installed (venv /opt/mcp/venv)"
echo "Units enabled but not started - they need /data, mounted by the VM boot script."
