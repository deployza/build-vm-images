#!/bin/bash
# Install the Claude Code CLI, pinned, at /opt/claude/bin/claude. ai-coder
# flavor.
#
# THE NATIVE BINARY, PLACED BY HAND. The official installer
# (claude.ai/install.sh) is per-user: it runs `claude install`, which puts the
# CLI under ~/.local and switches on auto-update. That is wrong here twice.
# ai-coding-server starts `claude` as a dedicated agent user and pins it (it
# checks claude.cli.min_version, and its VM runbook checks every flag against
# the installed build). So this installer does only the installer's download
# step: fetch the release's manifest.json and the linux-x64 binary from the same
# release directory, check the binary's SHA-256 against the manifest, and
# install it root-owned. No user can replace it.
#
# A CHECKSUM, UNLIKE THE OTHER TARBALL INSTALLERS. The release publishes one,
# the official installer checks it, and this binary is what runs agents with an
# API key in their environment. It costs one jq call.
#
# AUTO-UPDATE IS BUILD-OPS' JOB. A bare binary still tries to update itself
# into the RUNNING user's ~/.local. build-ops sets DISABLE_AUTOUPDATER=1 for the
# agent user (managed settings or the launcher), so the agent always runs this
# pinned build.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

CLAUDE_HOME=/opt/claude
RELEASE_URL="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}"
PLATFORM=linux-x64

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

wget -q "${RELEASE_URL}/manifest.json" -O "$WORK/manifest.json"
expected="$(jq -r --arg p "$PLATFORM" '.platforms[$p].checksum // empty' "$WORK/manifest.json")"
[[ "$expected" =~ ^[a-f0-9]{64}$ ]]

wget -q "${RELEASE_URL}/${PLATFORM}/claude" -O "$WORK/claude"
echo "${expected}  $WORK/claude" | sha256sum -c -

install -d -o root -g root -m 755 "$CLAUDE_HOME/bin"
install -o root -g root -m 755 "$WORK/claude" "$CLAUDE_HOME/bin/claude"
ln -sfn "$CLAUDE_HOME/bin/claude" /usr/local/bin/claude

# --version only prints; it does not log in or touch the API. Whatever state it
# leaves in root's home must not be captured into the image.
claude --version
claude --version | grep -q "^${CLAUDE_CODE_VERSION} "
rm -rf /root/.claude /root/.claude.json

echo "Claude Code ${CLAUDE_CODE_VERSION} installed at ${CLAUDE_HOME}/bin/claude."
echo "Not logged in and no API key: build-ops' launcher supplies ANTHROPIC_API_KEY."
