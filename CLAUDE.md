# CLAUDE.md

Guidance for Claude Code when working in this repository.

> ## 📖 Read the architecture docs first
> The overall Cloud Build / deploy / Terraform architecture lives in the
> **`build-docs`** repo, cloned as a sibling of this one:
> [`../build-docs/README.md`](../build-docs/README.md) — see especially
> [`../build-docs/build-design.md`](../build-docs/build-design.md).
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
> `install-java.sh`, `install-tomcat.sh`, `install-nginx.sh`, `install-mysql.sh`,
> `write-manifest.sh`, `versions.env`, `setenv.sh`, `server.xml`,
> `tomcat.service`) live under `scripts/<os>/`.
> They are owned by this repo. (Maven is intentionally **not** installed into the
> VM images — WARs are built by the docker `maven` image at build time.)
> The `docker/` repo (`build-docker`) maintains its **own** equivalent install
> steps inline in its Dockerfiles — the two are deliberately **independent copies,
> not a shared source**. Do not reintroduce a cross-repo "single source" coupling;
> if a version needs to change in both, change both.

> **Current state.** Six flavors are implemented under `images/ubuntu/<flavor>/`,
> each with an `image.pkr.hcl` + `cloudbuild.yaml` + a `<flavor>.md` doc:
> `java`, `tomcat`, `mysql`, `tomcat-mysql`, `tomcat-nginx-mysql`, `git` (Gitea).
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
- One `image.pkr.hcl` + `cloudbuild.yaml` per image folder (the folder name is
  the flavor, so the filenames stay unprefixed).
- Use `image_family` so consumers track the latest non-deprecated image.
- Image **names** (`<flavor>-<version>`) are unique per project: rebuilding an
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
  sits in. See `build-design.md` §3 for the commands and rationale.
- See `build-design.md` §3 in `build-docs` for the full template and rationale.

## Log & disk hygiene (VM-only)

Because these images run services **directly on the VM** (Tomcat/MySQL as
systemd units), the host owns log and disk management. Two layers:

- **Host-wide, generic** — `scripts/logs-system.sh` (systemd journal retention,
  core-dump size caps, generic `/opt` logrotate + a logrotate dry-run) and
  `scripts/logs-disk-tools.sh` (`disk-audit` / `disk-alert` helpers). Set only
  what differs from the OS defaults.
- **Per-service** — each installer owns its own log config: Tomcat log rotation
  in `install-tomcat.sh` (app logs live under `/home/tomcat/instance/logs/<app>/`,
  written per the app's own logback config),
  MySQL file rotation **and** binlog retention in `install-mysql.sh`, nginx's
  `/var/log/nginx/*.log` rotation in `install-nginx.sh`. Keep
  service log config with the service that produces it, not in the `logs-*`
  scripts. Tomcat's per-request access log is **off**: the repo-owned
  `scripts/ubuntu/server.xml` simply omits upstream's `AccessLogValve`, so no
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
   The Cloud Build SA is the identity doing all of that:
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
      install-basics.sh
      install-java.sh
      install-tomcat.sh
      install-nginx.sh
      nginx-tomcat.sh         # enables Tomcat's RemoteIpValve; its own provisioner step
      install-mysql.sh
      write-manifest.sh       # bakes /etc/image-manifest.txt (build-design.md §9)
      versions.env            # single source for pinned versions
      setenv.sh
      server.xml              # repo-owned Tomcat conf/server.xml (see below)
      tomcat.service
  images/
    ubuntu/
      java/
        image.pkr.hcl
        cloudbuild.yaml
        java.md
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
      tomcat-nginx-mysql/
        image.pkr.hcl
        cloudbuild.yaml
        tomcat-nginx-mysql.md
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

### Image composition guidance

Each `images/<os>/<flavor>/` folder produces one image **family**. The flavor folder
name and the family name match. The `tomcat` flavor is the one `build-design.md`
uses throughout (Tomcat implies Java, so there is no separate `java-tomcat`).

- `java` (family `java`): basic tools + Java only.
- `tomcat` (family `tomcat`): basic tools + Java + Tomcat (the primary flavor).
- `mysql` (family `mysql`): basic tools + MySQL daemon only.
- `tomcat-mysql` (family `tomcat-mysql`): basic tools + Java + Tomcat + MySQL.
- `tomcat-nginx-mysql` (family `tomcat-nginx-mysql`): the above plus nginx on
  port 80, able to serve static content and proxy to Tomcat at
  `127.0.0.1:8080`. **The routing between the two is not baked** — the image
  ships an empty `/etc/nginx/app.d/` that the app deploy script writes into, the
  same way MySQL is baked without credentials. Do not add app-specific
  `location` blocks to `install-nginx.sh`.

> **Tomcat's `conf/server.xml` is owned by this repo** — `scripts/ubuntu/server.xml`
> is upstream's file with two deliberate changes (no `AccessLogValve`; a
> `RemoteIpValve` present but commented out), installed verbatim by
> `install-tomcat.sh`. Change configuration by editing that file, **never** by
> adding a `sed`/`awk` patch to an installer: a range-based regex on XML can
> silently emit malformed output, which fails at VM boot rather than at bake time.
> On a Tomcat bump, diff it against the new release's `conf/server.xml` (the
> procedure is in the file's own header).
>
> **Only `scripts/ubuntu/nginx-tomcat.sh` enables the `RemoteIpValve`** (by
> deleting the `DEPLOYZA-REMOTEIP-BEGIN`/`END` marker lines). It is a **separate
> provisioner line** in a flavor's `image.pkr.hcl`, run after `install-nginx.sh`
> — `install-nginx.sh` does not call it, so granting this trust stays an explicit
> per-flavor choice. Only `tomcat-nginx-mysql` includes the line; it is also
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
the bare flavor name (e.g. `tomcat`); the tool version lives in the `image_name`
(`tomcat-1-0-0`) and in image **labels** — never in the family — so consumers
track `--image-family=tomcat` without ever chasing minor-version bumps.

Each image runs `install-basics.sh` first, then the additional installer scripts
required by that flavor, and finishes with `write-manifest.sh`.
