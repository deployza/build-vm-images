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
`*-cloudbuild.yaml` that bake bootable **GCE images** (Ubuntu + JDK +
Tomcat-as-systemd) and store them as image families (e.g. `tomcat`). This is the
VM-image equivalent of the `docker/` repo (which builds container images).

Packer **provisions the image by running the installers from
`build-vm-scripts/install`** — so this repo expects `build-vm-scripts` cloned as
a sibling. The image and the `docker/` images install the same toolchain from
that one source.

## Conventions

- One `<name>-image.pkr.hcl` + `<name>-image-cloudbuild.yaml` per image.
- Use `image_family` so consumers track the latest non-deprecated image.
- Cloud Build SA needs `roles/compute.instanceAdmin.v1` +
  `roles/iam.serviceAccountUser` (Packer creates a temp VM); enable
  `compute.googleapis.com`.
- See `build-design.md` §3 in `build-docs` for the full template and rationale.
