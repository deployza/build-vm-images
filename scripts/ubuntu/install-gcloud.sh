#!/bin/bash
# Google Cloud CLI. Runs on EVERY flavor, as its own provisioner line right
# after install-basics.sh.
#
# SPLIT OUT OF install-basics.sh, DELIBERATELY. It is a third-party apt repo
# with its own signing key, not a distro package, so it carries a failure mode
# the rest of basics does not: a key or repo URL that changes upstream breaks
# every bake, and the build log should name the step that broke rather than
# "install-basics.sh". Same reasoning as install-python.sh being its own file
# and its own provisioner line.
#
# WHAT DEPENDS ON IT. The pushed app-deploy scripts use `gcloud`/`gsutil` to
# pull the app's WAR and conf from GCS, the mcp flavor's gcp-secret helper reads
# Secret Manager through it, and it is the first thing anyone SSHing into a VM
# reaches for. It is baseline, not per-flavor.
#
# IT RUNS ON THE DISTRO INTERPRETER. The gcloud CLI ships its own bundled
# Python but falls back to /usr/bin/python3, which is why install-python.sh
# never repoints that symlink. Order matters only in one direction: this needs
# the apt basics (ca-certificates, curl, gnupg2, apt-transport-https) that
# install-basics.sh puts down, so it runs after it.
set -euxo pipefail

echo "== Add the Google Cloud apt repository =="
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

# Overwrite rather than append (`>` not `>>`): this script must be re-runnable
# on a live VM without accumulating duplicate repo lines, which apt warns about
# on every subsequent update.
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list

echo "== Install google-cloud-cli =="
apt-get update -y
apt-get install -y google-cloud-cli

# Drop the package lists again, matching install-basics.sh: they are ~40MB of
# cache that every later installer refreshes for itself anyway, and they would
# otherwise be captured into the image.
rm -rf /var/lib/apt/lists/*

gcloud --version
