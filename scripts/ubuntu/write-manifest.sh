#!/bin/bash
# Bake /etc/image-manifest.txt into the image (build-system.md §5). This is the
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

  # Ansible lives in a venv; the pip freeze records the collection package and
  # the core separately (both pinned), which `ansible --version` alone does not.
  if [ -x /opt/ansible/venv/bin/ansible ]; then
    echo "== ansible --version =="
    /opt/ansible/venv/bin/ansible --version 2>&1 || true
    echo
    echo "== ansible venv packages =="
    /opt/ansible/venv/bin/pip freeze 2>/dev/null || true
    echo
  fi

  if command -v semaphore >/dev/null 2>&1; then
    echo "== semaphore version =="
    semaphore version 2>&1 || true
    echo
  fi

  if command -v clickhouse-server >/dev/null 2>&1; then
    echo "== clickhouse-server --version =="
    clickhouse-server --version 2>&1 || true
    echo
  fi

  # The plugin list matters as much as Grafana's version: a datasource plugin
  # that is missing or too old is invisible until someone opens a dashboard.
  if command -v grafana >/dev/null 2>&1; then
    echo "== grafana --version =="
    grafana --version 2>&1 || true
    echo
    echo "== grafana plugins =="
    grafana cli --pluginsDir /var/lib/grafana/plugins plugins ls 2>&1 || true
    echo
  fi

  # ai-coding flavor: the build toolchains and the agent runtime. Each is
  # pinned in versions.env; this records what actually landed.
  if [ -x /opt/maven/bin/mvn ]; then
    echo "== mvn --version =="
    JAVA_HOME=/opt/java/latest /opt/maven/bin/mvn --version 2>&1 || true
    echo
  fi

  if [ -x /opt/node/bin/node ]; then
    echo "== node --version / npm --version =="
    /opt/node/bin/node --version 2>&1 || true
    /opt/node/bin/npm --version 2>&1 || true
    echo
    echo "== global npm packages (srt, playwright) =="
    /opt/node/bin/npm ls -g --depth=0 2>&1 || true
    echo
  fi

  if [ -x /opt/claude/bin/claude ]; then
    echo "== claude --version =="
    /opt/claude/bin/claude --version 2>&1 || true
    rm -rf /root/.claude /root/.claude.json
    echo
  fi

  if command -v bwrap >/dev/null 2>&1; then
    echo "== bwrap --version / AppArmor userns profile =="
    bwrap --version 2>&1 || true
    ls -l /etc/apparmor.d/deployza-sandbox 2>&1 || true
    echo
  fi

  # The browser build matters as much as the Playwright version: a repo on a
  # different Playwright release cannot use it.
  if [ -d /opt/ms-playwright ]; then
    echo "== playwright browsers (/opt/ms-playwright) =="
    ls -1 /opt/ms-playwright 2>&1 || true
    echo
  fi

  if [ -f /opt/reposilite/reposilite.jar ]; then
    echo "== reposilite =="
    cat /opt/reposilite/VERSION 2>/dev/null || true
    echo
  fi

  # The distro interpreter is the only Python on every flavor (install-basics.sh);
  # apt, gcloud and the baked venvs all run on it.
  echo "== python3 (/usr/bin/python3, distro) =="
  /usr/bin/python3 --version 2>&1 || true
  echo

  # mkdocs lives in a venv, not on PATH (mcp flavor from 1-6) — same reasoning
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

  # The collector is baked on every flavor but is INERT until a config is
  # pushed, so record both the version and which config is live. "is this box
  # actually shipping telemetry, and to where" is otherwise invisible: a
  # collector with the baked nop config looks identical, from the outside, to
  # one that is healthy and exporting.
  if [ -x /opt/otelcol/bin/otelcol-contrib ]; then
    echo "== otelcol-contrib --version =="
    /opt/otelcol/bin/otelcol-contrib --version 2>&1 || true
    echo
    echo "== otelcol config (first line identifies base vs pushed) =="
    head -n 1 /etc/otelcol/config.yaml 2>/dev/null || true
    echo
  fi

  # The Cloud SQL Auth Proxy is baked on every flavor but ships with NO instance
  # and its unit NOT enabled, so record both the version and whether this VM has
  # actually been pointed at a database. "does this box reach Cloud SQL, and
  # which instance" is otherwise a two-command investigation on a VM where the
  # answer is usually "no".
  if [ -x /opt/cloud-sql-proxy/bin/cloud-sql-proxy ]; then
    echo "== cloud-sql-proxy --version =="
    /opt/cloud-sql-proxy/bin/cloud-sql-proxy --version 2>&1 || true
    echo
    echo "== cloud-sql-proxy instances (empty => as baked, connects nowhere) =="
    grep '^CSP_INSTANCES=' /etc/cloud-sql-proxy/env 2>/dev/null || true
    systemctl is-enabled cloud-sql-proxy.service 2>&1 || true
    echo
  fi

  echo "== dpkg packages =="
  dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort
} > "$MANIFEST"

chmod 644 "$MANIFEST"
cat "$MANIFEST"
