# Serve www.deployza.com (+ /docs mkdocs site) from a new nginx VM

Living design/checklist doc for a cross-repo change. Read this first before
touching any of the five repos below — it captures decisions already made so
they don't need to be re-derived in a fresh session. Update the checkboxes as
each part actually ships; don't let this go stale.

## Context

`www.deployza.com` is currently served straight from a GCS bucket
(`www.deployza.com` bucket → `wesbsite-backend-bucket` → devops url-map
`path-matcher-4`). A separate repo, `api-docs`, held only a planning prompt
(`api-docs/plan.md`) describing a not-yet-built MkDocs Material site,
originally scoped to deploy over GitHub Actions + SSH.

The goal: stand up a new VM that (a) becomes the origin for
`www.deployza.com` (replacing the GCS bucket, the same way
`products/assess-vm` already fronts `www.ziniapps.com` / `go.ziniapps.com`),
and (b) serves the MkDocs docs at `/docs/` on that **same** domain (for SEO —
no new subdomain). Everything else already routed by the shared LB
(`files.deployza.com`, `mcp.deployza.com`, both ziniapps hosts,
`one.deployza.com`) is untouched.

## Decisions

- Docs path: `/docs/` on `www.deployza.com`.
- No-cache headers: **whole site**, matching the `ziniapps-www.sh` precedent
  exactly — every response from `www.deployza.com` (marketing pages and
  `/docs/` alike) carries `Cache-Control: no-cache, must-revalidate`,
  `Pragma: no-cache`, `Expires: 0`.
- Full cutover: the VM becomes the sole origin for `www.deployza.com`; the GCS
  backend-bucket resource is left in place (unreferenced) for easy rollback,
  not deleted.
- Both `www-website`'s and `api-docs`'s build/publish pipelines use **Cloud
  Build**, not GitHub Actions.
- `api-docs`'s docs content reaches the VM via a **pull** model (a systemd
  timer on the VM `gsutil rsync`s from GCS) rather than Cloud Build pushing
  over SSH — this VM, like every other in the fleet, has no public IP and
  only allows SSH from Google's IAP range, so a direct-SSH push (the design
  `api-docs/plan.md` originally asked for) would not reach it.

## Cross-repo map

| Repo | What changes | Status |
|---|---|---|
| `build-vm-images` (this repo) | New `nginx` flavor: basics + a new lean, Tomcat-free nginx installer | ☐ pending |
| `build-terraform` | New VM in `website/` (www-website-460108) + NEG/backend-service/health-check; swap `devops/load-balancing.tf` path-matcher-4 to it; new Cloud Build triggers for `www-website` and `api-docs`; a bucket IAM grant | ☐ pending |
| `build-app-install` | New per-HOST deploy script `vm/www-website.sh` — serves `/` from the WAR (`ziniapps-www.sh` model) and `/docs/` via a self-installed continuous GCS-pull timer, whole-site no-cache | ☐ pending |
| `www-website` | `cloudbuild.yaml`: `mvn package` the WAR, `gsutil cp` it + `install.properties` to `gs://deployza-apps/production/www-website/` | ☐ pending |
| `api-docs` | Scaffold the MkDocs Material site per its own `plan.md` (mkdocs.yml, requirements.txt, docs/ tree, README) + a `cloudbuild.yaml` that builds and `gsutil rsync`s `site/` to `gs://deployza-apps/production/api-docs/site/` | ☐ pending |

---

## 1. `build-vm-images` — new `nginx` flavor

Model directly on `images/ubuntu/mcp/` (the only other flavor with no Java) for
folder shape, and on `images/ubuntu/tomcat-nginx-mysql/image.pkr.hcl` for the
Packer boilerplate.

