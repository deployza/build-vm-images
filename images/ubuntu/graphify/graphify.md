# `graphify` image

GCE image family **`graphify`**: Ubuntu + basic tools + gcloud CLI + a dedicated
unprivileged `graphify` user + [graphify](https://github.com/Graphify-Labs/graphify)
in a Python venv, exposed as an **MCP server** over Streamable HTTP and refreshed
hourly, both running as `systemd` units.

graphify keeps a knowledge graph of the organisation's repositories and serves it
to Claude Code so it can answer questions that span repos. **No application code
is written for it** — the image installs the upstream package and the units that
run it.

The image ships **without** any configuration for a specific deployment and
**without** any secret. The MCP API key and the read-only GitHub PAT are fetched
from Secret Manager at run time and never touch the disk.

The first flavor with no Java and no Tomcat.

## What runs

| Unit | Type | Does |
| --- | --- | --- |
| `graphify-boot.service` | oneshot, at boot | Formats/mounts the data disk, adds swap, creates the service home |
| `graphify-mcp.service` | long-running | Serves the graph on `0.0.0.0:8080/mcp`, API-key gated |
| `graphify-refresh.timer` | hourly | Fires the refresh |
| `graphify-refresh.service` | oneshot | Fetches changed repos, rescans, merges, restarts the server if the graph moved |
| `graphify-refresh-failed.service` | `OnFailure=` | Writes one ERROR to Cloud Logging when a refresh fails |

**The consuming VM needs no startup script.** The whole boot sequence is
expressed in the units:

```
graphify-boot.service            mounts /data, swap, service home
  ├─ graphify-mcp.service        Requires= + After= it
  └─ graphify-refresh.timer      OnBootSec=2min -> first refresh -> first graph
```

`graphify-mcp.service` exits immediately for the first ~2 minutes of a brand-new
VM's life, because no graph exists yet. That is the designed path, not a fault:
`Restart=always` retries until the first refresh produces one.

## The boot-disk / data-disk split

This is the thing to understand before changing anything here.

| Boot disk — **baked by this image** | Data disk — **created at boot** |
| --- | --- |
| `/opt/graphify/venv` (~191 MB, every tree-sitter grammar) | `/data/repos` — shallow clones |
| `/usr/local/bin/graphify-*`, `gcp-secret` | `/data/graphify/.graphify/global-graph.json` |
| `/etc/graphify/graphify.env` | `/data/graphify/last-run` — the refresh watermark |
| the four systemd units | `/data/swapfile` |

Two consequences that are easy to get wrong:

- **The service user's home must be on the data disk.** graphify's `global add`
  writes to `Path.home()/".graphify"` — hardcoded upstream, no flag to redirect
  it. A home on the boot disk means the merged graph is destroyed by the next
  image swap. `install-graphify.sh` therefore creates the user with
  `--no-create-home` and `--home /data/graphify`; the VM's boot script creates
  and chowns it.
- **The units are enabled but cannot start at bake time.** `graphify-boot.service`
  does the mounting on the real VM, and the other two `Requires=` it, so systemd
  holds them back until the disk is there.

Mounting `/data`, the swapfile and the service home are **per-instance** work,
which is why they are a boot-time unit rather than a bake step — but they are
still baked *here*, as `graphify-boot.sh`, rather than living in the consuming
Terraform as a startup script. All of this flavor's shell belongs to this repo.

> **The one cross-repo contract is the disk device name.** `graphify-boot.sh`
> mounts `/dev/disk/by-id/google-graphify-data`, so the consuming Terraform's
> `attached_disk` must set `device_name = "graphify-data"`. Nothing else about
> the VM is this image's business.

## Why `install-vm-startup.sh` is not in this flavor

The standard boot launcher requires `APP_NAME`/`APP_ENV` metadata and fails the
boot without them, then clones `build-app-install` and runs `vm/<APP_NAME>.sh` —
a contract built around pulling a WAR and `conf/` from GCS and deploying into
Tomcat. graphify has no WAR, no `conf/` and no Tomcat.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI (also installs `git` and `jq`)
- `graphify/install-graphify.sh` — `python3-venv`, the `graphify` system user, the
  venv, the helper binaries, the sudoers drop-in, and the four systemd units
- `graphify/graphify.env` — all tunables, baked to `/etc/graphify/graphify.env`
- `graphify/graphify-boot.sh` — per-instance boot work (data disk, swap, home)
- `graphify/graphify-serve` — fetches the API key, exports it, `exec`s the server
- `graphify/graphify-refresh` — the gated hourly refresh
- `graphify/gcp-secret` — reads one Secret Manager secret to stdout
- `graphify/graphify-git-askpass` — feeds the PAT to git without it reaching argv
- `graphify/graphify-log-failure` — the `OnFailure=` reporter
- `graphify/*.service`, `graphify/*.timer` — the units

Unlike the other flavors, these live in their **own subdirectory** under
`scripts/ubuntu/`: none of them is shared with another flavor, and
`scripts/ubuntu/` proper is for the shared installers.

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

> **`v8` is the only reliable reference.** The published graphify documentation
> and the repo's `main` branch both disagree with the shipping code. Behavioural
> claims here come from reading `serve.py`, `global_graph.py` and `security.py`
> on branch `v8`.

## Language coverage

graphify ships ~25 tree-sitter grammars by default; the rest are extras. This
image installs `graphifyy[mcp,terraform,sql]`.

| Stack | Supported | Note |
| --- | --- | --- |
| Java | ✅ default | `framework-spring`: 967 nodes, 2,138 edges |
| Python | ✅ default | |
| React (JS/TS/JSX/TSX) | ✅ default | |
| Terraform / HCL | ✅ `[terraform]` | **0 nodes** without the extra, 338 nodes / 777 edges with it — silent, not an error |
| SQL schemas | ✅ `[sql]` | warns until added |
| Static UI (HTML/CSS) | ❌ **none** | no HTML or CSS grammar exists, even under `[all]` |

Markdown is classified as a *document*, not code, and documents need an LLM key —
a scan hard-fails without one. Every scan here runs `--code-only`, which skips
them deliberately instead.

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit \
  --config images/ubuntu/graphify/cloudbuild.yaml \
  --service-account=projects/tools-tech-463909/serviceAccounts/build-service-account@tools-tech-463909.iam.gserviceaccount.com \
  --project=tools-tech-463909 \
  .
```

> **`--service-account` is required, not optional.** Without it Cloud Build runs
> the build as the **Compute Engine default** service account
> (`<project-number>-compute@developer.gserviceaccount.com`), which fails before
> the build even starts:
>
> ```
> ERROR: could not resolve source: googleapi: Error 403:
> 347018192564-compute@developer.gserviceaccount.com does not have
> storage.objects.get access to the Google Cloud Storage object
> ```
>
> That reads like a bucket problem and is really an identity one — the tarball
> uploaded fine under your own credentials; it is the *build* that cannot read it
> back. `build-service-account` is the identity every trigger in
> `build-terraform/builds/cloudbuild-triggers.tf` already uses, so passing it here
> just makes a hand-run bake match an automated one. Verified 2026-08-25: the bare
> command fails as above, the command above succeeds.
>
> Two follow-on errors, if they appear:
> - `does not have permission to act as …` → your own account needs
>   `roles/iam.serviceAccountUser` on `build-service-account`.
> - still 403 on the bucket → check what the role actually contains rather than
>   escalating to a bigger-sounding one:
>   `gcloud iam roles describe roles/storage.admin --format="value(includedPermissions)"`
>
> `--service-account` also requires build logs to have a destination the SA can
> write. `options: logging: CLOUD_LOGGING_ONLY` in this flavor's `cloudbuild.yaml`
> already satisfies that.

Image names are unique per project, so re-running with an unchanged
`_IMAGE_VERSION` **fails** at the image-create step (GCE `409 alreadyExists`) —
GCE never overwrites an existing image. Bump `_IMAGE_VERSION` to publish a new
one. (The `graphify` family pointer just moves to the newest image.)

Consumers launch with `--image-family=graphify --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                              |
| ------- | ---------- | ----------------------------------- |
| 1-0     | 2026-08-25 | Initial image. graphify 0.9.48. **Broken** — see 1-1. |
| 1-1     | 2026-08-25 | **Two independent bugs found on first deployment.** (1) `CLOUDSDK_CONFIG=/tmp/gcloud` on both units — gcloud writes a credential cache to `$HOME`, which `ProtectSystem=strict` + `ReadOnlyPaths=/data` made read-only, so `gcp-secret` failed and the server crash-looped 213 times. (2) `graphify extract` exits non-zero on a repo that yields an empty graph (static-UI, config-only or empty repos), and `set -e` turned that into aborting the whole run — one repo killed the refresh for all ~200, hourly. Per-repo failures are now skipped and counted, never fatal. |
