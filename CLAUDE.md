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
[`images/common/install/`](images/common/install/)**, which live in this repo.
These are self-contained — there is no build-time dependency on a sibling repo.

> **Self-contained installers.** The installers (`install-basics.sh`,
> `install-java.sh`, `install-tomcat.sh`, `install-mysql.sh`, `write-manifest.sh`,
> `versions.env`, `setenv.sh`, `tomcat.service`) live in `images/common/install/`.
> They are owned by this repo. (Maven is intentionally **not** installed into the
> VM images — WARs are built by the docker `maven` image at build time.)
> The `docker/` repo (`build-docker`) maintains its **own** equivalent install
> steps inline in its Dockerfiles — the two are deliberately **independent copies,
> not a shared source**. Do not reintroduce a cross-repo "single source" coupling;
> if a version needs to change in both, change both.

> **Current state.** Four flavors are implemented under `images/<flavor>/`, each
> with a `<flavor>-image.pkr.hcl` + `<flavor>-image-cloudbuild.yaml` + `README.md`:
> `java`, `tomcat`, `mysql`, `tomcat-mysql`. Shared installers and pinned versions
> live in `images/common/`.

## Conventions

- One `<name>-image.pkr.hcl` + `<name>-image-cloudbuild.yaml` per image.
- Use `image_family` so consumers track the latest non-deprecated image.
- Cloud Build SA needs `roles/compute.instanceAdmin.v1` +
  `roles/iam.serviceAccountUser` (Packer creates a temp VM); enable
  `compute.googleapis.com`.
- See `build-design.md` §3 in `build-docs` for the full template and rationale.

## Recommended repository layout

To support multiple VM images with shared provisioning, organize the repo into image-specific folders plus common shared definitions.

Example structure:

```
build-vm-images/
  images/
    common/
      install/                # toolchain installers, owned by this repo
        install-basics.sh
        install-java.sh
        install-tomcat.sh
        install-mysql.sh
        write-manifest.sh     # bakes /etc/image-manifest.txt (build-design.md §9)
        versions.env          # single source for pinned versions
        setenv.sh
        tomcat.service
      variables.pkr.hcl       # canonical defaults (per-flavor templates copy these)
    java/
      java-image.pkr.hcl
      java-image-cloudbuild.yaml
      README.md
    tomcat/
      tomcat-image.pkr.hcl
      tomcat-image-cloudbuild.yaml
      README.md
    mysql/
      mysql-image.pkr.hcl
      mysql-image-cloudbuild.yaml
      README.md
    tomcat-mysql/
      tomcat-mysql-image.pkr.hcl
      tomcat-mysql-image-cloudbuild.yaml
      README.md
```

### Why this layout

- `images/<flavor>/` keeps each image definition isolated and easy to maintain.
- `images/common/` contains the shared `install/` provisioning scripts, shared
  Packer variables, reusable build logic, and base Cloud Build configuration.
- Each flavor's Packer template references the same `images/common/install/`
  scripts via a relative path within this repo.

### Image composition guidance

Each `images/<flavor>/` folder produces one image **family**. The flavor folder
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
