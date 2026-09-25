# `nginx-python` image

GCE image family **`nginx-python`**: Ubuntu + basic tools + gcloud CLI + nginx
(systemd, serving static content) + CPython **3.14.7** under `/opt/python`. No
Java, no Tomcat, no MySQL — the web front door for a VM that runs a **Python**
application behind nginx.

> **What actually distinguishes this flavor is not Python.** The pinned
> CPython is installed by `install-basics.sh` on **every** flavor in the repo,
> so `tomcat` and `mysql` have 3.14.7 too. Precisely, this is the
> [`nginx`](../nginx/nginx.md) flavor **without `install-mkdocs.sh`** — that
> venv is a `www-apidocs` build dependency and dead weight on a box running an
> ordinary Python app. The name is kept because it says what the box is for,
> and this is the one flavor that carries the Python version as an image
> label. If the MkDocs venv does not bother you, the `nginx` family already
> serves the same purpose.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI + Python (distro `python3`/venv/pip, and the pinned
  CPython from `install-python.sh` at `/opt/python/latest` — every flavor
  gets it; see [`../../../CLAUDE.md`](../../../CLAUDE.md))
- `install-nginx-static.sh` — nginx from the official nginx.org stable apt
  repo, `nginx` systemd service, static config at
  `/etc/nginx/conf.d/static.conf`, empty `/etc/nginx/app.d/` routing seam

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env)
(`NGINX_VERSION`, `PYTHON_VERSION`).

## What is NOT baked

**No application server and no routing.** The image ships an interpreter and an
nginx that answers `/nginx-health` and 404s everything else — exactly the
mechanism/policy split the rest of the fleet follows (MySQL is baked without
credentials; `install-nginx-static.sh` is baked without `location` blocks).

The per-app deploy script (`build-ops/vm/<app>.sh`) owns all three
pieces that make it serve something:

1. a venv of its own, `/opt/python/latest/bin/python3 -m venv /opt/<app>/venv`,
   then its own `requirements.txt`;
2. its WSGI/ASGI server (gunicorn, uvicorn, …) and the systemd unit that runs
   it, bound to loopback;
3. `/etc/nginx/app.d/<app>.conf` with the `proxy_pass` to that port, then
   `nginx -t && systemctl reload nginx`.

There is deliberately no baked `gunicorn`, no `python-app.service` and no
`proxy-to-python.conf`. The Tomcat flavors bake an upstream because Tomcat *is*
the runtime and there is one right answer; Python has no such default, and a
baked gunicorn unit would be dead weight for a uvicorn or a Django-with-daphne
app. See `/etc/nginx/app.d/README` on a running VM for the routing contract.

## The Python runtime

Everything in this section is **fleet-wide**, not specific to this flavor — it
is `install-basics.sh`'s behaviour, documented here because this is the flavor
named after it.

**Built from source, not from apt.** Ubuntu 24.04 ships Python 3.12 and has no
3.14 package; the usual backport (the deadsnakes PPA) publishes "latest
3.14.x", so an apt-based image would quietly acquire a different interpreter on
each rebuild — the opposite of a pinned image. python.org's source tarball is
the only official artifact for a named patch release, so `PYTHON_VERSION` is a
full `X.Y.Z` and `install-python.sh` compiles it, verifying at bake time that
what it built reports exactly that version.

`install-basics.sh` also installs the distro's `python3-venv` and
`python3-pip`, so the system interpreter is usable for scripting on its own.

**The system Python is untouched.** `/usr/bin/python3` remains Ubuntu's 3.12
and still serves apt, unattended-upgrades and the gcloud CLI. `install-python.sh`
therefore:

- installs into the private prefix `/opt/python/3.14.7` (`/opt/python/latest`),
  the same `/opt/<tool>/latest` layout as `/opt/java/latest`;