**New installer — `scripts/ubuntu/install-nginx-static.sh`** (not a reuse of
`install-nginx.sh`). `install-nginx.sh`'s header literally says "fronting
Tomcat on port 80" and bakes an `upstream tomcat { server 127.0.0.1:8080; }`
block plus a `proxy-to-tomcat.conf` snippet — both meaningless dead weight on
a flavor that will never run Tomcat. Reusing it would pass `nginx -t` (the
upstream doesn't need to be reachable at config-test time) but leaves a
misleading, Tomcat-shaped config on a box with no Tomcat. The new installer
mirrors `install-nginx.sh` structurally (official nginx.org apt repo, same
version pin from `versions.env`, same access-log-on + logrotate policy, same
empty `/etc/nginx/app.d/` + `/nginx-health` seam and README contract) but:
- names the baked conf.d file `static.conf` instead of `tomcat.conf`,
- has no `upstream`/`proxy-to-tomcat.conf` snippet,
- the `_` default server's `location /` just 404s until an app deploy script
  drops in a `site.d` block (same contract `ziniapps-*.sh` already rely on
  against `install-nginx.sh`-baked images).

**New flavor folder — `images/ubuntu/nginx/`:**
- `image.pkr.hcl` — `source.googlecompute.nginx`, family `nginx`, provisioner
  order: `install-basics.sh` → `install-nginx-static.sh` →
  `install-vm-startup.sh` → `write-manifest.sh`. Include
  `install-vm-startup.sh`: unlike `mcp` (which deliberately omits it because
  it doesn't use the GCS-WAR/`APP_NAME`+`APP_ENV` convention), this flavor
  *does* want the generic boot launcher — confirmed generic in
  `scripts/ubuntu/vm-startup.sh` (only needs `git`+`curl`, both from
  `install-basics.sh`; no Tomcat dependency), and `ziniapps-www.sh`'s own
  `require_tools` only checks for `gsutil`, `unzip`, `nginx` — never
  `tomcat`.
- `cloudbuild.yaml` — same shape as `mcp`'s (sources `versions.env` for
  `NGINX_VERSION`, passes `-var=nginx_version=$$NGINX_VERSION` alongside
  `image_version`/`git_sha`).
- `nginx.md` — doc following the other flavors' `<flavor>.md` pattern; use
  the **corrected** `gcloud builds submit --service-account=...` form per
  this repo's Conventions section.

No Java/Tomcat/MySQL installers, and nothing docs-specific baked into the
image — the MkDocs pull mechanism is policy, not mechanism, and belongs in
`build-app-install` (§3), matching how MySQL is baked with no credentials and
`install-nginx.sh` is baked with no app routing. `images/ubuntu` flavor list
gains `nginx` alongside the existing seven.

---

## 2. `build-terraform` — VM, LB wiring, and Cloud Build triggers

**`website/addresses.tf`** (new file): one internal static IP reservation for
the VM on the shared subnet
(`projects/devops-networking-460109/regions/asia-south1/subnetworks/default`
— `www-website-460108` is already an attached shared-VPC service project per
`devops/vpc.tf`). Omit an explicit `address` (unlike `products/addresses.tf`'s
hardcoded `10.160.0.10`) and let GCP auto-assign the next free IP in the
auto-mode subnet, avoiding a hand-picked collision with other projects'
reservations on the same shared subnet.

**`website/vms.tf`** (currently empty — the old www-website VM was fully
decommissioned): add `google_compute_instance.website_vm`, modeled on
`products/vms.tf`'s `assess_vm`:
- `boot_disk.image = "projects/tools-tech-463909/global/images/nginx-<version>"`
  (explicit versioned image, matching `assess_vm`'s convention of pinning
  rather than tracking the family, so a rebuild never silently replaces a
  live VM).
- `network_interface`: same shared-VPC default network/subnet as `assess_vm`,
  `network_ip` = the new reserved address.
- `service_account`: the **website project's own** default compute SA
  (`<project-number>-compute@developer.gserviceaccount.com`) — needs the
  actual project number for `www-website-460108` (e.g.
  `gcloud projects describe www-website-460108 --format='value(projectNumber)'`
  at implementation time; not fabricated here).
- `tags = ["firewall-allow-loadbalancer"]` — the existing devops rule already
  opens tcp:80/8080/3000 from the LB/health-check ranges; **no new firewall
  rule needed**, and (see §3) **no SSH ingress is needed for docs deploys
  either** — that's pull-based over HTTPS to GCS, not push-over-SSH.
- `metadata = { enable-osconfig = "TRUE", APP_NAME = "www-website", APP_ENV = "production" }`
  — consumed by the baked `vm-startup.service` to clone `build-app-install`
  and run `vm/www-website.sh production` on every boot.
- `lifecycle { ignore_changes = [metadata["ssh-keys"]] }`, same as
  `assess_vm`.

Add a matching daily-snapshot `google_compute_resource_policy` +
`google_compute_disk_resource_policy_attachment` pair, mirroring
`products/vms.tf`'s `assess_vm_snapshot` blocks.

**`website/load-balancing.tf`**: add back the NEG + health check + backend
service that the file's own header comment says were removed as dead
weight — same three resources as `products/load-balancing.tf`'s
`health_check_80` / `assess_server_neg_80` / `assess_server_endpoint_80` /
`assess_server_backend_service`, renamed for this VM (e.g.
`website_health_check_80`, `website_server_neg_80`,
`website_backend_service`), pointed at `google_compute_instance.website_vm`,
port 80.

**`devops/load-balancing.tf`**: change `path-matcher-4`'s `default_service`
from the `wesbsite-backend-bucket` backend bucket to the new
`.../backendServices/<website-backend-service-name>`. Leave the top-level
`google_compute_url_map.website.default_service` (the overall LB fallback
for unmatched hosts) pointed at the bucket. Update the file's routing
comment block to describe the new backend. No cert/cert-map change: the
hostname doesn't change, only its backend.

**Cloud Build wiring (`builds/` project, tools-tech-463909)** — new
repository connections + triggers, following the exact `product_assess_app`
pattern in `cloudbuild-repositories.tf` / `cloudbuild-triggers.tf`:
- `google_cloudbuildv2_repository.www_website` →
  `https://github.com/deployza/www-website.git`, and
  `google_cloudbuild_trigger.www_website_app` reading `cloudbuild.yaml` from
  it.
- `google_cloudbuildv2_repository.api_docs` →
  `https://github.com/deployza/api-docs.git` (confirm the actual GitHub repo
  name — the org's `GITHUB-SETUP.md` naming note suggests `www-apidocs`
  might be the real name), and `google_cloudbuild_trigger.api_docs_site`
  reading `cloudbuild.yaml` from it.

**Bucket IAM (`builds/buckets.tf`)** — the website VM's default compute SA
needs read access to `gs://deployza-apps` for both the WAR pull (boot-time)
and the docs pull (continuous timer, §3). No `google_storage_bucket_iam_*`
binding on this bucket turned up in this repo's Terraform (assess-vm's SA
already reads it today, so access exists somehow — likely an out-of-band or
project-level grant not captured here). **Verify this during
implementation** and add an explicit `google_storage_bucket_iam_member`
granting the website VM's SA `roles/storage.objectViewer` on
`google_storage_bucket.apps` if no existing grant covers it.

