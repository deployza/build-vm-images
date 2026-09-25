# CLAUDE.md

Guidance for Claude Code when working in this repository.

> ## 📖 Read the architecture docs first
> The overall Cloud Build / deploy / Terraform architecture lives in the
> **`build-docs`** repo, cloned as a sibling of this one:
> [`../build-docs/README.md`](../build-docs/README.md) — see especially
> [`../build-docs/build-system.md`](../build-docs/build-system.md).
>
> **If that path does not exist, you have not cloned `build-docs` yet — stop and
> clone it first** (it sits next to this repo under `Build/`):
> ```bash
> git clone https://bitbucket.org/deployza/build-docs.git
> ```
> Without it you are missing the cross-repo context.

## What this repo is

**VM disk-image pipelines.** Packer templates (`*.pkr.hcl`) +
`*-cloudbuild.yaml` that bake bootable **GCE images** (Ubuntu + JDK + Maven +
Tomcat-as-systemd) and store them as image families (e.g. `tomcat`). This is the
VM-image equivalent of the `docker/` repo (which builds container images).

Packer **provisions the image by running the installers in
[`scripts/<os>/`](scripts/)**, which live in this repo.
These are self-contained — there is no build-time dependency on a sibling repo.

> **OS-keyed layout.** Both `scripts/` and `images/` are keyed by base OS
> (`scripts/<os>/`, `images/<os>/<flavor>/`) so the repo can support more than one
> base distro without coupling their installers. Ubuntu is the only OS implemented
> today (`scripts/ubuntu/`, `images/ubuntu/`). A future OS (e.g. CentOS/Rocky) gets
> its own parallel tree (`scripts/centos/`, `images/centos/`) — the two are kept
> **independent**, not merged behind a package-manager shim, because RHEL-family
> divergence (SELinux, firewalld, repo RPMs, dnf, package names) is large.

> **Self-contained installers.** The installers (`install-basics.sh`,
> `install-gcloud.sh`,
> `install-java.sh`, `install-tomcat.sh`, `install-nginx.sh`, `install-mysql.sh`,
> `install-python.sh`, `write-manifest.sh`, `versions.env`, `setenv.sh`,
> `server.xml`, `tomcat.service`) live under `scripts/<os>/`, or, where a
> component owns several files, under a per-component subfolder of it
> (`scripts/<os>/tomcat/`, `.../otelcol/`, ... — see the layout below).
> They are owned by this repo. (Maven is intentionally **not** installed into the
> VM images — WARs are built by the docker `maven` image at build time.)
> The `docker/` repo (`build-docker`) maintains its **own** equivalent install
> steps inline in its Dockerfiles — the two are deliberately **independent copies,
> not a shared source**. Do not reintroduce a cross-repo "single source" coupling;
> if a version needs to change in both, change both.

> **Per-flavor asset bundles.** `scripts/<os>/` proper holds the **shared**
> installers — the ones several flavors run (`install-basics.sh`,
> `install-java.sh`, …). A flavor that brings a large set of files **used by
> nothing else** puts them in its own subdirectory, `scripts/<os>/<flavor>/`, and
> the flavor's Packer template invokes
> `bash /tmp/scripts/<flavor>/install-<flavor>.sh`. The `file` provisioner copies
> `scripts/<os>/` recursively, so the subdirectory arrives at
> `/tmp/scripts/<flavor>/` with no template change beyond that path.
> `tomcat/`, `semaphore/` and `clickhouse/` do this today. Keep genuinely shared
> installers flat — this is for single-flavor payloads, not a general
> reorganisation. (`mcp/` did it until image 1-3; its payload was the
> application, not the software, and moved to build-ops — see below.)

> **Software in the image, the application in build-ops.** An image bakes the
> runtime an app needs (a JDK, Tomcat, nginx, a Python venv); the app itself, its
> config and its systemd units are pushed to a running VM by `build-ops`
> (`vm/<vm>/<app>.sh`, driven by Ansible). The `mcp` flavor broke this until
> image 1-3 by baking the whole MCP server — its gateway code, helpers, units
> and `mcp.env` — so a config change meant a rebake and a VM replacement. It now
> bakes only `/opt/mcp/venv`; the rest is `build-ops/vm/mcp-vm/`. Hold new
> flavors to the same line.