- adds only **versioned** names to `/usr/local/bin` — `python3.14`, `pip3.14`.
  A bare `python3` there would sit ahead of `/usr/bin` for **every** root
  process, which is the classic way to leave a box unable to run apt;
- puts the unversioned names on `PATH` via `/etc/profile.d/python.sh`, which
  affects login and interactive shells only.

So on a running VM:

| invocation | interpreter |
|---|---|
| `python3` in an SSH session | 3.14.7 (`/opt/python/latest`) |
| `python3.14` anywhere, incl. systemd units and cron | 3.14.7 |
| `/usr/bin/python3`, apt/gcloud shebangs | Ubuntu's 3.12 |

A systemd unit gets no `/etc/profile.d`, so a unit that wants this interpreter
must name it: `python3.14`, or its venv's own `bin/python`.

`pip install` works directly against `/opt/python/latest` — PEP 668 applies to
externally-managed distro interpreters, and this one is ours. Applications
should still build a venv from it anyway, the way `install-mkdocs.sh` and
`install-mcp.sh` do, so one app's dependencies cannot break another's.

`install-python.sh` also asserts at bake time that `ssl`, `sqlite3`, `lzma`,
`bz2`, `zlib`, `ctypes`, `readline`, `uuid` and `decimal` all import. CPython's
`configure` does not fail when a `-dev` header is missing — it silently omits
the module — so without that check a missing `libssl-dev` would ship an
interpreter that cannot make an HTTPS request, and nobody would find out until
an app failed on a live VM.

## Build time and bake machine

**Every** flavor compiles CPython now, so all nine carry the same three
overrides — they are not specific to this one:

- `machine_type = "e2-standard-8"` in `image.pkr.hcl`. A PGO + LTO CPython
  build is almost entirely parallel `make`, so bake time is set by the bake
  VM's core count; on googlecompute's `e2-standard-2` default it runs well over
  half an hour. The VM exists only for the bake.
- `disk_size = 20`. The default 10GB holds the base image, `build-essential`
  and a full CPython source tree with its object files at once — not
  comfortably.
- `timeout: 3600s` in `cloudbuild.yaml`. Cloud Build's default is **10
  minutes**, which this build cannot meet. A timeout kills the build mid-bake
  and leaves the temporary Packer VM behind, so the value is deliberately
  generous rather than tight.

PGO/LTO is kept despite the cost: it is paid once per image and recovered on
every VM the image boots. **A new flavor must copy all three settings** or its
first bake dies on the Cloud Build clock, in a way that looks nothing like a
Python problem.

If fleet-wide bake time becomes painful, the escape hatch is to compile 3.14.z
once, publish the result to `${FILES_BASE_URL}/installables/` the way the JDK
tarball is shipped, and have `install-python.sh` untar it — seconds per bake,
at the price of a manual build-and-upload step on every Python bump.

## Build

Triggered from Cloud Build like the other flavors. A hand-run submit **must**
pass `--service-account` (see [`../../../CLAUDE.md`](../../../CLAUDE.md) →
Conventions):

```bash
gcloud builds submit \
  --config images/ubuntu/nginx-python/cloudbuild.yaml \
  --service-account=projects/dz-builds/serviceAccounts/build-service-account@dz-builds.iam.gserviceaccount.com \
  --project=dz-builds \
  .
```

Bump `_IMAGE_VERSION` in `cloudbuild.yaml` to publish: image **names**
(`nginx-python-<version>`) are unique per project, so rebuilding an existing
version hard-fails at image-create with a GCE `409 alreadyExists` rather than
overwriting. The family pointer advances on its own.

## Verify a booted VM

```bash
cat /etc/image-manifest.txt          # both interpreters are recorded
python3 --version                    # 3.14.7
python3 -c 'import ssl; print(ssl.OPENSSL_VERSION)'
/usr/bin/python3 --version           # Ubuntu's 3.12, still there
systemctl status nginx
curl -s localhost/nginx-health       # ok
```
