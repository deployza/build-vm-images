# `tomcat` image

GCE image family **`tomcat`**: Ubuntu + basic tools + gcloud CLI + JDK + Apache
Tomcat running as a `systemd` service. This is the original/primary flavor.

Maven is **not** installed — WARs are built by the docker `maven` image at build
time and pulled onto the VM at boot (see `build-design.md`).

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-java.sh` — JDK under `/opt/java`
- `install-tomcat.sh` — Tomcat at `/opt/tomcat`, `tomcat` systemd service

Versions are pinned in [`../../scripts/versions.env`](../../scripts/versions.env).

## Build

```bash
gcloud builds submit --config cloudbuild.yaml .
```

Image names are unique per project, so re-running with an unchanged
`_IMAGE_VERSION` **fails** at the image-create step (GCE `409 alreadyExists`) —
GCE never overwrites an existing image. Bump `_IMAGE_VERSION` to publish a new
one. (The `tomcat` family pointer just moves to the newest image.)

Consumers launch with `--image-family=tomcat --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                                   |
| ------- | ---------- | ---------------------------------------- |
| 1-0-0   | 2026-06-22 | Initial image. JDK 24, Tomcat 11.0.8.    |
