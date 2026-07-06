#!/bin/bash
# -----------------------------------------------------------------------------
# vm-startup.sh — boot-time launcher baked into the VM images, run by the
# vm-startup.service systemd unit on every boot. (The Docker images carry a
# sibling copy, docker-startup.sh, that differs only in APP_PLATFORM.)
#
# It resolves three parameters, clones a git repo, and runs the app's own
# per-app script from inside that clone:
#
#   APP_REPO  git URL to clone   (default: https://github.com/deployza/build-vm-scripts.git)
#   APP_NAME  app identifier     (default: default-app)
#   APP_ENV   deploy environment (default: development)
#
# After cloning APP_REPO it runs  <clone>/<APP_PLATFORM>/<APP_NAME>.sh  and passes
# APP_NAME and APP_ENV to it as "$1" and "$2". APP_PLATFORM (vm) is baked in by
# the vm-startup.service unit and selects the vm/ subdir of the app repo.
#
# Parameter source — checked in this order, first hit wins:
#   1. Environment variables (e.g. an EnvironmentFile drop-in on the unit).
#   2. GCE instance metadata attributes (the normal source on a VM).
#   3. The built-in defaults above.
#
# Logs — this script logs via log() to stdout, so its output (and the app
# script's, since that runs as a child) lands in the systemd journal under the
# vm-startup.service unit. On the VM:
#   sudo journalctl -u vm-startup.service        # all output from the unit
#   sudo journalctl -u vm-startup.service -b      # just this boot
#   sudo journalctl -u vm-startup.service -f      # follow live
# Its own lines are prefixed "[vm-startup]". Because it runs at boot, the output
# also appears in the GCE serial console:
#   gcloud compute instances get-serial-port-output <instance>
# -----------------------------------------------------------------------------
set -euo pipefail

log() { echo "[vm-startup] $*"; }

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
DEFAULT_APP_REPO="https://github.com/deployza/build-vm-scripts.git"
DEFAULT_APP_NAME="default-app"
DEFAULT_APP_ENV="development"

# Platform this launcher runs on: selects which subdir of the app repo holds the
# app script (repo layout is <repo>/vm/<APP_NAME>.sh and <repo>/docker/<APP_NAME>.sh).
# This is baked into the IMAGE, not supplied by the user: the VM's systemd unit
# sets APP_PLATFORM=vm; the Dockerfile sets APP_PLATFORM=docker. Default to "vm"
# so this launcher resolves correctly even if the unit's Environment= is missing.
APP_PLATFORM="${APP_PLATFORM:-vm}"

METADATA_BASE="http://metadata.google.internal/computeMetadata/v1/instance/attributes"

# Read a single GCE instance-metadata attribute. Returns empty (never fails the
# script) if the metadata server is unreachable or if the attribute is absent.
metadata_attr() {
  local key="$1"
  curl -fsS --max-time 3 -H "Metadata-Flavor: Google" \
    "${METADATA_BASE}/${key}" 2>/dev/null || true
}

# Resolve one parameter: env var wins, then metadata, then the default.
# $1 = variable name (also the env var name and the metadata attribute key)
# $2 = default value
resolve() {
  local name="$1" default="$2" value
  value="${!name:-}"
  if [[ -z "$value" ]]; then
    value="$(metadata_attr "$name")"
  fi
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  printf '%s' "$value"
}

APP_REPO="$(resolve APP_REPO "$DEFAULT_APP_REPO")"
APP_NAME="$(resolve APP_NAME "$DEFAULT_APP_NAME")"
APP_ENV="$(resolve APP_ENV  "$DEFAULT_APP_ENV")"

log "APP_PLATFORM=${APP_PLATFORM}"
log "APP_REPO=${APP_REPO}"
log "APP_NAME=${APP_NAME}"
log "APP_ENV=${APP_ENV}"

# -----------------------------------------------------------------------------
# Clone the app repo into a fresh working directory
# -----------------------------------------------------------------------------
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vm-startup.XXXXXX")"
CLONE_DIR="${WORK_DIR}/repo"

log "Cloning ${APP_REPO} into ${CLONE_DIR} ..."
git clone --depth 1 "$APP_REPO" "$CLONE_DIR"

# -----------------------------------------------------------------------------
# Execute the app's own script: <clone>/<APP_PLATFORM>/<APP_NAME>.sh APP_NAME APP_ENV
# The app repo keeps platform-specific scripts side by side (vm/ and docker/),
# because the VM and container deploy steps differ (service user, hot-deploy vs.
# plain drop). APP_PLATFORM picks the right one.
# -----------------------------------------------------------------------------
APP_SCRIPT="${CLONE_DIR}/${APP_PLATFORM}/${APP_NAME}.sh"

if [[ ! -f "$APP_SCRIPT" ]]; then
  log "ERROR: app script not found at ${APP_SCRIPT}" >&2
  log "       (looked in the '${APP_PLATFORM}/' subdir of ${APP_REPO})" >&2
  exit 1
fi

chmod +x "$APP_SCRIPT" 2>/dev/null || true

# Run the app's deploy script and RETURN when it finishes. The app script's
# contract is "deploy, then return" — it is a deploy step, not the long-running
# process. vm-startup.service is Type=oneshot: this returns, the unit goes
# "active (exited)", and the real server (Tomcat) is a separate systemd unit.
log "Running ${APP_SCRIPT} ${APP_NAME} ${APP_ENV}"
bash "$APP_SCRIPT" "$APP_NAME" "$APP_ENV"

log "App script finished; vm-startup done."
