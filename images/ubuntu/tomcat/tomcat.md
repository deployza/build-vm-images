# `tomcat` image

GCE image family **`tomcat`**: Ubuntu + basic tools + gcloud CLI + JDK + Apache
Tomcat running as a `systemd` service. This is the original/primary flavor.

Maven is **not** installed — WARs are built by the docker `maven` image at build
time and pulled onto the VM at boot (see `build-design.md`).

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-java.sh` — JDK under `/opt/java`
- `install-tomcat.sh` — `tomcat` user (home `/home/tomcat`), Tomcat at
  `/home/tomcat/instance`, `tomcat` systemd service

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## Layout

The image creates a `tomcat` service user with a standard home directory and
installs everything under it:

| Purpose         | Location                   |
| --------------- | -------------------------- |
| Home            | `/home/tomcat`             |
| Tomcat install  | `/home/tomcat/instance` (`CATALINA_HOME`) |
| App config      | `/home/tomcat/apps/conf`   |
| App logs        | `/home/tomcat/apps/logs`   |

Tomcat installs into the fixed `instance` dir (no version in the path), so a
Tomcat version bump only changes which archive `versions.env` points at — no
path in the service, `setenv.sh`, or the deploy script changes.

## Deploying WARs

Drop WAR files into Tomcat's default appBase, **`/home/tomcat/instance/webapps/`**
(`autoDeploy` picks them up). `app.war` → context `/app`; `ROOT.war` → root `/`.

App config and logs live under the tomcat user's home (outside the install tree)
and are passed to Tomcat both as **environment variables** and as **JVM `-D`
properties**:

| Purpose | Location     | Env var      | `-D` property |
| ------- | ------------ | ------------ | ------------- |
| Config  | `/home/tomcat/apps/conf/` | `CONFIG_DIR` | `config.dir`  |
| Logs    | `/home/tomcat/apps/logs/` | `LOGS_DIR` | `logs.dir`   |

The app reads whichever it prefers — `System.getenv("CONFIG_DIR")` or
`System.getProperty("config.dir")` — and resolves its properties/log paths
against that (never the JVM working directory). Both roots are created by the
image, owned `tomcat:tomcat`. Logs under `/home/tomcat/apps/logs/*.log` are
rotated by `/etc/logrotate.d/tomcat-apps`.

Tomcat's per-request **access log is disabled**: `install-tomcat.sh` comments the
`AccessLogValve` out of `conf/server.xml`, so no `localhost_access_log.*.txt`
files are written under `/home/tomcat/instance/logs` (matching the
nginx/apisix/tomcat docker images, which also turn the access log off). This
applies to the `tomcat-mysql` flavor too, since it runs the same installer.

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
| 1-0-1   | 2026-07-07 | Move Tomcat under the `tomcat` user home: install at `/home/tomcat/instance`, app config `/home/tomcat/apps/conf`, app logs `/home/tomcat/apps/logs`. |
| 1-0-0   | 2026-06-22 | Initial image. JDK 24, Tomcat 11.0.8.    |
