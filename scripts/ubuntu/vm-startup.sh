#!/bin/bash
# -----------------------------------------------------------------------------
# vm-startup.sh — boot-time launcher baked into the VM images, run by the
# vm-startup.service systemd unit on every boot. (The Docker images carry a
# sibling copy, docker-startup.sh, that differs only in APP_PLATFORM.)
#
# It resolves three parameters, clones a git repo, and runs the app's own
# per-app script from inside that clone:
#
#   APP_REPO  git URL to clone   (FIXED in image; not overridable per-instance)
#   APP_NAME  app identifier     (REQUIRED — no default; boot fails if unset)
#   APP_ENV   deploy environment (REQUIRED — no default; boot fails if unset)
#
# After cloning APP_REPO it runs  <clone>/vm/<APP_NAME>.sh  and passes APP_ENV to
# it as "$1". APP_NAME already selects which script runs (it is the script's
# basename), so it is not passed as an argument. This is the VM copy of the
# launcher, so it always runs the vm/ subdir of the app repo (the Docker images
# carry a sibling docker-startup.sh that runs docker/ instead).
#
# Parameter source for APP_NAME / APP_ENV — checked in this order, first hit wins:
#   1. Environment variables (e.g. an EnvironmentFile drop-in on the unit).
#   2. GCE instance metadata attributes (the normal source on a VM).
# There is NO default for either — an unset value fails the boot with a clear
# error rather than silently deploying a placeholder app/env. (APP_REPO is fixed
# in the image and not resolved from these sources.)
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

# =============================================================================
# Variable declarations
# =============================================================================
# All variables are declared here up front. Static values are set inline;
# values that depend on runtime input (the resolved APP_NAME / APP_ENV) are
# declared empty here and populated in main() as they become available. The
# comment on each explains where its value comes from.

# --- Fixed in the image -------------------------------------------------------
# APP_REPO is fixed in the image — every VM clones the standard app-install repo.
# It is intentionally NOT overridable per-instance. APP_NAME and APP_ENV, by
# contrast, are REQUIRED and per-instance (see resolve_required) so a misconfigured
# boot fails loudly instead of deploying a placeholder.
readonly APP_REPO="https://github.com/deployza/build-app-install.git"

# Platform this launcher runs on: selects which subdir of the app repo holds the
# app script (repo layout is <repo>/vm/<APP_NAME>.sh and <repo>/docker/<APP_NAME>.sh).
# This is the VM copy of the launcher, so it is fixed to "vm" — the Docker images
# carry a sibling docker-startup.sh that sets it to "docker". It is NOT read from
# the environment or metadata: this script only ever runs on a VM.
readonly APP_PLATFORM="vm"

# GCE instance-metadata endpoint for resolving REQUIRED parameters.
readonly METADATA_BASE="http://metadata.google.internal/computeMetadata/v1/instance/attributes"

# All deploy artifacts live under one shared root so a human browsing the box
# sees everything for this deploy in one place:
#   /tmp/deployza/
#   ├── repo/            the git clone (owned here — this is the universal
#   │                    vm-startup.sh, identical on every VM)
#   └── <APP_NAME>/      the app's own staging dir, created & owned by
#                        <APP_NAME>.sh (see that script)
# The directory boundary mirrors the script boundary: vm-startup.sh owns repo/,
# each app script owns its own /tmp/deployza/<APP_NAME>/ sibling. The root is a
# stable path (not mktemp) so it self-cleans on re-clone instead of leaking a
# new dir per boot.
readonly DEPLOY_ROOT="/tmp/deployza"
readonly CLONE_DIR="${DEPLOY_ROOT}/repo"

# --- Populated in main() from the resolved parameters -------------------------
APP_NAME=""             # required parameter (env var or metadata); no default
APP_ENV=""              # required parameter (env var or metadata); no default
APP_SCRIPT=""           # ${CLONE_DIR}/${APP_PLATFORM}/${APP_NAME}.sh

# =============================================================================
# Functions
# =============================================================================

# metadata_attr <key>: read a single GCE instance-metadata attribute. Returns
# empty (never fails the script) if the metadata server is unreachable or if the
# attribute is absent.
metadata_attr() {
  local key="$1"
  curl -fsS --max-time 3 -H "Metadata-Flavor: Google" \
    "${METADATA_BASE}/${key}" 2>/dev/null || true
}

# resolve_required <name>: resolve a REQUIRED parameter — env var wins, then
# metadata. There is no default; if neither source supplies a value, log a clear
# error and fail the boot. $1 is the variable name, which doubles as the env var
# name and the metadata attribute key.
resolve_required() {
  local name="$1" value
  value="${!name:-}"
  if [[ -z "$value" ]]; then
    value="$(metadata_attr "$name")"
  fi
  if [[ -z "$value" ]]; then
    log "ERROR: required parameter ${name} is not set." >&2
    log "       Provide it via an environment variable or GCE instance" >&2
    log "       metadata attribute '${name}' (e.g. --metadata ${name}=...)." >&2
    exit 1
  fi
  printf '%s' "$value"
}

# resolve_params: populate APP_NAME / APP_ENV from env or metadata and log the
# full resolved parameter set for the journal.
resolve_params() {
  APP_NAME="$(resolve_required APP_NAME)"
  APP_ENV="$(resolve_required APP_ENV)"

  log "APP_PLATFORM=${APP_PLATFORM}"
  log "APP_REPO=${APP_REPO}"
  log "APP_NAME=${APP_NAME}"
  log "APP_ENV=${APP_ENV}"
}

# clone_repo: clone the app repo into a fresh working directory under the shared
# deploy root. The clone dir is removed first so a re-boot re-clones cleanly
# instead of layering onto a stale tree.
clone_repo() {
  log "Cloning ${APP_REPO} into ${CLONE_DIR} ..."
  rm -rf "${CLONE_DIR:?}"
  mkdir -p "$DEPLOY_ROOT"
  git clone --depth 1 "$APP_REPO" "$CLONE_DIR"
}

# locate_app_script: resolve and validate the app's own script inside the clone:
# <clone>/<APP_PLATFORM>/<APP_NAME>.sh. The app repo keeps platform-specific
# scripts side by side (vm/ and docker/), because the VM and container deploy
# steps differ (service user, hot-deploy vs. plain drop); APP_PLATFORM picks the
# right one. Fail loudly if the expected script is missing.
locate_app_script() {
  APP_SCRIPT="${CLONE_DIR}/${APP_PLATFORM}/${APP_NAME}.sh"

  if [[ ! -f "$APP_SCRIPT" ]]; then
    log "ERROR: app script not found at ${APP_SCRIPT}" >&2
    log "       (looked in the '${APP_PLATFORM}/' subdir of ${APP_REPO})" >&2
    exit 1
  fi

  chmod +x "$APP_SCRIPT" 2>/dev/null || true
}

# run_app_script: run the app's deploy script and RETURN when it finishes. The
# app script's contract is "deploy, then return" — it is a deploy step, not the
# long-running process. vm-startup.service is Type=oneshot: this returns, the
# unit goes "active (exited)", and the real server (Tomcat) is a separate
# systemd unit.
run_app_script() {
  log "Running ${APP_SCRIPT} ${APP_ENV}"
  bash "$APP_SCRIPT" "$APP_ENV"
}

# =============================================================================
# Main
# =============================================================================
main() {
  resolve_params
  clone_repo
  locate_app_script
  run_app_script

  log "App script finished; vm-startup done."
}

main "$@"
