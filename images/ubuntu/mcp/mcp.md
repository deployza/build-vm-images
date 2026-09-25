# `mcp` image

GCE image family **`dz-mcp`**: Ubuntu + basic tools + gcloud CLI + the
**runtime** of the Deployza MCP server — one Python venv at `/opt/mcp/venv`
holding [graphify](https://github.com/Graphify-Labs/graphify) (with every
tree-sitter grammar) and [fastmcp](https://gofastmcp.com).

**That is all it bakes.** Since image 1-3 this flavor follows the fleet's split:
the image carries the software, and the application is pushed to a running VM by
build-ops. Everything that makes the venv *the Deployza MCP server* — the `mcp`
service user, `/etc/mcp/mcp.env`, the `/usr/local/bin/mcp-*` helpers, the OAuth
gateway (`mcp_auth_app.py`), the Markdown pass (`mcp-md-graph` and its vendored
extractor), the sudoers drop-in and all six systemd units — lives in
[`build-ops/vm/mcp-vm/`](../../../../build-ops/vm/mcp-vm/) and is installed by
its `mcp` unit:

```bash
ansible-playbook playbooks/mcp-vm.yml --tags mcp        # from build-ops/ansible
sudo bash vm/mcp-vm/install.sh production mcp           # or on the box
```

The design, the units and the operator runbook are in
`build-terraform/dz-builds/mcp.md`; the deploy script's header documents
exactly what it installs.

> **A VM booted from this image serves nothing until that push has run.** There
> is no unit to start — nothing on the image knows it is the MCP server. Every
> VM replacement therefore ends with the playbook. From then on the VM needs
> nothing at boot: the pushed units are enabled and express the whole boot
> sequence themselves.

**Why the split.** Up to image 1-2 all of the above was baked here, so changing
one line of `mcp.env` meant a rebake and a VM replacement — which throws away
`/data` (the graph, the clones, the OAuth token store) and signs everyone out.
Image 1-2 existed for exactly that: a renamed secret id. Now it is a push and a
two-second restart.

**Why the venv stays baked.** It is ~191 MB of wheels. Installing it at deploy
time would make PyPI's availability a deploy-time dependency and cost minutes
per push on a shared-core e2-micro. It is the runtime, in the same sense Tomcat
is on the tomcat flavors.

The first flavor with no Java and no Tomcat.

## Contents

- `install-basics.sh`, `install-gcloud.sh`, `install-python.sh` — the baseline
  every flavor gets (git and jq included; see [`../../../CLAUDE.md`](../../../CLAUDE.md))
- `install-mcp.sh` — `python3-venv` and the venv:
  `graphifyy[mcp,terraform,sql]`, `fastmcp` and `py-key-value-aio[disk]`,
  plus an import smoke test
- `otelcol/install-otel.sh`, `cloud-sql-proxy/…`, `logs/…`, `write-manifest.sh`
  — inert on every flavor, as usual

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).
`write-manifest.sh` records the venv's `pip freeze` in `/etc/image-manifest.txt`.

## Compatibility checks moved to the push

Two checks guard the seam between our code and the upstream packages. They
were bake-time checks while the code was baked; they now run in
`build-ops/vm/mcp-vm/mcp.sh` **before it installs anything**, against the
files being pushed and this image's venv:

- **Gateway import check** — `mcp_auth_app.py` imports eight symbols from six
  fastmcp submodules, and fastmcp is pre-1.0.
- **Vendored-extractor drift check** — see *Markdown* below.

So a `GRAPHIFY_VERSION` or `FASTMCP_VERSION` bump that breaks either now fails
the **first push** to a VM on the new image, while the old install keeps
serving — not the bake. Before replacing the live VM with a bumped image, push
to a scratch VM booted from it, or run the pre-flight by hand on one.

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

## Markdown

Markdown is classified by graphify as a *document*, and documents go through
LLM-based extraction — so `--code-only` skips them and a scan without it
hard-fails asking for a key. But graphify **also ships a deterministic Markdown
extractor** that needs no LLM at all; it is simply unreachable from the CLI.
`mcp-md-graph` (build-ops) calls it directly, as a second pass per repo,
merging doc nodes into the same `graph.json` before `global add`.

That extractor is **vendored** into `mcp_md_extract.py` rather than imported,
because reaching graphify's own requires four private symbols — one of them a
module global read via `getattr(..., None)`, so an upstream rename would not
raise, it would silently stop resolving links. The vendored copy is verified
byte-identical to the library's output, and the push re-checks that against a
fixture before it installs anything.

To check drift by hand on a running VM:

```bash
/opt/mcp/venv/bin/python /usr/local/bin/mcp-md-graph \
    /data/repos/<repo> --self-test
```

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit \
  --config images/ubuntu/mcp/cloudbuild.yaml \
  --service-account=projects/dz-builds/serviceAccounts/build-service-account@dz-builds.iam.gserviceaccount.com \
  --project=dz-builds \
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
one. (The `dz-mcp` family pointer just moves to the newest image.)

Consumers launch with `--image-family=dz-mcp --image-project=dz-builds`.

## Changelog

| Version | Date       | Change                              |
| ------- | ---------- | ----------------------------------- |
| 1-0     | 2026-08-31 | Initial `mcp` image. Renamed wholesale from the former `graphify` family — flavor, units, helpers, service user, venv and env file all now say `mcp`; only upstream's own names (`graphifyy`, `graphify.serve`, `GRAPHIFY_API_KEY`, `.graphify`) are unchanged. `/data` moves onto the boot disk, so no `attached_disk` is required; `mcp-boot` still mounts one if present. Carries forward everything the `graphify` family had learned — the gcloud `CLOUDSDK_CONFIG` fix, per-repo failure tolerance in the refresh, and the tokenless Markdown pass with its vendored extractor and bake-time drift check. |
| 1-2     | 2026-09-09 | `mcp.env`'s `MCP_GITHUB_PAT_SECRET` renamed `mcp-github-pat` → `github-readonly-pat` (the PAT is now shared with `website-vm`'s docs-refresh; see `../../docs/apidocs-vm-build-plan.md`). Requires `github-readonly-pat` to hold a valid value in Secret Manager *before* this VM replaces the running one, or `mcp-refresh.service` starts failing immediately. |
| 1-3     | 2026-09-25 | **The application moves out of the image.** This flavor now bakes only the venv (graphify + fastmcp); the `mcp` user, `mcp.env`, every helper, the OAuth gateway, the Markdown pass, the sudoers drop-in and all six units moved to `build-ops/vm/mcp-vm/` and are installed by its `mcp` unit. The gateway import check and the extractor drift check moved with them and run before each push. `install-mcp.sh` moves from `scripts/ubuntu/mcp/` to `scripts/ubuntu/`. **A VM booted from 1-3 serves nothing until `ansible-playbook playbooks/mcp-vm.yml` has run** — do not repoint anything at a 1-3 VM before that. |
