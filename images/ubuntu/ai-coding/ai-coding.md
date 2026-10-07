# `ai-coding` image

GCE image family **`dz-ai-coding`**. It's the VM for Deployza's automated coding
system: [`ai-coding-server`](../../../../../AI/ai-coding-server) and
[`ai-coding-ui`](../../../../../AI/ai-coding-ui), two WARs in Tomcat behind
nginx, plus the AI agents (the `claude` CLI) that code each sprint and the
sandboxed builds that check their work.

The flavor is named for its purpose, like `mcp` and `ops`.

**Software only.** The image installs everything the system and its agents run.
Every user, secret, policy, config file and app unit is pushed by build-ops
(see [What build-ops configures](#what-build-ops-configures)). A VM booted from
this image serves nothing and can run no agent until that push has run.

## Contents

| Installer | Installs | Where |
| --- | --- | --- |
| `install-basics.sh`, `install-gcloud.sh` | The baseline: apt basics (git, jq, curl, the distro Python 3.12 with venv and pip) and the gcloud CLI (Secret Manager reads at deploy time) | system |
| `install-java.sh` | JDK (the fleet pin; matches `deployza-parent-pom`'s `java.version`) | `/opt/java/latest` |
| `tomcat/install-tomcat.sh` | Tomcat, `tomcat` user, systemd unit | `/home/tomcat/instance` |
| `nginx/install-nginx.sh` + `tomcat/nginx-tomcat.sh` | nginx stable on `:80`, proxying to Tomcat, empty `/etc/nginx/app.d/`; Tomcat trusts `X-Forwarded-*` from loopback | system |
| `install-maven.sh` | Maven, `mvn` on PATH | `/opt/maven` |
| `install-node.sh` | Node.js LTS, `node`/`npm`/`npx` on PATH; the global npm prefix | `/opt/node` |
| `ai-coding/install-build-tools.sh` | `build-essential`, `python3-dev`, `pkg-config` (pip source builds), `ripgrep`, `acl`, `patch`, `file`, `zip`, `xz-utils`, `less` | system |
| `ai-coding/install-sandbox.sh` | `srt` (sandbox-runtime, npm), `bubblewrap`, `socat`, `ripgrep`, and an AppArmor profile granting `userns` to bwrap and srt's seccomp helper | `/opt/node`, `/etc/apparmor.d/deployza-sandbox` |
| `ai-coding/install-claude.sh` | Claude Code CLI, native binary, checksum-verified against the release manifest | `/opt/claude/bin/claude` |
| `ai-coding/install-playwright.sh` | Playwright CLI (npm) and Chromium + headless shell + ffmpeg, with their OS libraries and fonts | `/opt/node`, `/opt/ms-playwright` |
| `ai-coding/install-reposilite.sh` | Reposilite jar only (the read-only Maven proxy) | `/opt/reposilite/reposilite.jar` |

Plus the baseline every flavor carries: otelcol (inert), cloud-sql-proxy (not
enabled, and this system has no database), and the log policy.

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).
`cat /etc/image-manifest.txt` on a VM shows what was installed.

### What the bake checks

Each installer fails the bake rather than shipping a broken tool:

- Maven, Node, Claude Code, srt and Playwright must report exactly their pinned
  version.
- **The sandbox must work as an unprivileged user.** A throwaway user runs two
  commands under `srt`. A write inside the allowed directory must land, and a
  write outside it must be blocked. This runs on the bake VM's own Ubuntu
  24.04 kernel and AppArmor setup, so a profile problem fails here, not in the
  first build check.
- **Chromium must render a page** headless, as an unprivileged user.

## Notes

- **Ubuntu 24.04 and user namespaces.** 24.04 strips capabilities from user
  namespaces created by unprivileged processes, which breaks bubblewrap.
  `apparmor-sandbox` grants `userns` to `/usr/bin/bwrap` and srt's
  `apply-seccomp` helpers only. The host-wide
  `kernel.apparmor_restrict_unprivileged_userns` stays at `1`. Claude Code's
  built-in sandbox uses the same bwrap, so it benefits too. The isolation tests
  in ai-coding-server's `docs/vm-testing.md` are the real check.
- **Chromium runs without its own sandbox.** Playwright passes `--no-sandbox`
  by default, so Chromium needs no AppArmor profile. Agent commands already run
  inside srt.
- **Playwright versions.** A Playwright release runs only the browser build it
  shipped with. A repo whose `playwright` dependency (npm or pip) matches
  `PLAYWRIGHT_VERSION` uses the baked Chromium. Any other version tries to
  download its own browser, and the sandbox allow-list blocks that.
- **Claude Code is pinned and root-owned.** It isn't installed with the official
  per-user installer, which turns on auto-update. ai-coding-server checks
  `claude --version` against `claude.cli.min_version`. Bump
  `CLAUDE_CODE_VERSION` deliberately, then re-run the VM runbook's CLI checks.
- **Disk.** The image uses about 7 GB of its 10. Clones, worktrees, the agent's
  `~/.m2` / `~/.gradle` / `~/.cache/pip` caches and the run log spool grow
  without limit, so launch the VM with a larger boot disk or a data disk.
- **Size the agent pool to the VM.** `ai-coding-vm` is an e2-medium (2 vCPU /
  4 GB, decided 2026-10-07), so coding-server's `agent.pool.size` (default 5)
  must be 1 or 2. Each agent may start a JVM or a browser. See
  `build-terraform/dz-builds/ai-coding.md`.

## What build-ops configures

None of this is in the image. It is pushed by
[`build-ops/vm/ai-coding-vm/`](../../../../build-ops/vm/ai-coding-vm/) (units
`maven-proxy`, `agent`, `coding-server`, `coding-ui`, `otel`):

```bash
ansible-playbook playbooks/ai-coding-vm.yml        # from build-ops/ansible
sudo bash vm/ai-coding-vm/install.sh prod           # or on the box
```

The spec it implements is in `ai-coding-server/prompts/security.md`,
`configuration.md` and `features/agent-runtime.md`. In summary:

1. **Users and groups:** the agent OS user (e.g. `deployza-agent`), a group
   shared with `tomcat`, and the Reposilite user. Set up the worktree root
   with setgid and default ACLs.
2. **sudo:** a rule letting `tomcat` run only the agent launcher as the agent
   user, and the launcher itself. Its `claude` mode reads the API key file into
   `ANTHROPIC_API_KEY`; its `build` mode runs `srt` with no key. Both set
   `DISABLE_AUTOUPDATER=1`, `JAVA_HOME=/opt/java/latest` and
   `PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright`.
3. **Secrets from Secret Manager:** the GitHub App key (readable by `tomcat`
   only), the Claude API key (readable by the agent user only), and the
   Artifact Registry Reader key (readable by the Reposilite user only).
4. **Reposilite:** config (Artifact Registry plus Maven Central, read-only),
   bound to loopback on a port other than Tomcat's `8080` (e.g. `8081`), and its
   systemd unit.
5. **The agent's `~/.m2/settings.xml`:** one `mirrorOf *` mirror pointing at
   the proxy, with no credentials. Also create the dependency cache dirs.
6. **The apps:** both WARs, their Tomcat context XMLs, `app.properties`
   (mode 600), and the nginx `app.d/` routes and TLS.
7. **otel:** add `OTEL_GROUPS` if the collector should read Tomcat's logs.

## Build

Run from the **repo root**. The build context must include `scripts/`:

```bash
gcloud builds submit \
  --config images/ubuntu/ai-coding/cloudbuild.yaml \
  --service-account=projects/dz-builds/serviceAccounts/build-service-account@dz-builds.iam.gserviceaccount.com \
  --project=dz-builds \
  .
```

Bump `_IMAGE_VERSION` to publish a new image. Re-running an existing version
fails with GCE `409 alreadyExists`.

Consumers launch with
`--image-family=dz-ai-coding --image-project=dz-builds`.

## Changelog

| Version | Date       | Change |
| ------- | ---------- | ------ |
| 1-0     | 2026-10-07 | Initial image. JDK 24, Tomcat 11.0.8, nginx stable, Maven 3.9.16, Node 24.21.0, Claude Code 2.1.285, srt 0.0.78, Playwright 1.63.0 (Chromium), Reposilite 3.6.3. |
