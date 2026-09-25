#!/bin/bash
# Install Ansible into a venv at /opt/ansible/venv and put its commands on PATH.
# ops flavor.
#
# A VENV, FOR THE SAME REASON AS install-mkdocs.sh AND install-mcp.sh. Ubuntu's
# python3 is externally managed (PEP 668) and refuses a bare `pip install`, and
# Ubuntu's own `ansible` apt package trails upstream by a year or more with no
# way to pin a patch. PyPI is the only place an exact ansible + ansible-core
# pair can be named.
#
# BUILT FROM THE DISTRO python3, not the pinned CPython: install-python.sh runs
# last in every template, so /opt/python does not exist yet when this runs.
# That is fine — both pins need Python >= 3.12, which is what Ubuntu 24.04 ships.
#
# ON PATH, UNLIKE mkdocs/graphify. Those venvs are invoked by absolute path from
# units this repo owns. Ansible is invoked by Semaphore, which runs
# `ansible-playbook` / `ansible-galaxy` by name, and by a human at a shell. So
# the entry points are symlinked into /usr/local/bin. A symlinked venv script
# still runs on the venv's interpreter (its shebang is absolute), so this does
# not leak the venv's packages onto the system python.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

ANSIBLE_HOME=/opt/ansible
ANSIBLE_VENV="${ANSIBLE_HOME}/venv"

# python3-venv is also installed by install-basics.sh; repeated so this
# installer stands on its own (same stance as install-mkdocs.sh). sshpass lets
# Semaphore use password-type SSH keys; without it those tasks fail at run time
# with a message that does not mention sshpass until you read far enough.
apt-get update -y
apt-get install -y python3 python3-venv sshpass
rm -rf /var/lib/apt/lists/*

mkdir -p "$ANSIBLE_HOME"
python3 -m venv "$ANSIBLE_VENV"
"$ANSIBLE_VENV/bin/pip" install --no-cache-dir --upgrade pip
"$ANSIBLE_VENV/bin/pip" install --no-cache-dir \
    "ansible==${ANSIBLE_VERSION}" \
    "ansible-core==${ANSIBLE_CORE_VERSION}"

# Every ansible* entry point the venv has, rather than a hand-kept list that
# goes stale when ansible-core adds or drops one.
for bin in "$ANSIBLE_VENV"/bin/ansible*; do
  ln -sfn "$bin" "/usr/local/bin/$(basename "$bin")"
done

# Fail the bake if what got installed is not what was pinned. pip would have
# refused an impossible pair, but not a silently different core.
got_core="$("$ANSIBLE_VENV/bin/python" -c 'import ansible.release as r; print(r.__version__)')"
test "$got_core" = "$ANSIBLE_CORE_VERSION"

# Resolved through PATH on purpose: this is how Semaphore will find it.
ansible --version
ansible-playbook --version >/dev/null
ansible-galaxy --version >/dev/null

echo "ansible ${ANSIBLE_VERSION} (core ${ANSIBLE_CORE_VERSION}) installed in ${ANSIBLE_VENV}"
echo "Commands are symlinked into /usr/local/bin."
