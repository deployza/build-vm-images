#!/bin/bash
# -----------------------------------------------------------------------------
# graphify-boot — per-instance provisioning, run once per boot by
# graphify-boot.service before the server and refresh units start.
#
# Baked to /usr/local/bin/graphify-boot. This is the graphify flavor's equivalent
# of vm-startup.sh: the image cannot bake it away, because everything it touches
# belongs to the DATA DISK, which does not exist at bake time.
#
#   1. format (first boot only) and mount the data disk at /data
#   2. a 2 GB swapfile on it
#   3. the service user's HOME on it — mandatory, see setup_service_home
#
# It deliberately does NOT install software and does NOT start the other units.
# Software is baked by install-graphify.sh; start-up ordering is systemd's job —
# graphify-mcp.service and graphify-refresh.service both declare
# Requires=/After= on graphify-boot.service, so they run once this succeeds and
# not at all if it fails.
#
# Runs on EVERY boot, so every step is idempotent.
#
# Logs: sudo journalctl -u graphify-boot.service -b
# -----------------------------------------------------------------------------
set -euxo pipefail

log() { echo "[graphify-boot] $*"; }

# DATA_DEV must match the attached_disk device_name set by the consuming
# Terraform (build-terraform builds/graphify.tf). The rest match the paths in
# /etc/graphify/graphify.env.
readonly DATA_DEV="/dev/disk/by-id/google-graphify-data"
readonly DATA_MNT="/data"
readonly SVC_USER="graphify"
readonly SVC_HOME="/data/graphify"
readonly REPOS_DIR="/data/repos"
readonly SWAPFILE="/data/swapfile"
readonly SWAP_SIZE="2G"
# One line per applied migration. On the DATA disk, so it survives an image swap
# — which is the whole point: these run once per data disk, not once per boot.
readonly MIGRATIONS="/data/graphify/.migrations"

# =============================================================================
# 1. Data disk
# =============================================================================
mount_data_disk() {
    # blkid is the guard against reformatting a disk that already holds the
    # graph: it succeeds only once a filesystem is present. Never add -F to the
    # mkfs below — that would defeat this check on any disk blkid cannot read.
    if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
        log "no filesystem on ${DATA_DEV} — formatting (first boot)"
        mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "$DATA_DEV"
    fi

    mkdir -p "$DATA_MNT"

    # Recorded by UUID, not by the by-id path: that path depends on the attached
    # disk's device_name, and a mismatch would mount the wrong volume silently.
    # nofail keeps a missing disk from dropping the box into emergency mode,
    # where even IAP SSH cannot reach it to fix the problem.
    local uuid
    uuid="$(blkid -s UUID -o value "$DATA_DEV")"
    if ! grep -q "^UUID=${uuid} " /etc/fstab; then
        echo "UUID=${uuid} ${DATA_MNT} ext4 discard,defaults,nofail 0 2" >> /etc/fstab
        # Let systemd regenerate its fstab-derived mount units so later boots and
        # `systemctl status data.mount` agree with what is actually mounted.
        systemctl daemon-reload
    fi

    mountpoint -q "$DATA_MNT" || mount "$DATA_MNT"
}

# =============================================================================
# 2. Swap
# =============================================================================
#
# A cushion, not a crutch. On the measured numbers (72 MB peak across 22 repos,
# ~300 MB projected at ~200) it should never be touched — it exists so an
# unexpectedly large merge degrades into slowness instead of an OOM kill.
#
# On the data disk deliberately, to keep write churn off the boot volume.
setup_swap() {
    if [[ ! -f "$SWAPFILE" ]]; then
        log "creating ${SWAP_SIZE} swapfile at ${SWAPFILE}"
        # fallocate leaves no holes on ext4, which swapon requires.
        fallocate -l "$SWAP_SIZE" "$SWAPFILE"
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE"
    fi

    grep -q "^${SWAPFILE} " /etc/fstab \
        || echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab

    swapon --show=NAME --noheadings | grep -qx "$SWAPFILE" \
        || swapon "$SWAPFILE"
}

# =============================================================================
# 3. Service user's home
# =============================================================================
#
# NOT optional and NOT arbitrary. graphify's `global add` writes to
# Path.home()/".graphify" — hardcoded upstream, with no flag to redirect it.
# install-graphify.sh creates the user with --home /data/graphify
# --no-create-home precisely so the directory is made here, after the disk is
# mounted. A home on the boot disk would put the merged graph there, to be
# destroyed by the next image swap — silently, with no error.
setup_service_home() {
    mkdir -p "${SVC_HOME}/.graphify" "$REPOS_DIR"
    chown -R "${SVC_USER}:${SVC_USER}" "$SVC_HOME" "$REPOS_DIR"
    chmod 750 "$SVC_HOME"

    # The clone tree must be writable by the service user: graphify writes
    # graphify-out/ INTO each scanned repo, not into the working directory.
    chmod 750 "$REPOS_DIR"
}

# =============================================================================
# 4. One-shot data-disk migrations
# =============================================================================
#
# WHY THIS EXISTS. The boot disk is replaced wholesale by an image swap, but the
# DATA disk survives — so a change to what the software indexes cannot, on its
# own, reach state that is already on that disk. There is no SSH to this VM
# (§7 of graphify-mcp.md), so "just go and delete the file" is not available.
#
# A migration is a named line in $MIGRATIONS. Adding a new one is: pick a name
# that will never be reused, and put its body behind `if needs_migration <name>`.

# needs_migration <name>: true exactly once per data disk, then never again.
# The stamp is written BEFORE the body runs, deliberately — a migration that
# fails half-way must not re-run on every subsequent boot and wedge the box in a
# loop. The failure is visible in the journal; a retry is a human decision.
needs_migration() {
    local name="$1"
    if [[ -f "$MIGRATIONS" ]] && grep -qxF "$name" "$MIGRATIONS"; then
        return 1
    fi
    echo "$name" >> "$MIGRATIONS"
    chown "${SVC_USER}:${SVC_USER}" "$MIGRATIONS"
    chmod 640 "$MIGRATIONS"
    return 0
}

apply_migrations() {
    # md-indexing-v1 (image 1-2). The refresh gained a Markdown pass, so every
    # repo's *.md now belongs in the graph — but Gate 1 only rescans repos whose
    # GitHub pushed_at is newer than the watermark. Every repo already cloned
    # here is unchanged, so without this the Markdown pass would run over nothing:
    # each repo would keep its code-only subgraph until someone happened to push
    # to it, and a quiet repo would never gain its docs at all. `build-docs`,
    # newly un-excluded, would not even be cloned.
    #
    # Clearing the watermark makes the next refresh treat every repo as changed —
    # one full pass (~5 min of CPU, clones already present), once.
    if needs_migration "md-indexing-v1"; then
        log "migration md-indexing-v1: clearing the refresh watermark so the"
        log "  next run re-indexes every repo and picks up Markdown"
        rm -f "${SVC_HOME}/last-run"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    mount_data_disk
    setup_swap
    setup_service_home
    apply_migrations
    log "per-instance provisioning complete; systemd starts the units from here"
}

main "$@"
