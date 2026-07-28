# `tomcat-nginx-mysql` image

GCE image family **`tomcat-nginx-mysql`**: Ubuntu + basic tools + gcloud CLI +
JDK + Apache Tomcat (systemd) + nginx (systemd, reverse proxy to Tomcat) +
MySQL Server (distro `mysql-server` + `mysql-client`, 8.0.x, systemd). Web front
door, app server and database co-located on one VM.

This is the [`tomcat-mysql`](../tomcat-mysql/tomcat-mysql.md) flavor with an HTTP
front end added. nginx owns port 80 and can both serve static content from disk
and proxy to Tomcat on `127.0.0.1:8080`, so the VM terminates client traffic
without exposing the app connector directly. The **routing between those two is
not baked** — see [nginx configuration](#nginx-configuration).

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

**The image bakes the mechanism, not the routing.** Which paths are served as
static files and which proxy to Tomcat is an application decision, so it is
supplied at deploy time by the app install script — the same split MySQL
follows (baked with no credentials; the deploy step provisions them).

Baked at `/etc/nginx/conf.d/tomcat.conf`. The package's stock
`conf.d/default.conf` (the nginx welcome page) is **removed** by the installer —
leaving it would collide with this block's `default_server` on `:80`.

- `listen 80 default_server`, and an `upstream tomcat` pointing at
  `127.0.0.1:8080` with a keepalive pool.
- `client_max_body_size 0` — the proxy imposes no upload limit of its own
  (nginx defaults to 1m); the app tier decides.
- `GET /nginx-health` returns `200 ok` **without** touching Tomcat, so it reports
  nginx liveness, not application liveness.
- `include /etc/nginx/app.d/*.conf;` — the app routing seam, **empty in the baked
  image**.

With `app.d/` empty there is no `location /` at all, so every path except
`/nginx-health` returns **404**. That is intentional: a VM with no app deployed
should not pretend to serve one.

### The app.d contract

The per-app deploy script (`build-app-install/vm/<app>.sh`) writes
`/etc/nginx/app.d/<app>.conf` containing **only location blocks** (no `server{}`
wrapper — they are included inside the baked server block), then runs
`nginx -t && systemctl reload nginx`. The same contract is documented in
`/etc/nginx/app.d/README` on the VM itself.

To proxy a path to Tomcat, include the baked snippet rather than repeating the
forwarding headers:

```nginx
location /api/ {
    include snippets/proxy-to-tomcat.conf;
}
```

`snippets/proxy-to-tomcat.conf` sets `Host`, `X-Real-IP`, `X-Forwarded-For`,
`X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-Port` and the connect/send/
read timeouts. Without those headers Tomcat sees every client as `127.0.0.1` over
plain HTTP.

To serve a static UI bundle (an empty `/var/www/app` is created for this):

```nginx
location / {
    root /var/www/app;
    try_files $uri $uri/ /index.html;   # SPA fallback; drop for plain static
}
```

Do not edit `conf.d/tomcat.conf` in place on a running VM — the next image
rebuild overwrites it. App-specific changes belong in `app.d/`.

For TLS the VM needs a tcp:443 firewall rule and a certificate supplied at deploy
time — neither is baked into the image.

### Client IP and scheme (RemoteIpValve)

Tomcat's `conf/server.xml` is **owned by this repo**
([`scripts/ubuntu/server.xml`](../../../scripts/ubuntu/server.xml)) and installed
verbatim by `install-tomcat.sh`. It ships the `RemoteIpValve` **commented out**;
`install-nginx.sh` enables it by deleting the two
`DEPLOYZA-REMOTEIP-BEGIN`/`END` marker lines that form the comment:

```xml
<Valve className="org.apache.catalina.valves.RemoteIpValve"
       internalProxies="127\.0\.0\.1"
       remoteIpHeader="x-forwarded-for"
       protocolHeader="x-forwarded-proto"
       protocolHeaderHttpsValue="https" />
```

Without it, nginx's loopback hop makes `request.getRemoteAddr()` return
`127.0.0.1` for every client — corrupting audit logs and defeating IP-based rate
limiting or allowlists — and leaves `request.isSecure()` false even once TLS
terminates at nginx, so `secure` cookies get set over what Tomcat thinks is
cleartext.

**Why only the nginx installer enables it:** the valve makes Tomcat *believe*
forwarded headers, which is only safe because nginx is the sole path to the
connector. On the plain `tomcat` and `tomcat-mysql` flavors Tomcat is itself the
front door, so a live valve there would let any client reaching `:8080` forge its
own client IP and claim `X-Forwarded-Proto: https`. Those flavors get the same
`server.xml` with the valve still commented out. The component that creates the
trust relationship configures the trust — and if the proxy is ever removed, the
valve goes with it.

`internalProxies` is deliberately **loopback only**, narrower than Tomcat's
default (all RFC1918), which on a GCP VM would trust the entire VPC rather than
just local nginx.

This is also why **`:8080` must stay closed in the firewall**. Opening it does
not merely bypass nginx — it makes the forwarded headers spoofable and turns the
valve into a liability.

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
