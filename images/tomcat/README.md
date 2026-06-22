# `tomcat` image

GCE image family **`tomcat`**: Ubuntu + basic tools + gcloud CLI + JDK + Apache
Tomcat running as a `systemd` service. This is the original/primary flavor.

Maven is **not** installed — WARs are built by the docker `maven` image at build
time and pulled onto the VM at boot (see `build-design.md`).

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-java.sh` — JDK under `/opt/java`
- `install-tomcat.sh` — Tomcat at `/opt/tomcat`, `tomcat` systemd service

Versions are pinned in [`../common/install/versions.env`](../common/install/versions.env).

## Build

```bash
gcloud builds submit --config tomcat-image-cloudbuild.yaml .
```

Consumers launch with `--image-family=tomcat --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                                   |
| ------- | ---------- | ---------------------------------------- |
| 1-0-0   | 2026-06-22 | Initial image. JDK 24, Tomcat 11.0.8.    |
