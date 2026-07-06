# `git` image

GCE image family **`git`**: Ubuntu + basic tools + gcloud CLI + a dedicated
unprivileged `git` user + [Gitea](https://gitea.com) (self-hosted Git service
with a web UI) running as a `systemd` service.

Gitea is baked as a single static binary listening on port **3000**, using
`sqlite3` as the default embedded database backend. The image ships **without**
an `/etc/gitea/app.ini` — the boot-time deploy step writes the config (admin
user, secrets, DB settings) and opens the firewall as needed. Secrets never
live in the image.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI (also installs `git`)
- `install-gitea.sh` — sqlite3, the `git` system user, the pinned Gitea binary,
  the Gitea directory layout, and the `gitea` systemd service
- `gitea.service` — systemd unit for Gitea

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit --config images/ubuntu/git/cloudbuild.yaml .
```

Image names are unique per project, so re-running with an unchanged
`_IMAGE_VERSION` **fails** at the image-create step (GCE `409 alreadyExists`) —
GCE never overwrites an existing image. Bump `_IMAGE_VERSION` to publish a new
one. (The `git` family pointer just moves to the newest image.)

Consumers launch with `--image-family=git --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                          |
| ------- | ---------- | ------------------------------- |
| 1-0-0   | 2026-06-23 | Initial image. Gitea 1.22.0.    |
