# `tomcat-nginx-mysql` image

GCE image family **`tomcat-nginx-mysql`**: Ubuntu + basic tools + gcloud CLI +
JDK + Apache Tomcat (systemd) + nginx (systemd, reverse proxy to Tomcat) +
MySQL Server (distro `mysql-server` + `mysql-client`, 8.0.x, systemd). Web front
door, app server and database co-located on one VM.

This is the [`tomcat-mysql`](../tomcat-mysql/tomcat-mysql.md) flavor with an HTTP
front end added. nginx owns port 80 and proxies to Tomcat on `127.0.0.1:8080`, so
the VM can terminate client traffic without exposing the app connector directly.

Maven is **not** installed (WARs are built at build time, pulled at boot).
MySQL is baked with no root password, bound to `127.0.0.1`; the boot-time
deploy step provisions credentials and databases.

## Why nginx rather than Apache HTTPD

The sibling container repo (`build-docker/nginx/`) already standardized on nginx,
so this keeps one web server, one config dialect and one set of tuning knowledge
across the VM and container halves of the platform. The job here is reverse
proxying Tomcat and serving static assets, which is nginx's core competence;
HTTPD's historical advantages (`mod_php`, `.htaccess`, its module ecosystem) do
not apply when the app tier is Tomcat. nginx's event model also holds less memory
per connection, which matters on a co-located VM where Tomcat's heap and MySQL's
buffer pool already compete for RAM.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-java.sh` — JDK under `/opt/java`
- `install-tomcat.sh` — `tomcat` user (home `/home/tomcat`), Tomcat at
  `/home/tomcat/instance`, `tomcat` systemd service
- `install-nginx.sh` — nginx from the official nginx.org stable apt repo,
  `nginx` systemd service, reverse-proxy config at
  `/etc/nginx/conf.d/tomcat.conf`
- `install-mysql.sh` — `mysql-server` + `mysql-client` (Ubuntu distro 8.0.x),
  `mysql` systemd service

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## nginx configuration

Baked at `/etc/nginx/conf.d/tomcat.conf`. The package's stock
`conf.d/default.conf` (the nginx welcome page) is **removed** by the installer —
leaving it would collide with this block's `default_server` on `:80`.

- `listen 80 default_server` → `proxy_pass http://127.0.0.1:8080` via a keepalive
  upstream.
- Sets `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`,
  `X-Forwarded-Host`, `X-Forwarded-Port` so the app can reconstruct the original
  request. Without these Tomcat sees every client as `127.0.0.1` over plain HTTP.
- `client_max_body_size 0` — the proxy does not impose its own upload limit
  (nginx defaults to 1m); the app tier decides.
- `GET /nginx-health` returns `200 ok` **without** touching Tomcat, so it reports
  nginx liveness, not application liveness.

To serve static content or add TLS, drop another file into `/etc/nginx/conf.d/`
at deploy time or bake a new image version; do not edit `tomcat.conf` in place on
a running VM (the next image rebuild overwrites it).

For TLS the VM needs a tcp:443 firewall rule and a certificate supplied at deploy
time — neither is baked into the image.

## Logging

The nginx access log stays **on** and is rotated by
`/etc/logrotate.d/nginx-custom` (daily, 14 days, compressed, `USR1` to reopen
handles) — matching the retention the Tomcat and MySQL installers use.

This is deliberately the **opposite** of the `build-docker/nginx` image, which
disables the access log because containers get no in-image logrotate. A VM owns
its own disk and runs logrotate, so it can afford to keep the log. See
[`../../../CLAUDE.md`](../../../CLAUDE.md) → "Log & disk hygiene (VM-only)".

## Ports

| Port | Service | Exposure |
| ---- | ------- | -------- |
| 80   | nginx   | The intended entry point — needs a firewall rule. |
| 8080 | Tomcat  | Bound by Tomcat's default connector. Do **not** open it in the firewall; nginx reaches it over loopback. |
| 3306 | MySQL   | Bound to `127.0.0.1` only. |

Tomcat's connector is left on its stock configuration, so `:8080` is reachable
from the VM itself. The firewall is what keeps it private — grant tcp:80 (and
tcp:443 once TLS is configured) and nothing else.

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit --config images/ubuntu/tomcat-nginx-mysql/cloudbuild.yaml .
```

Image names are unique per project, so re-running with an unchanged
`_IMAGE_VERSION` **fails** at the image-create step (GCE `409 alreadyExists`) —
GCE never overwrites an existing image. Bump `_IMAGE_VERSION` to publish a new
one. (The `tomcat-nginx-mysql` family pointer just moves to the newest image.)

Consumers launch with `--image-family=tomcat-nginx-mysql --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                                                         |
| ------- | ---------- | -------------------------------------------------------------- |
| 1-0     | 2026-07-28 | Initial image. `tomcat-mysql` + nginx reverse proxy on :80.    |