---

## 3. `build-app-install` — new deploy script `vm/www-website.sh`

A near-copy of `vm/ziniapps-www.sh` (per-HOST model: writes a complete
`server{}` block to `/etc/nginx/site.d/www-website.conf`, `server_name
www.deployza.com`, root = the unpacked WAR — **no** `include app.d`,
matching `ziniapps-www.sh`'s reasoning that this is the one product on this
host, not a landing page linking to path-prefixed apps). Per this repo's
`CLAUDE.md` "When adding a new app" checklist, also add a
`docker/www-website.sh` sibling to keep the two platforms in lockstep —
confirm whether that should be a real Docker deploy path or a thin stub,
since there's no Docker target for this app yet.

Two additions beyond the `ziniapps-www.sh` template, both **policy this
script owns** (not baked into the image, consistent with `install-nginx.sh`'s
mechanism/policy split):

**(a) A second `location /docs/` block** in the generated server config,
independent of the WAR unpack:

```nginx
location /docs/ {
    alias /var/www/api-docs/;
    try_files $uri $uri/ =404;

    add_header Cache-Control "no-cache, must-revalidate" always;
    add_header Pragma "no-cache" always;
    add_header Expires 0 always;
}
```

The whole site is no-cache — matching `ziniapps-www.sh` exactly.
`location /` (the marketing site) keeps its own copy of the same three
headers, as does the `= /404.html` location, for the same reason
`ziniapps-www.sh`'s header explains: `add_header` in a nested `location`
**replaces** any inherited set rather than adding to it, so every location
that can produce a response must repeat them.

