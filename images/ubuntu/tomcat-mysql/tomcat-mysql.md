# `tomcat-mysql` image

GCE image family **`tomcat-mysql`**: Ubuntu + basic tools + gcloud CLI + JDK +
Apache Tomcat (systemd) + MySQL Server (distro `mysql-server` + `mysql-client`,
8.0.x, systemd). App server and
database co-located on one VM — convenient for single-node deployments.

Maven is **not** installed (WARs are built at build time, pulled at boot).
MySQL is baked with no root password, bound to `127.0.0.1`; the boot-time
deploy step provisions credentials and databases.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-java.sh` — JDK under `/opt/java`
- `install-tomcat.sh` — Tomcat at `/opt/tomcat`, `tomcat` systemd service
- `install-mysql.sh` — `mysql-server` + `mysql-client` (Ubuntu distro 8.0.x),
  `mysql` systemd service

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit --config images/ubuntu/tomcat-mysql/cloudbuild.yaml .
```

Image names are unique per project, so re-running with an unchanged
`_IMAGE_VERSION` **fails** at the image-create step (GCE `409 alreadyExists`) —
GCE never overwrites an existing image. Bump `_IMAGE_VERSION` to publish a new
one. (The `tomcat-mysql` family pointer just moves to the newest image.)

Consumers launch with `--image-family=tomcat-mysql --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                                                         |
| ------- | ---------- | -------------------------------------------------------------- |
| 1-0-1   | 2026-07-06 | Switch to Ubuntu distro `mysql-server`+`mysql-client` (8.0).  |
| 1-0-0   | 2026-06-22 | Initial image. JDK 24, Tomcat 11.0.8, MySQL 8.4.               |
