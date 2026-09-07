# `nginx` image

GCE image family **`nginx`**: Ubuntu + basic tools + gcloud CLI + nginx
(systemd), serving static content. No Java, no Tomcat, no MySQL — the lean web
front door for a VM that has no app server of its own (e.g. a marketing site
or docs bundle unpacked to disk, not a Tomcat app).

This is `install-nginx.sh`'s Tomcat-free sibling, not a reuse of it:
`install-nginx.sh`'s header literally says "fronting Tomcat on port 80" and
bakes an `upstream tomcat { ... }` block plus a `proxy-to-tomcat.conf` snippet
— both meaningless dead weight on a box that will never run Tomcat. This
flavor's installer, `install-nginx-static.sh`, mirrors it structurally (same
nginx.org apt repo, same version pin, same access-log-on + logrotate policy,
same empty `/etc/nginx/app.d/` + `/nginx-health` seam and README contract) but
drops the upstream and the proxy snippet, and names its baked conf.d file
`static.conf` rather than `tomcat.conf`. See
[`../../../CLAUDE.md`](../../../CLAUDE.md) — "Self-contained installers" — for
why the docker and VM nginx install steps are deliberately independent copies,
not a shared source.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-nginx-static.sh` — nginx from the official nginx.org stable apt
  repo, `nginx` systemd service, static config at
  `/etc/nginx/conf.d/static.conf`
- `install-vm-startup.sh` — the generic boot launcher (clones
  `build-app-install` and runs `vm/<APP_NAME>.sh` on every boot). Included
  here, unlike the `mcp` flavor: this flavor deploys the standard
  GCS-artifact/`APP_NAME`+`APP_ENV` way, and the launcher's own requirements
  (`git` + `curl`, both from `install-basics.sh`) have no Tomcat dependency.

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## nginx configuration

**The image bakes the mechanism, not the routing.** Which paths are served and
what they serve is an application decision, so it is supplied at deploy time
by the app install script — the same split MySQL follows (baked with no
credentials; the deploy step provisions them).

Baked at `/etc/nginx/conf.d/static.conf`. The package's stock
`conf.d/default.conf` (the nginx welcome page) is **removed** by the installer
— leaving it would collide with this block's `default_server` on `:80`.

- `listen 80 default_server`. No `upstream` block — there is nothing on this
  box to proxy to.
- `client_max_body_size 0` — nginx imposes no upload limit of its own (its
  default is 1m); the app tier decides.
- `GET /nginx-health` returns `200 ok`, so it reports nginx liveness, not
  application liveness.
- `include /etc/nginx/app.d/*.conf;` — the app routing seam, **empty in the
  baked image**.

With `app.d/` empty there is no `location /` at all, so every path except
`/nginx-health` returns **404**. That is intentional: a VM with no app
deployed should not pretend to serve one.

### The app.d / site.d contract

The per-app deploy script (`build-app-install/vm/<app>.sh`) writes
`/etc/nginx/app.d/<app>.conf` containing **only location blocks** (no
`server{}` wrapper — they are included inside the baked server block), then
runs `nginx -t && systemctl reload nginx`. The same contract is documented in
`/etc/nginx/app.d/README` on the VM itself.

To serve a static site or SPA bundle (an empty `/var/www/app` is created for
this):

```nginx
location / {
    root /var/www/app;
    try_files $uri $uri/ =404;   # add "/index.html" instead of "=404" for an SPA
}
```

A per-HOST app that wants the whole server block to itself — e.g. it needs
several `server_name`s or several distinct `location` trees rooted at
different paths on disk, not just one path dropped into the shared default
server — writes a complete `server{}` block to `/etc/nginx/site.d/<site>.conf`
instead, the same `ziniapps-*.sh` pattern already used against
`install-nginx.sh`-baked images. **`/etc/nginx/site.d/` is not baked into this
image** — the deploy script creates the directory and adds the
`include /etc/nginx/site.d/*.conf;` line to `nginx.conf` itself, the first time
it runs. See `build-app-install`'s `ziniapps-go.sh` (`ensure_site_d_include`)
for the mechanics and the reasoning for keeping `site.d` and `app.d` separate.

Do not edit `conf.d/static.conf` in place on a running VM — the next image
rebuild overwrites it. App-specific changes belong in `app.d/` or `site.d/`.

For TLS the VM needs a tcp:443 firewall rule and a certificate supplied at
deploy time — neither is baked into the image.

## Why nginx rather than Apache HTTPD

The sibling container repo (`build-docker/nginx/`) already standardized on
nginx, so this keeps one web server, one config dialect and one set of tuning
knowledge across the VM and container halves of the platform. The workload
here is serving static content, which is nginx's core competence; HTTPD's
historical advantages (`mod_php`, `.htaccess`) do not apply.

## Logging

The nginx access log stays **on** and is rotated by
`/etc/logrotate.d/nginx-custom` (daily, 14 days, compressed, `USR1` to reopen
handles) — matching the retention the other flavors' installers use.

This is deliberately the **opposite** of the `build-docker/nginx` image, which
disables the access log because containers get no in-image logrotate. A VM
owns its own disk and runs logrotate, so it can afford to keep the log. See
[`../../../CLAUDE.md`](../../../CLAUDE.md) → "Log & disk hygiene (VM-only)".

## Ports

| Port | Service | Exposure |
| ---- | ------- | -------- |
| 80   | nginx   | The intended entry point — needs a firewall rule. |

## Build

Run from the **repo root** (the build context must include `scripts/`):

```bash
gcloud builds submit \
  --config images/ubuntu/nginx/cloudbuild.yaml \
  --service-account=projects/tools-tech-463909/serviceAccounts/build-service-account@tools-tech-463909.iam.gserviceaccount.com \
  --project=tools-tech-463909 \
  .
```

> **`--service-account` is required, not optional.** Without it Cloud Build
> runs the build as the **Compute Engine default** service account
> (`<project-number>-compute@developer.gserviceaccount.com`), which fails
> before the build even starts:
>
> ```
> ERROR: could not resolve source: googleapi: Error 403:
> 347018192564-compute@developer.gserviceaccount.com does not have
> storage.objects.get access to the Google Cloud Storage object
> ```
>
> That reads like a bucket problem and is really an identity one — the
> tarball uploaded fine under your own credentials; it is the *build* that
> cannot read it back. `build-service-account` is the identity every trigger
> in `build-terraform/builds/cloudbuild-triggers.tf` already uses, so passing
> it here just makes a hand-run bake match an automated one. See this repo's
> `CLAUDE.md` Conventions section for the full correction.

Image names are unique per project, so re-running with an unchanged
`_IMAGE_VERSION` **fails** at the image-create step (GCE `409 alreadyExists`)
— GCE never overwrites an existing image. Bump `_IMAGE_VERSION` to publish a
new one. (The `nginx` family pointer just moves to the newest image.)

Consumers launch with `--image-family=nginx --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                        |
| ------- | ---------- | ------------------------------ |
| 1-0     | 2026-09-07 | Initial `nginx` image — basics + nginx serving static content, no Java/Tomcat/MySQL. Built for `www.deployza.com` (marketing site + `/docs/`). |
