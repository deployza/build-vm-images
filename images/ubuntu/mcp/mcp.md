# `mcp` image

GCE image family **`mcp`**: Ubuntu + basic tools + gcloud CLI + a dedicated
unprivileged `mcp` user + [graphify](https://github.com/Graphify-Labs/graphify)
in a Python venv, exposed as an **MCP server** over Streamable HTTP and refreshed
hourly, both running as `systemd` units.

It keeps a code knowledge graph of the organisation's repositories and serves it
to Claude Code so it can answer questions that span repos. **graphify is the
engine, not the product** — the flavor, the units and the helpers are named for
what this is (an MCP server); `graphify`, `graphifyy` and `graphify.serve` are
upstream's names and stay as they are.

> **Since image 1-2 this flavor DOES carry application code**, which the rest of
> the fleet does not: `mcp-md-graph` (ours) and `mcp_md_extract.py`
> (vendored from graphify, Apache-2.0). Everything else here is still the upstream
> package plus the units that run it. See *Language coverage* for why.

The image ships **without** any configuration for a specific deployment and
**without** any secret. The MCP API key and the read-only GitHub PAT are fetched
from Secret Manager at run time and never touch the disk.

The first flavor with no Java and no Tomcat.

## What runs

| Unit | Type | Does |
| --- | --- | --- |
| `mcp-boot.service` | oneshot, at boot | Formats/mounts the data disk, adds swap, creates the service home |
| `mcp.service` | long-running | Serves the graph on `0.0.0.0:8080/mcp`, API-key gated |
| `mcp-refresh.timer` | hourly | Fires the refresh |
| `mcp-refresh.service` | oneshot | Fetches changed repos, rescans, merges, restarts the server if the graph moved |
| `mcp-refresh-failed.service` | `OnFailure=` | Writes one ERROR to Cloud Logging when a refresh fails |

**The consuming VM needs no startup script.** The whole boot sequence is
expressed in the units:

```
mcp-boot.service            mounts /data, swap, service home
  ├─ mcp.service        Requires= + After= it
  └─ mcp-refresh.timer      OnBootSec=2min -> first refresh -> first graph
```

`mcp.service` exits immediately for the first ~2 minutes of a brand-new
VM's life, because no graph exists yet. That is the designed path, not a fault:
`Restart=always` retries until the first refresh produces one.

## Where state lives

`/data` holds everything per-instance: the shallow clones, the merged graph, the
refresh watermark and the swapfile. Everything else — `/opt/mcp/venv` (~191 MB
with every tree-sitter grammar), `/usr/local/bin/mcp-*`, `/etc/mcp/mcp.env` and
the systemd units — is baked into this image.

**`/data` is a plain directory on the boot disk.** The boot disk is 20 GB because
GCE refuses one smaller than the image, and the OS plus venv use ~2.7 GB, leaving
~12 GB spare — far more than the ~5 GB projected at 200 repos. A dedicated data
disk was used until 2026-08-31 and bought nothing but a second resource, a
device-name contract between two repos, and a zonal volume that could not follow
the VM across regions.

**The trade:** `/data` dies with the boot disk on an image swap, so a replacement
re-indexes from scratch — measured at ~12 min of CPU for the whole org. Cheap
against the complexity it removes, and the refresh is designed to rebuild from
nothing anyway.

**A separate disk is still supported.** Attach one as `device_name = "mcp-data"`
and `mcp-boot` formats and mounts it exactly as before. That keeps this image
usable with or without one, so neither repo has to deploy in lockstep.

Two consequences that are easy to get wrong:

- **The service user's home must be under `/data`.** graphify's `global add`
  writes to `Path.home()/".graphify"` — hardcoded upstream, no flag to redirect
  it. `install-mcp.sh` creates the user with `--no-create-home` and
  `--home /data/mcp`; `mcp-boot` creates and chowns it per instance. (`.graphify`
  inside it is upstream's name and stays.)
- **The units are enabled but cannot start at bake time.** `mcp-boot.service`
  does the per-instance work on the real VM, and the others `Requires=` it, so
  systemd holds them back until it succeeds.

All of this flavor's shell belongs to this repo — `mcp-boot` is baked here rather
than living in the consuming Terraform as a startup script.

## Why `install-vm-startup.sh` is not in this flavor

The standard boot launcher requires `APP_NAME`/`APP_ENV` metadata and fails the
boot without them, then clones `build-app-install` and runs `vm/<APP_NAME>.sh` —
a contract built around pulling a WAR and `conf/` from GCS and deploying into
Tomcat. graphify has no WAR, no `conf/` and no Tomcat.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI (also installs `git` and `jq`)
- `mcp/install-mcp.sh` — `python3-venv`, the `mcp` system user, the
  venv, the helper binaries, the sudoers drop-in, and the four systemd units
- `mcp/mcp.env` — all tunables, baked to `/etc/mcp/mcp.env`
- `mcp/mcp-boot` — per-instance boot work (`/data`, swap, service home)
- `mcp/mcp-serve` — fetches the API key, exports it, `exec`s the server
- `mcp/mcp-refresh` — the gated hourly refresh
- `mcp/mcp-md-graph` — the Markdown pass, plus `--self-test`
- `mcp/mcp_md_extract.py` — **vendored** (Apache-2.0) Markdown extractor
- `mcp/gcp-secret` — reads one Secret Manager secret to stdout
- `mcp/mcp-git-askpass` — feeds the PAT to git without it reaching argv
- `mcp/mcp-log-failure` — the `OnFailure=` reporter
- `mcp/*.service`, `graphify/*.timer` — the units

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

| **Markdown** | ✅ **no grammar, no LLM** | vendored extractor, see below. `build-docs`: 63 nodes / 75 edges, 0 tokens |

Markdown is classified by graphify as a *document*, and documents go through
LLM-based extraction — so `--code-only` skips them and a scan without it
hard-fails asking for a key. But graphify **also ships a deterministic Markdown
extractor** that needs no LLM at all; it is simply unreachable from the CLI.
`mcp-md-graph` calls it directly, as a second pass per repo, merging doc
nodes into the same `graph.json` before `global add`.

That extractor is **vendored** into `mcp_md_extract.py` rather than imported,
because reaching graphify's own requires four private symbols — one of them a
module global read via `getattr(..., None)`, so an upstream rename would not
raise, it would silently stop resolving links. The vendored copy is verified
byte-identical to the library's output, and `install-mcp.sh` re-checks that
at **bake time** against a fixture: a `GRAPHIFY_VERSION` bump that changes
extraction fails the image build rather than shipping stale behaviour.

To check drift by hand after an upgrade:

```bash
/opt/mcp/venv/bin/python /usr/local/bin/mcp-md-graph \
    /data/repos/<repo> --self-test
```

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit \
  --config images/ubuntu/mcp/cloudbuild.yaml \
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
one. (The `mcp` family pointer just moves to the newest image.)

Consumers launch with `--image-family=mcp --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                              |
| ------- | ---------- | ----------------------------------- |
| 1-0     | 2026-08-31 | Initial `mcp` image. Renamed wholesale from the former `graphify` family — flavor, units, helpers, service user, venv and env file all now say `mcp`; only upstream's own names (`graphifyy`, `graphify.serve`, `GRAPHIFY_API_KEY`, `.graphify`) are unchanged. `/data` moves onto the boot disk, so no `attached_disk` is required; `mcp-boot` still mounts one if present. Carries forward everything the `graphify` family had learned — the gcloud `CLOUDSDK_CONFIG` fix, per-repo failure tolerance in the refresh, and the tokenless Markdown pass with its vendored extractor and bake-time drift check. |
| 1-2     | 2026-09-09 | `mcp.env`'s `MCP_GITHUB_PAT_SECRET` renamed `mcp-github-pat` → `github-readonly-pat` (the PAT is now shared with `website-vm`'s docs-refresh; see `../../docs/apidocs-vm-build-plan.md`). Requires `github-readonly-pat` to hold a valid value in Secret Manager *before* this VM replaces the running one, or `mcp-refresh.service` starts failing immediately. |
