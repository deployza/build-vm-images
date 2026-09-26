# `tomcat-mysql` image

GCE image family **`dz-tomcat-mysql`**: Ubuntu + basic tools + gcloud CLI + JDK +
Apache Tomcat (systemd) + MySQL Server (distro `mysql-server` + `mysql-client`,
8.0.x, systemd). App server and
database co-located on one VM — convenient for single-node deployments.

Maven is **not** installed (WARs are built at build time, pulled at boot).
MySQL is baked with no root password, bound to `127.0.0.1`; the boot-time
deploy step provisions credentials and databases.

## Contents

- `install-basics.sh`, `install-gcloud.sh`, `install-python.sh` — the baseline
  every flavor gets: apt basics (distro `python3`/venv/pip included), the gcloud
  CLI, and the pinned CPython at `/opt/python/latest`; see
  [`../../../CLAUDE.md`](../../../CLAUDE.md)
- `install-java.sh` — JDK under `/opt/java`
- `install-tomcat.sh` — `tomcat` user (home `/home/tomcat`), Tomcat at
  `/home/tomcat/instance`, `tomcat` systemd service
- `install-mysql.sh` — `mysql-server` + `mysql-client` (Ubuntu distro 8.0.x),
  `mysql` systemd service

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit \
  --config images/ubuntu/tomcat-mysql/cloudbuild.yaml \
  --service-account=projects/dz-builds/serviceAccounts/build-service-account@dz-builds.iam.gserviceaccount.com \
  --project=dz-builds \
  .
```

`--service-account` is required: without it the build runs as the Compute
Engine default SA and fails with a 403 on the source tarball. See this repo's
`CLAUDE.md` Conventions section.

Image names are unique per project, so re-running with an unchanged
`_IMAGE_VERSION` **fails** at the image-create step (GCE `409 alreadyExists`) —
GCE never overwrites an existing image. Bump `_IMAGE_VERSION` to publish a new
one. (The `dz-tomcat-mysql` family pointer just moves to the newest image.)

Consumers launch with `--image-family=dz-tomcat-mysql --image-project=dz-builds`.

## Changelog

| Version | Date       | Change                                                         |
| ------- | ---------- | -------------------------------------------------------------- |
| 1-0-2   | 2026-07-07 | Move Tomcat under the `tomcat` user home: install at `/home/tomcat/instance`, app config `/home/tomcat/apps/conf`, app logs `/home/tomcat/apps/logs`. |
| 1-0-1   | 2026-07-06 | Switch to Ubuntu distro `mysql-server`+`mysql-client` (8.0).  |
| 1-0-0   | 2026-06-22 | Initial image. JDK 24, Tomcat 11.0.8, MySQL 8.4.               |
