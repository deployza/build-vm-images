#!/bin/bash
# Install Playwright and its Chromium, shared by every user, under
# /opt/ms-playwright. ai-coder flavor.
#
# WHAT IT IS FOR. Agents check UI work in a real browser and take before/after
# screenshots for the PR. ai-coding-ui is static HTML, so nothing else on the
# VM renders it.
#
# WHAT THE BAKE SAVES. Two things a sandboxed agent cannot do for itself:
#   * the browser's OS libraries and fonts, which need root (`--with-deps`
#     runs apt).
#   * the browser download. The sandbox's network allow-list has only package
#     registries, not Playwright's CDN.
#
# ONE BROWSER BUILD, SHARED. Browsers go to PLAYWRIGHT_BROWSERS_PATH
# (/opt/ms-playwright), not root's ~/.cache, and are world-readable. Every user
# who runs Playwright must have the same variable set; build-ops sets it for the
# agent user. The `playwright` CLI (npm, pinned) is on PATH.
#
# VERSION MATCHING. Each Playwright release runs only the browser build it was
# released with. A repo whose own playwright dependency (npm or pip) is the
# same version as PLAYWRIGHT_VERSION uses the baked Chromium. Any other version
# looks for its own build and fails offline, so keep repos on this pin or bump
# it.
#
# CHROMIUM ONLY. Firefox and WebKit are not baked. `install chromium` also
# brings chromium-headless-shell (what headless runs actually launch) and ffmpeg
# (video capture).
#
# NO CHROMIUM SANDBOX NEEDED. Playwright launches Chromium with --no-sandbox by
# default (chromiumSandbox: false), so Chromium does not need its own userns
# permission on 24.04. Agents' commands already run inside srt.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

export DEBIAN_FRONTEND=noninteractive
export npm_config_cache=/tmp/npm-cache npm_config_update_notifier=false npm_config_fund=false
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

npm install -g "playwright@${PLAYWRIGHT_VERSION}"
rm -rf /tmp/npm-cache
ln -sfn /opt/node/bin/playwright /usr/local/bin/playwright
test "$(playwright --version)" = "Version ${PLAYWRIGHT_VERSION}"

# --with-deps runs its own apt-get update; clear the lists after, like every
# other apt installer here.
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
playwright install --with-deps chromium
rm -rf /var/lib/apt/lists/*

chown -R root:root "$PLAYWRIGHT_BROWSERS_PATH"
chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"
ls -1 "$PLAYWRIGHT_BROWSERS_PATH"

# Launch the baked browser headless and render a page, as an unprivileged user,
# so a missing library or permission fails the bake, not the first agent run.
TEST_USER=playwright-bake-test
useradd --create-home --shell /bin/bash "$TEST_USER"
TEST_HOME="$(getent passwd "$TEST_USER" | cut -d: -f6)"
cleanup() { userdel -r "$TEST_USER" 2>/dev/null || true; }
trap cleanup EXIT

runuser -u "$TEST_USER" -- env HOME="$TEST_HOME" PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" \
    NODE_PATH=/opt/node/lib/node_modules node -e '
const { chromium } = require("playwright");
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent("<h1>bake-ok</h1>");
  const text = await page.textContent("h1");
  const version = browser.version();
  await browser.close();
  if (text !== "bake-ok") { console.error("unexpected:", text); process.exit(1); }
  console.log("chromium", version, "rendered a page");
})().catch(e => { console.error(e); process.exit(1); });
'

cleanup
trap - EXIT

echo "Playwright ${PLAYWRIGHT_VERSION} and Chromium installed in ${PLAYWRIGHT_BROWSERS_PATH}."
echo "Users must set PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH} (build-ops does this for the agent user)."
