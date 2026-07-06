# `mysql` image

GCE image family **`mysql`**: Ubuntu + basic tools + gcloud CLI + MySQL Server
(distro `mysql-server` + `mysql-client`, 8.0.x) running as a `systemd` service.

The server is baked with no root password and bound to `127.0.0.1`. The
boot-time deploy step is responsible for setting the root password / creating
app databases and opening a remote bind if needed — secrets never live in the
image.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-mysql.sh` — `mysql-server` + `mysql-client` from Ubuntu's own apt
  repo (distro 8.0.x, not `dev.mysql.com`), `mysql` systemd service

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit --config images/ubuntu/mysql/cloudbuild.yaml .
```

Image names are unique per project, so re-running with an unchanged
`_IMAGE_VERSION` **fails** at the image-create step (GCE `409 alreadyExists`) —
GCE never overwrites an existing image. Bump `_IMAGE_VERSION` to publish a new
one. (The `mysql` family pointer just moves to the newest image.)

Consumers launch with `--image-family=mysql --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                                                        |
| ------- | ---------- | ------------------------------------------------------------- |
| 1-0-1   | 2026-07-06 | Switch to Ubuntu distro `mysql-server`+`mysql-client` (8.0). |
| 1-0-0   | 2026-06-22 | Initial image. MySQL 8.4.                                     |