**(b) A continuous docs-content puller**, since the boot-time-only WAR model
doesn't fit MkDocs (docs update far more often than this VM reboots, and
there's no WAR/`install.properties` artifact for it — just a `site/` tree).
`www-website.sh` idempotently (same marker-file pattern as
`ensure_site_d_include`) installs and enables:

- `/etc/systemd/system/docs-refresh.service` — a oneshot unit running
  `gsutil rsync -r -d gs://deployza-apps/production/api-docs/site/ /var/www/api-docs/`
  (`-d` deletes local files no longer in the bucket).
- `/etc/systemd/system/docs-refresh.timer` — fires the service on a short
  interval (e.g. every 3 minutes) plus `OnBootSec` so a fresh VM isn't empty
  until the first tick.

This is a **pull** model, deliberately: `api-docs`'s Cloud Build trigger
never needs to reach this VM at all (no SSH, no IAP tunnel, no new firewall
rule) — it just writes to GCS, and the VM notices on its own schedule.

`mkdir -p /var/www/api-docs` (owned by `www-data`, matching `/var/www/app`'s
pattern in `install-nginx.sh`) is created by this script too — it only owns
the directory's existence, not its contents (those arrive via the timer).

`require_tools` needs no change from the `ziniapps-www.sh` version
(`gsutil`, `unzip`, `nginx`, the `nginx.conf` anchor line) — update its
header comment's "Requires the tomcat-nginx-mysql image" line to say
`nginx` instead.

---

## 4. `www-website` — Cloud Build publishes the WAR

No changes needed to site content or `pom.xml` (already `packaging=war`).
Add `cloudbuild.yaml` at the repo root:

```yaml
steps:
  - name: 'asia-east1-docker.pkg.dev/tools-tech-463909/docker-taiwan/maven-docker:latest'
    entrypoint: mvn
    args: ['-B', 'clean', 'package']

  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk:slim'
    entrypoint: gsutil
    args: ['cp', 'target/www-website-1.0-SNAPSHOT.war',
           'gs://deployza-apps/production/www-website/www-website.war']

  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk:slim'
    entrypoint: gsutil
    args: ['cp', '-r', 'install/',
           'gs://deployza-apps/production/www-website/install/']
```

The `maven-docker:latest` builder image is the org's existing Maven build
image (`build-docker/maven/`, published via the `docker_maven` Cloud Build
trigger to the `docker-taiwan` Artifact Registry repo) — the exact same
image `product-assess-server/cloudbuild.yaml` already runs against.

Deliberately **not** reusing `build-apps/build-maven.sh` (the shared script
`product-assess-server` calls): that script's job is `mvn deploy` to a
private Maven Artifact Registry repo plus a git tag — built for
library/artifact publishing with downstream consumers. `www-website`'s WAR
has none of that; it only needs to land in `gs://deployza-apps`.

`install/install.properties` (checked into the repo, not generated) needs at
minimum `install.war=www-website.war` and
`install.server.name=www.deployza.com`.

**Operational note**: like `ziniapps-www.sh` today, picking up a new WAR
requires the VM to reboot or an operator to re-run
`sudo bash www-website.sh production` over IAP SSH — `vm-startup.service`
only runs at boot. Only `/docs/` content updates continuously via the timer
in §3.

