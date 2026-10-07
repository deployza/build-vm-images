#!/bin/bash
# Install Anthropic's sandbox-runtime (`srt`) and the OS pieces it and Claude
# Code's own sandbox need. ai-coder flavor.
#
# WHAT THE SANDBOX IS FOR. ai-coding-server runs every build check (code an
# agent wrote) as `sudo -u <agent user> srt -- <build command>`. Claude Code's
# built-in sandbox, which wraps the agent's own shell commands, uses the same
# engine. On Linux both need:
#
#   bubblewrap   filesystem and namespace isolation
#   socat        the relay behind the network allow-list proxy
#   ripgrep      srt's deny-path detection
#
# srt comes from npm, pinned, into the global prefix /opt/node (root-owned).
# Its pre-built seccomp helpers for x64 ship inside the package, so gcc and
# libseccomp-dev are not needed.
#
# UBUNTU 24.04 AND USER NAMESPACES. 24.04 strips capabilities from user
# namespaces that unprivileged processes create, which breaks bwrap. The
# AppArmor profiles in apparmor-sandbox grant `userns` to bwrap and srt's
# seccomp helper only. The host-wide sysctl stays at its hardened default.
#
# THE BAKE PROVES THE SANDBOX STARTS. A throwaway unprivileged user runs a
# command under srt on the bake VM, which has the same kernel and AppArmor
# setup as the VMs booted from this image. If the profile is wrong, this bake
# fails, rather than every build check on the VM.
#
# NO POLICY IS BAKED. The srt settings and Claude Code sandbox settings are
# generated per run by ai-coding-server from one policy source. The agent user
# that runs them is created by build-ops.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

export DEBIAN_FRONTEND=noninteractive
export npm_config_cache=/tmp/npm-cache npm_config_update_notifier=false npm_config_fund=false

SRT_DIR=/opt/node/lib/node_modules/@anthropic-ai/sandbox-runtime


echo "== OS dependencies =="
apt-get update -y
apt-get install -y apparmor bubblewrap ripgrep socat
rm -rf /var/lib/apt/lists/*
bwrap --version
socat -V | head -n 2


echo "== srt ${SANDBOX_RUNTIME_VERSION} =="
npm install -g "@anthropic-ai/sandbox-runtime@${SANDBOX_RUNTIME_VERSION}"
rm -rf /tmp/npm-cache
ln -sfn /opt/node/bin/srt /usr/local/bin/srt
test "$(node -p "require('${SRT_DIR}/package.json').version")" = "${SANDBOX_RUNTIME_VERSION}"

# The AppArmor profile names the helpers by glob; make sure there is something
# for it to match, so a package layout change fails here, by name.
find "$SRT_DIR/vendor" -type f -name 'apply-seccomp*' | grep -q .


echo "== AppArmor profiles for user namespaces =="
install -o root -g root -m 644 "$SCRIPT_DIR/apparmor-sandbox" /etc/apparmor.d/deployza-sandbox
# Loads it now, for the test below. At boot, apparmor.service loads everything
# in /etc/apparmor.d, so the image needs no other step.
apparmor_parser -r /etc/apparmor.d/deployza-sandbox
sysctl kernel.apparmor_restrict_unprivileged_userns || true


echo "== Prove srt runs as an unprivileged user =="
TEST_USER=srt-bake-test
useradd --create-home --shell /bin/bash "$TEST_USER"
TEST_HOME="$(getent passwd "$TEST_USER" | cut -d: -f6)"
cleanup() { userdel -r "$TEST_USER" 2>/dev/null || true; }
trap cleanup EXIT

# Most restrictive settings: no network, writes only in the cwd.
cat > "$TEST_HOME/srt-settings.json" <<'JSON'
{
  "network": { "allowedDomains": [], "deniedDomains": [] },
  "filesystem": { "denyRead": [], "allowWrite": ["."], "denyWrite": [] }
}
JSON
install -d -o "$TEST_USER" "$TEST_HOME/work" "$TEST_HOME/outside"
chown "$TEST_USER:" "$TEST_HOME/srt-settings.json"

# Checked by EFFECT, not by output: srt echoes the command line it runs, so a
# marker string in stdout would match even if the sandbox never started.
#   1. a write inside the cwd must land (the sandbox started and ran it)
#   2. a write to a dir the user owns, but outside the cwd, must not
runuser -u "$TEST_USER" -- env HOME="$TEST_HOME" bash -c '
  cd "$HOME/work"
  srt --settings "$HOME/srt-settings.json" "touch inside-ok"
  srt --settings "$HOME/srt-settings.json" "touch $HOME/outside/escaped" || true
'
test -f "$TEST_HOME/work/inside-ok"
test ! -e "$TEST_HOME/outside/escaped"

cleanup
trap - EXIT

echo "srt ${SANDBOX_RUNTIME_VERSION} installed and verified as an unprivileged user."
echo "bubblewrap, socat and ripgrep are installed; the AppArmor profile is"
echo "/etc/apparmor.d/deployza-sandbox. No sandbox policy is baked."