> **Why some scripts have no `.sh`.** The extension tracks **how the file is
> invoked**. Handed to an interpreter (`bash /tmp/scripts/install-basics.sh`) →
> keep it. Installed to `/usr/local/bin` and invoked as a command → drop it, and
> name the file in-tree exactly as it is installed. The `mcp` helpers followed
> this rule while they lived here (they are in `build-ops/vm/mcp-vm/mcp/` now,
> same names). The shebang carries the language for editors and for graphify's
> own indexer, but a `**/*.sh` glob will skip such files — **lint by shebang,
> not by extension**.
> Upstream names (Tomcat's `catalina.sh`/`setenv.sh`) are not ours to
> choose.

> **Current state.** Seven flavors are implemented under `images/ubuntu/<flavor>/`,
> each with an `image.pkr.hcl` + `cloudbuild.yaml` + a `<flavor>.md` doc:
> `tomcat`, `mysql`, `tomcat-mysql`, `tomcat-mysql-nginx`,
> `mcp` (the code knowledge-graph MCP server), `nginx` (a lean, Tomcat-free
> static web front door) and `ops` (Ansible + Semaphore UI + ClickHouse +
> Grafana) — `mcp`, `nginx` and `ops` are the flavors with no Java. Every
> image family is the flavor name with a `dz-` prefix (`dz-tomcat`).
> The `java`, `git` (Gitea) and `nginx-python` flavors were removed on
> 2026-09-25: nothing launched them, and with pinned CPython on every flavor
> `nginx-python` no longer differed usefully from `nginx`.
> Shared installers and
> pinned versions (plus `FILES_BASE_URL`, the download base) live in
> `scripts/ubuntu/`. The GCP `project`/`zone` variables are declared (with
> defaults) inside each flavor's `image.pkr.hcl` — Packer's `validate`/`build`
> take a single template (or directory), not a list of files, so there is no
> separate shared vars file to pass alongside.

## Conventions

- **Do not run `packer` locally** (`validate`, `build`, `init`, `fmt`). Packer is
  not installed in this environment, and these templates target GCE — builds only
  run in Cloud Build (from the repo root, `/workspace`). Reason about template
  correctness by reading the HCL; the real validation is the next Cloud Build run.
- **A hand-run `gcloud builds submit` MUST pass `--service-account`.** Cloud Build
  no longer defaults to the legacy `<project-number>@cloudbuild.gserviceaccount.com`;
  a build submitted without an explicit identity runs as the **Compute Engine
  default** SA and dies before it starts, on the source tarball it cannot read:

  ```
  ERROR: could not resolve source: googleapi: Error 403:
  347018192564-compute@developer.gserviceaccount.com does not have
  storage.objects.get access to the Google Cloud Storage object
  ```

  It reads like a bucket problem and is an identity one — your own credentials
  uploaded the tarball fine; the *build* cannot read it back. Pass the same SA the
  triggers use (`build-terraform/builds/cloudbuild-triggers.tf`):

  ```bash
  gcloud builds submit \
    --config images/ubuntu/<flavor>/cloudbuild.yaml \
    --service-account=projects/dz-builds/serviceAccounts/build-service-account@dz-builds.iam.gserviceaccount.com \
    --project=dz-builds \
    .
  ```

  Verified 2026-08-25 on the `mcp` flavor: bare command fails as above, this
  one succeeds. Triggers are unaffected — they already set `service_account`.
  Only `mcp/mcp.md` shows the corrected form; the other six still show the bare
  one. Treat this section as the correction until they are updated.
- One `image.pkr.hcl` + `cloudbuild.yaml` per image folder (the folder name is
  the flavor, so the filenames stay unprefixed).
- Use `image_family` so consumers track the latest non-deprecated image.
- Image **names** (`dz-<flavor>-<version>`) are unique per project: rebuilding an
  existing version hard-fails at image-create (GCE `409 alreadyExists`) and never
  overwrites. Bump `image_version` to publish; the family pointer advances on its
  own. No explicit pre-check is needed — GCE enforces this.
- Cloud Build SA needs `roles/compute.instanceAdmin.v1` +
  `roles/iam.serviceAccountUser` (Packer creates a temp VM); enable
  `compute.googleapis.com`.
- The templates set no `network`/`subnetwork`, so the temp bake VM lands on the
  project's **`default`** VPC — it must exist (`gcloud compute networks create
  default --subnet-mode=auto`, plus a tcp:22 firewall rule). A missing one fails
  with `Error 400 … 'global/networks/default' … cannot be found`. **Use a
  throwaway/isolated VPC only — never a Shared VPC or one holding production
  assets:** the bake VM runs the `install-*.sh` provisioners as root and is
  SSH-reachable, so a tampered installer would execute inside whatever network it
  sits in. See `build-system.md` §3 for the commands and rationale.
- See `build-system.md` §3 in `build-docs` for the full template and rationale.

## Log & disk hygiene (VM-only)

Because these images run services **directly on the VM** (Tomcat/MySQL as
systemd units), the host owns log and disk management. Two layers:

- **Host-wide, generic** — `scripts/ubuntu/logs/logs-system.sh` (systemd journal
  retention, core-dump size caps, generic `/opt` logrotate + a logrotate dry-run
  that **fails the bake** if any rule on the image does not parse) and
  `scripts/ubuntu/logs/logs-disk-tools.sh` (`disk-audit` / `disk-alert` helpers). Set
  only what differs from the OS defaults. Both run on **every** flavor, last
  before `write-manifest.sh` — `logs-disk-tools.sh` does `apt-get clean`, so it
  has to follow the last apt work (`install-python.sh`) to reclaim anything.
  They lived at `scripts/` root until 2026-09-24 and were therefore never
  shipped by the file provisioner (`source = "scripts/ubuntu/"`) and had never
  run; do not move them back out.
- **Per-service** — each installer owns its own log config: Tomcat log rotation
  in `install-tomcat.sh` (app logs live under `/home/tomcat/instance/logs/<app>/`,
  written per the app's own logback config),
  MySQL file rotation **and** binlog retention in `install-mysql.sh`, nginx's
  `/var/log/nginx/*.log` rotation in `install-nginx.sh`. Keep
  service log config with the service that produces it, not in the `logs-*`
  scripts. Tomcat's per-request access log is **off**: the repo-owned
  `scripts/ubuntu/tomcat/server.xml` simply omits upstream's `AccessLogValve`, so no
  `localhost_access_log.*.txt` files are written — matching the fleet-wide
  access-log-off decision in the docker images.

> **nginx's access log is the one exception, and it is intentional.**
> `install-nginx.sh` leaves `access_log` **on** and rotates it, where
> `build-docker/nginx` turns it off. The docker rule exists because a container
> has no logrotate and an unbounded file lands on the overlay layer; on a VM that
> premise is false — logrotate is present and the disk is the host's. nginx is
> also the edge here, so its access log is the only record of who reached the VM.
> Tomcat's access log stays off because nginx now produces the same information
> one hop earlier; keeping both would log every request twice.

**This model is VM-only — do not port it to Docker.** Containers don't get
in-image logrotate/journald/cron; applications there log to `stdout`/`stderr`
and the Docker daemon's log driver caps size at the host. See
`build-docker/CLAUDE.md` → "Logging" for the container stance and why it's the
deliberate opposite of this.

## One-time project setup (prerequisites for a successful build)

A Cloud Build run will not succeed until **all** of the following exist in the
target GCP project. These are one-time, per-project steps.

1. **Enable the Compute API:**
   ```bash
   gcloud services enable compute.googleapis.com
   ```

2. **Grant the Cloud Build service account the roles Packer needs.** Packer
   creates a temporary "bake" VM, SSHes in to run the `install-*.sh`
   provisioners as root, snapshots the disk into an image, then deletes the VM.
   The Cloud Build SA is the identity doing all of that.

   > **`$CB_SA` below is the LEGACY default and is no longer what runs a build.**
   > Cloud Build now uses the Compute Engine default SA unless a build names an
   > identity. In `dz-builds` the identity that actually matters is
   > `build-service-account@dz-builds.iam.gserviceaccount.com` — it is what
   > every trigger sets and what a hand-run submit must pass via
   > `--service-account` (see Conventions). It already holds these roles, granted
   > in `build-terraform/dz-builds/service-accounts.tf`, so in this project step 2 is
   > already done. The commands below remain correct for standing up a *new*
   > project; substitute the SA you intend builds to run as.
   ```bash
   PROJECT_ID="$(gcloud config get-value project)"
   PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
   CB_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

   # Create / manage / delete the temp bake VM
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="serviceAccount:${CB_SA}" \
     --role="roles/compute.instanceAdmin.v1"

   # Let the SA attach a service account to that VM (required, or VM creation
   # fails with "does not have permission to act as ...")
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="serviceAccount:${CB_SA}" \
     --role="roles/iam.serviceAccountUser"
   ```

3. **Create the `default` VPC with SSH ingress.** The templates set no
   `network`/`subnetwork`, so the bake VM lands on the `default` VPC and Packer
   must reach it over tcp:22. A missing network fails with
   `Error 400 … 'global/networks/default' … cannot be found`; a missing SSH rule
   leaves the build hanging on the SSH connection.
   ```bash
   gcloud compute networks create default --subnet-mode=auto

   gcloud compute firewall-rules create default-allow-ssh \
     --network=default \
     --direction=INGRESS \
     --action=ALLOW \
     --rules=tcp:22 \
     --source-ranges=35.235.240.0/20   # IAP range; widen only if needed
   ```
   **Use a throwaway/isolated VPC only — never a Shared VPC or one holding
   production assets:** the bake VM runs the installers as root and is
   SSH-reachable, so a tampered installer would execute inside whatever network
   it sits in.

## Recommended repository layout

To support multiple VM images with shared provisioning, organize the repo into image-specific folders plus common shared definitions.

Example structure:

```
build-vm-images/
  scripts/
    ubuntu/                   # toolchain installers for Ubuntu, owned by this repo
      versions.env            # single source for pinned versions (stays at the top level:
                              # every installer sources it, grouped ones as ../versions.env)
      install-basics.sh       # apt basics ONLY (distro python3 + venv/pip included)
      install-gcloud.sh       # Google Cloud CLI: third-party apt repo + key
      install-python.sh       # pinned CPython, compiled; its own provisioner line, kept LAST
      install-java.sh
      install-mysql.sh
      install-mkdocs.sh
      install-ansible.sh      # ansible + ansible-core venv, on PATH (ops)
      install-grafana.sh      # Grafana OSS + ClickHouse plugin, NOT enabled
      write-manifest.sh       # bakes /etc/image-manifest.txt (build-system.md §5)
      # A component that owns more than its installer gets a folder, holding the
      # installer NEXT TO the units and config files it installs. The file
      # provisioner copies scripts/ubuntu/ recursively, so these arrive as
      # /tmp/scripts/<group>/ and are invoked by that path.
      tomcat/
        install-tomcat.sh
        nginx-tomcat.sh       # enables Tomcat's RemoteIpValve; its own provisioner step
        server.xml            # repo-owned Tomcat conf/server.xml (see below)
        setenv.sh
        tomcat.service
      nginx/
        install-nginx.sh
        install-nginx-static.sh  # nginx with no Tomcat upstream (static / Python flavors)
      otelcol/
        install-otel.sh       # OpenTelemetry Collector, INERT (every flavor)
        otelcol.service       # collector unit (not a template, unlike tomcat.service)
        otelcol-base.yaml     # the inert nop config baked as /etc/otelcol/config.yaml
      cloud-sql-proxy/
        install-cloud-sql-proxy.sh  # Cloud SQL Auth Proxy, INERT (every flavor)
        cloud-sql-proxy.service # proxy unit — installed but NOT enabled at bake
        cloud-sql-proxy.env   # the empty instance config baked as /etc/cloud-sql-proxy/env
      semaphore/
        install-semaphore.sh
        semaphore.service     # installed but NOT enabled at bake (no config yet)
        config.example.json   # baked as /etc/semaphore/config.json.example
      clickhouse/
        install-clickhouse.sh
        clickhouse-config.xml # baked as config.d/deployza.xml (loopback, log caps, TTLs)
        clickhouse-users.xml  # baked as users.d/deployza.xml (default user: loopback only)
      logs/
        logs-system.sh        # host-wide journald + logrotate policy (every flavor)
        logs-disk-tools.sh    # disk-audit / disk-alert helpers (every flavor)
      install-mcp.sh          # graphify + fastmcp venv ONLY (mcp); the app is build-ops'
        ...
  images/
    ubuntu/
      tomcat/
        image.pkr.hcl
        cloudbuild.yaml
        tomcat.md
      mysql/
        image.pkr.hcl
        cloudbuild.yaml
        mysql.md
      tomcat-mysql/
        image.pkr.hcl
        cloudbuild.yaml
        tomcat-mysql.md
      tomcat-mysql-nginx/
        image.pkr.hcl
        cloudbuild.yaml
        tomcat-mysql-nginx.md
```

A second base OS (e.g. `centos`) is added as sibling `scripts/centos/` +
`images/centos/<flavor>/` trees — never by branching inside the Ubuntu scripts.

### Why this layout

- `images/<os>/<flavor>/` keeps each image definition isolated and easy to maintain.
- `scripts/<os>/` contains the shared provisioning installers (owned by this repo).
- The GCP `project`/`zone` variables are declared (with defaults) inside each
  flavor's `image.pkr.hcl`. Packer's `validate`/`build` accept only a single
  template (or one directory) as their positional argument — not a list of files —
  so there is no separate cross-flavor vars file passed alongside the template.
  Override with `-var=project=…` / `-var=zone=…` if a build needs a different
  target. Per-build values (`image_version`, `git_sha`) are passed as `-var` by
  each `cloudbuild.yaml`; tool versions stay in `versions.env`.
- Each flavor's Packer template references its OS's installers via a repo-root
  relative path (`scripts/<os>/`) within this repo. Packer resolves the `file`
  provisioner `source` against its working directory, and the `cloudbuild.yaml`
  steps run `packer` from the workspace root (`/workspace`) — they pass the
  template by full path (`images/<os>/<flavor>/image.pkr.hcl`) and do **not** use
  the Cloud Build `dir:` attribute. The `file` provisioner uploads the installers
  to `/tmp/scripts/` (a `mkdir -p /tmp/scripts` shell step runs first so the
  trailing-slash contents copy has a target).

### Telemetry: baked but inert

`install-otel.sh` runs on **every** flavor and installs the OpenTelemetry
Collector (contrib) plus `otelcol.service`, with `otelcol-base.yaml` baked as
`/etc/otelcol/config.yaml`. That base config is a `nop` pipeline: the service is
running and healthy but **reads nothing and exports nowhere**.

Real configuration is **pushed** to a running VM over SSH from
`build-ops/otel/`, which swaps `config.yaml` and restarts the service.
Nothing on the VM clones, pulls or polls for it, and no collector config belongs
in this repo beyond the inert base.

Two things to know before touching it:

- **`versions.env` here is the only `OTELCOL_VERSION` pin.**
  `build-ops/otel/cloudbuild.yaml` held a second copy until it was
  deleted on 2026-09-24 (that repo is not connected to Cloud Build, so nothing
  ever triggered the job). There is now no CI on the otel configs at all —
  `push.sh --dry-run` validates against whatever `otelcol-contrib` the pusher
  has, so that binary should match this pin.
- **The `otelcol` user is created with no supplementary groups.** Which groups
  it needs (`adm`, `tomcat`) depends on what the VM runs, which is a push-time
  decision. Do not add them here.

Full design and reasoning: `../build-docs/ops-execution.md`.

### Database access: baked but inert, and NOT enabled

`install-cloud-sql-proxy.sh` runs on **every** flavor and installs the Cloud SQL
Auth Proxy binary (`/opt/cloud-sql-proxy/bin/cloud-sql-proxy`) plus
`cloud-sql-proxy.service`, with `cloud-sql-proxy.env` baked as
`/etc/cloud-sql-proxy/env` — an **empty** `CSP_INSTANCES`. A VM booted from any
of these images connects to no database.

**The unit is installed but NOT enabled, and that is the one way this differs
from otel.** The collector's inert `nop` config is still a valid config, so it
can run healthily with nothing to do. The proxy has no such state: given no
instance connection name it exits non-zero at once, so an enabled unit would put
every VM in the fleet into restart backoff at boot. The deploy step that knows
the instance turns it on:

```bash
printf 'CSP_INSTANCES=%s\n' "my-project:asia-east1:my-instance" \
  >> /etc/cloud-sql-proxy/env
systemctl enable --now cloud-sql-proxy.service
```

Three things to know before touching it:

- **It listens on 127.0.0.1:3307, not 3306.** 3306 belongs to the local MySQL
  daemon on the `mysql` / `tomcat-mysql` / `tomcat-mysql-nginx` flavors, and one
  env file that is correct on every flavor is worth more than matching the
  upstream default port. A Cloud SQL JDBC URL is therefore
  `jdbc:mysql://127.0.0.1:3307/<db>`. Never bind the listener beyond loopback:
  the proxy terminates an *authenticated* tunnel, so whatever reaches that port
  is the database client.
- **There are no credentials to bake.** The proxy authenticates as the VM's own
  service account through the metadata server, so what it needs is an IAM grant
  — `roles/cloudsql.client` on the target instance — not a key file. A missing
  grant is a 403 in `journalctl -u cloud-sql-proxy`, not a refused connection.
- **The process, not the JDBC socket factory.** The Java connector library would
  serve the Tomcat flavors only; a process serves the Python flavors, a `mysql`
  shell during an incident, and any future runtime through one mechanism.

### Image composition guidance

Each `images/<os>/<flavor>/` folder produces one image **family**, named
`dz-<flavor>` — the folder stays unprefixed, the family carries the `dz-`
prefix. The `tomcat` flavor is the one `build-system.md`
uses throughout (Tomcat implies Java, so there is no separate `java-tomcat`).

- `tomcat` (family `dz-tomcat`): basic tools + Java + Tomcat (the primary flavor).
- `mysql` (family `dz-mysql`): basic tools + MySQL daemon only.
- `tomcat-mysql` (family `dz-tomcat-mysql`): basic tools + Java + Tomcat + MySQL.
- `mcp` (family `dz-mcp`): basic tools + a Python venv holding graphify (with
  its tree-sitter grammars) and fastmcp — the MCP server's runtime only. The
  server, gateway, refresh and their units are pushed by
  `build-ops/vm/mcp-vm/`. **No Java, no Tomcat.** See `images/ubuntu/mcp/mcp.md`.
- `tomcat-mysql-nginx` (family `dz-tomcat-mysql-nginx`): the above plus nginx on
  port 80, able to serve static content and proxy to Tomcat at
  `127.0.0.1:8080`. **The routing between the two is not baked** — the image
  ships an empty `/etc/nginx/app.d/` that the app deploy script writes into, the
  same way MySQL is baked without credentials. Do not add app-specific
  `location` blocks to `install-nginx.sh`.
- `nginx` (family `dz-nginx`): basic tools + nginx only, serving static content.
  **No Java, no Tomcat, no MySQL** — for a VM that is a pure web front door
  with no app server of its own. Uses its own installer,
  `install-nginx-static.sh`, rather than `install-nginx.sh`: the latter bakes
  a Tomcat upstream and a `proxy-to-tomcat.conf` snippet that would be dead
  weight here. Same empty `/etc/nginx/app.d/` + `/nginx-health` seam and
  README contract as `install-nginx.sh`, just without the Tomcat pieces. See
  `images/ubuntu/nginx/nginx.md`.
- `ops` (family `dz-ops`): basic tools + Ansible (venv) + Semaphore UI +
  ClickHouse + Grafana with the ClickHouse datasource plugin. **No Java, no
  Tomcat, no nginx.** Named for its purpose, like `mcp`, rather than
  by joining tool names: four tools made that name too long. Only ClickHouse is enabled
  (loopback-only, safe as baked). Grafana (it would boot into `admin/admin`) and
  Semaphore (it cannot start without its secrets) are installed but **not
  enabled**, following the cloud-sql-proxy precedent. Semaphore is on `:3001`
  because Grafana owns `:3000`. The bake starts ClickHouse once to prove its
  config, then wipes `/var/lib/clickhouse`: first start writes the server's
  `uuid`, and every VM booted from the image must not share it. See
  `images/ubuntu/ops/ops.md`.

> **Tomcat's `conf/server.xml` is owned by this repo** — `scripts/ubuntu/tomcat/server.xml`
> is upstream's file with two deliberate changes (no `AccessLogValve`; a
> `RemoteIpValve` present but commented out), installed verbatim by
> `install-tomcat.sh`. Change configuration by editing that file, **never** by
> adding a `sed`/`awk` patch to an installer: a range-based regex on XML can
> silently emit malformed output, which fails at VM boot rather than at bake time.
> On a Tomcat bump, diff it against the new release's `conf/server.xml` (the
> procedure is in the file's own header).
>
> **Only `scripts/ubuntu/tomcat/nginx-tomcat.sh` enables the `RemoteIpValve`** (by
> deleting the `DEPLOYZA-REMOTEIP-BEGIN`/`END` marker lines). It is a **separate
> provisioner line** in a flavor's `image.pkr.hcl`, run after `install-nginx.sh`
> — `install-nginx.sh` does not call it, so granting this trust stays an explicit
> per-flavor choice. Only `tomcat-mysql-nginx` includes the line; it is also
> runnable standalone on a live VM. It tells Tomcat to trust
> `X-Forwarded-*`, which is only safe where a proxy is the sole path to the
> connector. Enabling it on the `tomcat` / `tomcat-mysql` flavors, where Tomcat is
> the front door, would let any client that reaches `:8080` forge its client IP
> and claim `X-Forwarded-Proto: https`. Keep `internalProxies` at loopback only;
> Tomcat's RFC1918 default would trust the whole VPC.

**nginx is the fleet's HTTP server — do not add Apache HTTPD.** The sibling
`build-docker` repo already ships an `nginx` image, and one web server across
both halves of the platform means one config dialect to know. The workload is
reverse-proxying Tomcat, where HTTPD's advantages (`mod_php`, `.htaccess`) do not
apply. As with the other installers, the docker and VM copies of the nginx
install step are deliberately **independent** — the shared decision is the
software, not the source.

Naming convention: a flavor named after a tool includes that tool plus its
prerequisites (so `tomcat` ⇒ Java, no redundant `java-` prefix). Combined
flavors join the tool names with `-` (`tomcat-mysql`). The image **family** is
the flavor name with a `dz-` prefix (e.g. `dz-tomcat`), which marks our images
apart from public ones in a GCE image listing; the version lives in the
`image_name` (`dz-tomcat-1-1`) and in image **labels** — never in the family — so
consumers track `--image-family=dz-tomcat` without ever chasing minor-version
bumps. The `flavor` label and `IMAGE_FLAVOR` stay the bare flavor name.

Each image runs `install-basics.sh` then `install-gcloud.sh` first, then the
additional installer scripts required by that flavor, then `install-otel.sh` +
`install-cloud-sql-proxy.sh`, and finishes with `install-python.sh` +
`write-manifest.sh`.

> **Every installer gets its own provisioner line — no installer calls
> another.** `install-basics.sh` used to end by invoking `install-python.sh`,
> and used to add the Google Cloud apt repo itself. Both are now separate files
> with their own line in every `image.pkr.hcl`. Chaining hid two steps with
> quite different failure modes — an upstream repo signing key, and a
> 15-minute source build — behind one `install-basics.sh` entry in the build
> log, and it meant a template did not say what the flavor actually installs.
> The three baseline lines (`basics`, `gcloud`, `python`) are now as visible in
> a diff as `install-otel.sh` and `install-cloud-sql-proxy.sh` are, and a new
> flavor that omits one is caught by reading the template rather than by a
> missing binary on a booted VM. `nginx-tomcat.sh` already worked this way for
> the same reason; keep it that way for anything added next.
>
> **`install-python.sh` is kept LAST, immediately before `write-manifest.sh`.**
> It is by far the slowest step, so every cheap failure in every other
> installer surfaces before the compile rather than 15 minutes after it.
> Nothing in a bake depends on its output — `install-mkdocs.sh` and
> `install-mcp.sh` build their venvs from the **distro** `python3` that
> `install-basics.sh` puts down — so running it last costs nothing.

> **Python is baseline on every flavor, and it costs every bake 10-20
> minutes.** `install-basics.sh` installs the distro's
> `python3`/`python3-venv`/`python3-pip` from apt, and a separate
> `install-python.sh` line in every flavor's template **compiles** the pinned
> CPython from source into `/opt/python/<version>` (symlink
> `/opt/python/latest`, the same `/opt/<tool>/latest` layout as
> `/opt/java/latest`).
>
> Source-built because there is no alternative that stays pinned: Ubuntu 24.04
> has no 3.14 package at all, and the usual backport (the deadsnakes PPA)
> publishes "latest 3.14.x" rather than a named patch, so an apt route would
> hand a *different* interpreter to each rebuild. `PYTHON_VERSION` in
> `versions.env` is therefore a full `X.Y.Z`, and the script verifies at bake
> time that what it built reports exactly that.
>
> **Consequence for every flavor, including a new one you add:** the PGO+LTO
> build needs `machine_type = "e2-standard-8"` and `disk_size = 20` in the
> template, and `timeout: 3600s` in `cloudbuild.yaml` — Cloud Build's
> 10-minute default cannot fit it, and a timeout strands the temp Packer VM.
> All ten flavors carry all three. **Copy them into any new flavor** or its
> first bake fails on the clock, in a way that looks nothing like a Python
> problem.
>
> The cheaper alternatives were considered and rejected: keeping the compile
> opt-in per flavor, and publishing a prebuilt tarball to
> `${FILES_BASE_URL}/installables/` the way the JDK is shipped. The tarball
> route is the one to revisit if bake time becomes painful — it would return
> every flavor to a seconds-long install, at the price of a manual
> build-and-upload step on each Python bump.
>
> **Never repoint `/usr/bin/python3` at it.** The distro interpreter stays the
> system one — apt, unattended-upgrades and the gcloud CLI all run against it —
> so `install-python.sh` uses a private prefix and adds only **versioned**
> names (`python3.14`, `pip3.14`) to `/usr/local/bin`. A bare `python3` there
> would sit ahead of `/usr/bin` for every root process and is the classic way
> to leave a box unable to run apt. Unversioned names reach login shells
> through `/etc/profile.d/python.sh` only, so a systemd unit that wants this
> interpreter must name it (`python3.14`, or its venv's own `bin/python`).
>
> **Python is not an image label.** Labels carry what distinguishes a flavor,
> and baseline tools (git and curl from `install-basics.sh`, gcloud from
> `install-gcloud.sh`) have never been labelled. The version is in
> `/etc/image-manifest.txt` on every image.
