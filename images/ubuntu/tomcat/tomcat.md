# `tomcat` image

GCE image family **`tomcat`**: Ubuntu + basic tools + gcloud CLI + JDK + Apache
Tomcat running as a `systemd` service. This is the original/primary flavor.

Maven is **not** installed — WARs are built by the docker `maven` image at build
time and pulled onto the VM at boot (see `build-design.md`).

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-java.sh` — JDK under `/opt/java`
- `install-tomcat.sh` — Tomcat at `/opt/tomcat`, `tomcat` systemd service

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## Deploying WARs

Drop WAR files into Tomcat's default appBase, **`/opt/tomcat/webapps/`**
(`autoDeploy` picks them up). `app.war` → context `/app`; `ROOT.war` → root `/`.

Config and logs are externalized out of the install tree (FHS-correct) and passed
to Tomcat both as **environment variables** and as **JVM `-D` properties**:

| Purpose | Location     | Env var      | `-D` property |
| ------- | ------------ | ------------ | ------------- |
| Config  | `/etc/apps/` | `CONFIG_DIR` | `config.dir`  |
| Logs    | `/var/log/apps/` | `LOGS_DIR` | `logs.dir`   |

The app reads whichever it prefers — `System.getenv("CONFIG_DIR")` or
`System.getProperty("config.dir")` — and resolves its properties/log paths
against that (never the JVM working directory). Both roots are created by the
image, owned `tomcat:tomcat`. Logs under `/var/log/apps/*.log` are rotated by
`/etc/logrotate.d/tomcat-apps`.

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit --config images/ubuntu/tomcat/cloudbuild.yaml .
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
