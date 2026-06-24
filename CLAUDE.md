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
> `install-java.sh`, `install-tomcat.sh`, `install-mysql.sh`, `write-manifest.sh`,
> `versions.env`, `setenv.sh`, `tomcat.service`) live under `scripts/<os>/`.
> They are owned by this repo. (Maven is intentionally **not** installed into the
> VM images — WARs are built by the docker `maven` image at build time.)
> The `docker/` repo (`build-docker`) maintains its **own** equivalent install
> steps inline in its Dockerfiles — the two are deliberately **independent copies,
> not a shared source**. Do not reintroduce a cross-repo "single source" coupling;
> if a version needs to change in both, change both.

> **Current state.** Five flavors are implemented under `images/ubuntu/<flavor>/`,
> each with an `image.pkr.hcl` + `cloudbuild.yaml` + `README.md`:
> `java`, `tomcat`, `mysql`, `tomcat-mysql`, `git` (Gitea). Shared installers and
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
- Image **names** (`<flavor>-v<version>`) are unique per project: rebuilding an
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
      install-mysql.sh
      write-manifest.sh       # bakes /etc/image-manifest.txt (build-design.md §9)
      versions.env            # single source for pinned versions
      setenv.sh
      tomcat.service
  images/
    ubuntu/
      java/
        image.pkr.hcl
        cloudbuild.yaml
        README.md
      tomcat/
        image.pkr.hcl
        cloudbuild.yaml
        README.md
      mysql/
        image.pkr.hcl
        cloudbuild.yaml
        README.md
      tomcat-mysql/
        image.pkr.hcl
        cloudbuild.yaml
        README.md
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

Naming convention: a flavor named after a tool includes that tool plus its
prerequisites (so `tomcat` ⇒ Java, no redundant `java-` prefix). Combined
flavors join the tool names with `-` (`tomcat-mysql`). The image **family** is
the bare flavor name (e.g. `tomcat`); the tool version lives in the `image_name`
(`tomcat-v1-0-0`) and in image **labels** — never in the family — so consumers
track `--image-family=tomcat` without ever chasing minor-version bumps.

Each image runs `install-basics.sh` first, then the additional installer scripts
required by that flavor, and finishes with `write-manifest.sh`.
