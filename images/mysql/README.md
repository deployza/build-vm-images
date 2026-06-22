# `mysql` image

GCE image family **`mysql`**: Ubuntu + basic tools + gcloud CLI + MySQL
Community Server running as a `systemd` service.

The server is baked with no root password and bound to `127.0.0.1`. The
boot-time deploy step is responsible for setting the root password / creating
app databases and opening a remote bind if needed — secrets never live in the
image.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-mysql.sh` — MySQL from the official `dev.mysql.com` apt repo, `mysql`
  systemd service

Versions are pinned in [`../common/install/versions.env`](../common/install/versions.env).

## Build

```bash
gcloud builds submit --config mysql-image-cloudbuild.yaml .
```

Consumers launch with `--image-family=mysql --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                          |
| ------- | ---------- | ------------------------------- |
| 1-0-0   | 2026-06-22 | Initial image. MySQL 8.4.       |