---

## 5. `api-docs` — scaffold the MkDocs site + Cloud Build deploy

Executes the repo's own `plan.md` request, with the deploy step redesigned
for Cloud Build + GCS instead of GitHub Actions + SSH.

**`mkdocs.yml`** — Material theme, `navigation.instant`, `navigation.tabs`,
`navigation.sections`, `navigation.indexes`, `search.suggest`,
`search.highlight`, `content.code.copy`, `toc.follow`;
`mkdocs-awesome-pages-plugin` for folder-driven nav. **Critically, set
`site_url: https://www.deployza.com/docs/`** (not site root) — this VM
serves the built site under the `/docs/` prefix (§3), and MkDocs needs
`site_url` to generate correct absolute asset/canonical links for that
prefix.

**`requirements.txt`** — pinned `mkdocs-material` and
`mkdocs-awesome-pages-plugin` versions.

**`docs/` tree** — `index.md`, `getting-started.md`, `_template.md`
(Overview / Base URL / Authentication / Endpoints / Errors sections), family
folders (`api-auth`, `api-billing`, `api-retail`, `api-catalog`) each with a
`.pages` file + `index.md`, and one filled-out example
(`api-auth/api-auth-user.md`) built from the template.

**`README.md`** — `mkdocs serve` locally, how to add a new API doc (copy
`_template.md` into the right family folder), how the deploy pipeline works.

**`cloudbuild.yaml`** (replaces the GH Actions workflow the original
`plan.md` asked for):

```yaml
steps:
  - name: 'python:3.12-slim'
    entrypoint: bash
    args:
      - -c
      - |
        pip install -r requirements.txt
        mkdocs build --strict

  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk:slim'
    entrypoint: gsutil
    args: ['-m', 'rsync', '-r', '-d', 'site/',
           'gs://deployza-apps/production/api-docs/site/']
```

`-d` mirrors deletions (a removed/renamed doc page disappears from the
bucket, and then from `/var/www/api-docs` on the VM's next timer tick). No
`GCP_VM_HOST`/`GCP_VM_USER`/`GCP_VM_SSH_KEY` secrets, no SSH action — the VM
pulls (§3), Cloud Build only pushes to GCS.

---

## Verification

- **Image build**: `gcloud builds submit --config images/ubuntu/nginx/cloudbuild.yaml --service-account=projects/tools-tech-463909/serviceAccounts/build-service-account@tools-tech-463909.iam.gserviceaccount.com --project=tools-tech-463909 .` — confirm the `nginx` family publishes and `cat /etc/image-manifest.txt` on a test VM shows the right nginx version.
- **Terraform**: `terraform plan` in `website/` and `devops/` (Packer/Terraform
  execution stays a human or CI step per this repo's Conventions — not run
  from a Claude session).
- **www-website pipeline**: push to `www-website` main, confirm the Cloud
  Build trigger runs and `gsutil ls gs://deployza-apps/production/www-website/`
  shows the new WAR + `install/`.
- **api-docs pipeline**: push to `api-docs` main, confirm
  `gsutil ls gs://deployza-apps/production/api-docs/site/` populates, then
  (after the VM's `docs-refresh.timer` ticks) `curl -I
  https://www.deployza.com/docs/` shows `Cache-Control: no-cache,
  must-revalidate`, `Pragma: no-cache`, `Expires: 0`.
- **Marketing site**: `curl -I https://www.deployza.com/` also shows the
  same no-cache headers — the whole host is no-cache, not just `/docs/`.
- `journalctl -u vm-startup.service -b` and
  `journalctl -u docs-refresh.service` on the VM are the first places to
  check if either path is missing content.
- Confirm `files.deployza.com`, `mcp.deployza.com`, `www.ziniapps.com`,
  `go.ziniapps.com`, `one.deployza.com` are all unaffected (no changes to
  their url-map entries).
