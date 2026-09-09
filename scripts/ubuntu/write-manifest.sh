#!/bin/bash
# Bake /etc/image-manifest.txt into the image (build-design.md §9). This is the
# source of truth that cannot drift: `cat /etc/image-manifest.txt` on any VM
# tells you exactly what is installed.
#
# GIT_SHA and IMAGE_FLAVOR are passed in as environment_vars from the Packer
# provisioner.
set -euxo pipefail

MANIFEST=/etc/image-manifest.txt

{
  echo "image-flavor: ${IMAGE_FLAVOR:-unknown}"
  echo "git-sha:      ${GIT_SHA:-unknown}"
  echo "built-at:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo

  if command -v java >/dev/null 2>&1 || [ -x /opt/java/latest/bin/java ]; then
    echo "== java -version =="
    /opt/java/latest/bin/java -version 2>&1 || true
    echo
  fi

  if [ -d /home/tomcat/instance ]; then
    echo "== tomcat version =="
    cat /home/tomcat/instance/RELEASE-NOTES 2>/dev/null | head -n 5 || true
    /opt/java/latest/bin/java -cp /home/tomcat/instance/lib/catalina.jar org.apache.catalina.util.ServerInfo 2>/dev/null || true
    echo
  fi

  if command -v mysql >/dev/null 2>&1; then
    echo "== mysql --version =="
    mysql --version 2>&1 || true
    echo
  fi

  if command -v nginx >/dev/null 2>&1; then
    echo "== nginx -v =="
    nginx -v 2>&1 || true
    echo
  fi

  if command -v gitea >/dev/null 2>&1; then
    echo "== gitea --version =="
    gitea --version 2>&1 || true
    echo
  fi

  # mkdocs lives in a venv, not on PATH (nginx flavor only) — same reasoning
  # as graphify below: the plugin set matters more than the bare version, and
  # a plugin-version mismatch against www-apidocs/requirements.txt is
  # otherwise invisible until `mkdocs build --strict` fails on the VM.
  if [ -x /opt/mkdocs/venv/bin/mkdocs ]; then
    echo "== mkdocs --version =="
    /opt/mkdocs/venv/bin/mkdocs --version 2>&1 || true
    echo
    echo "== mkdocs venv packages =="
    /opt/mkdocs/venv/bin/pip freeze 2>/dev/null || true
    echo
  fi

  # graphify lives in a venv, not on PATH, so probe the interpreter directly.
  # The pip freeze matters more than the version string: the tree-sitter grammar
  # set is what determines which repos index to anything, and it is invisible
  # otherwise (a missing HCL grammar yields 0 nodes silently, not an error).
  if [ -x /opt/mcp/venv/bin/graphify ]; then
    echo "== graphify --version =="
    /opt/mcp/venv/bin/graphify --version 2>&1 || true
    echo
    echo "== graphify venv packages =="
    /opt/mcp/venv/bin/pip freeze 2>/dev/null || true
    echo
  fi

  echo "== dpkg packages =="
  dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort
} > "$MANIFEST"

chmod 644 "$MANIFEST"
cat "$MANIFEST"
