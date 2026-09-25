# `ops` image

GCE image family **`dz-ops`**. It contains Ubuntu, the basic tools and the gcloud
CLI, plus:

- **Ansible**: a pinned venv, with its commands on PATH.
- **[Semaphore UI](https://semaphoreui.com)**: a web UI and API for running
  Ansible playbooks.
- **[ClickHouse](https://clickhouse.com)**: server and client.
- **[Grafana](https://grafana.com) OSS**: with the
  [ClickHouse datasource plugin](https://grafana.com/grafana/plugins/grafana-clickhouse-datasource/)
  pre-installed.

Each service runs as a `systemd` unit. There is no Java, no Tomcat, and no nginx.

The flavor is named for its purpose, like `git` and `mcp`, rather than by joining
its tool names.

## What a booted VM looks like

| Service | Unit | Port | Baked state |
| --- | --- | --- | --- |
| ClickHouse | `clickhouse-server` | `127.0.0.1:9000` native, `:8123` HTTP | **enabled**, loopback only, empty data dir |
| Grafana | `grafana-server` | `:3000` | installed, **not enabled** |
| Semaphore | `semaphore` | `:3001` | installed, **not enabled**, no config |
| Ansible | (CLI) | n/a | `/opt/ansible/venv`, commands in `/usr/local/bin` |

**Why only ClickHouse is enabled:** whether a service is enabled depends on
whether its baked state is safe to boot into.

- **ClickHouse** runs fine with no configuration. The repo's `config.d` and
  `users.d` files keep it, and its password-less `default` user, on loopback.
  So it is enabled, like MySQL on the `mysql` flavor.
- **Grafana** would boot into `admin/admin` on every interface.
- **Semaphore** exits at once without its config. That config holds three
  secrets, and `access_key_encryption` encrypts every SSH key stored in it.

Both of those stay off until the deploy step supplies their secrets. This is
the same split as otel (safe inert state, so enabled) versus cloud-sql-proxy
(no safe state, so not enabled). Secrets never live in the image.

**Why Semaphore is on :3001:** Grafana and Semaphore both default to `:3000`.
Semaphore moves. The port is set in `semaphore.service` via `SEMAPHORE_PORT`,
and environment variables override `config.json`, so the port is owned by the
unit, not the deploy.

## Contents

| Installer | Installs |
| --- | --- |
| `install-ansible.sh` | `ansible` + `ansible-core` (both pinned) in a venv built from the distro `python3`, plus `sshpass`. |
| `semaphore/install-semaphore.sh` | The `semaphore_community` deb from GitHub, a `semaphore` user with a real home (Ansible writes `~/.ansible` and `~/.ssh`), `/var/lib/semaphore`, the unit, and `/etc/semaphore/config.json.example`. |
| `clickhouse/install-clickhouse.sh` | Pinned `clickhouse-{common-static,server,client}` from packages.clickhouse.com (`lts`), held. Installs `config.d/deployza.xml` and `users.d/deployza.xml`. **Starts the server once** to prove the config loads, checks the running version equals the pin, then wipes `/var/lib/clickhouse` so no two VMs share a server UUID. |
| `install-grafana.sh` | Pinned `grafana` from apt.grafana.com, held, and the pinned ClickHouse plugin. Asserts no `grafana.db` was baked. |

`clickhouse-config.xml` changes only what differs from the package's own config:

- It listens on loopback.
- The logger level goes from `trace` to `information`, with 5 × 100 MB files
  instead of up to 20 GB.
- `max_server_memory_usage_to_ram_ratio` is 0.6, because this box is shared with
  Grafana and Semaphore.
- The system log tables get TTLs. They otherwise grow forever.

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).
Every flavor also carries the baseline: otelcol (inert), cloud-sql-proxy (not
enabled), the pinned CPython, and the log policy.

## Build

Run from the **repo root**. The build context must include `scripts/`:

```bash
gcloud builds submit \
  --config images/ubuntu/ops/cloudbuild.yaml \
  --service-account=projects/dz-builds/serviceAccounts/build-service-account@dz-builds.iam.gserviceaccount.com \
  --project=dz-builds \
  .
```

Bump `_IMAGE_VERSION` to publish a new image. Re-running an existing version
fails with GCE `409 alreadyExists`.

Consumers launch with
`--image-family=dz-ops --image-project=dz-builds`.
Give the VM **at least 8 GB of RAM** (e2-standard-2 or larger): ClickHouse is
capped at 60% of it, and Ansible runs need the rest.

## Turning it on (deploy time)

None of this is in the image. Each installer prints its own version of these
steps at the end of its bake log.

1. **ClickHouse:** put a password for `default` (or named users) in a new file
   under `/etc/clickhouse-server/users.d/`, create the databases, then restart.
2. **Grafana:**
   - Add `GF_SECURITY_ADMIN_PASSWORD=...` to `/etc/default/grafana-server`.
     Grafana reads it only on the first start.
   - Add a datasource provisioning file at
     `/etc/grafana/provisioning/datasources/clickhouse.yaml`, with type
     `grafana-clickhouse-datasource`, server `127.0.0.1`, and port `9000`.
   - Run `systemctl enable --now grafana-server`.
3. **Semaphore:**
   - Write `/etc/semaphore/config.json` from the `.example`, generating each
     secret with `head -c32 /dev/urandom | base64`.
   - Run `sudo -u semaphore semaphore user add --admin ... --config /etc/semaphore/config.json`.
   - Run `systemctl enable --now semaphore`.
4. **Network:** open `:3000` and `:3001` only to the audience that needs them,
   for example IAP or an internal range. Neither service terminates TLS.
5. **otel:** to ship ClickHouse's own logs, the `otelcol` user needs the
   `clickhouse` group. Add it to `OTEL_GROUPS` in the host's
   `build-ops/vm/<vm>/install-otel.sh`. It is a push-time decision, not an
   image one.

## Changelog

| Version | Date       | Change |
| ------- | ---------- | ------ |
| 1-0     | 2026-09-25 | Initial image. Ansible 14.4.0 (core 2.21.4), Semaphore 2.19.12, ClickHouse 26.8.10.6, Grafana 13.2.2, ClickHouse plugin 4.21.3. |
