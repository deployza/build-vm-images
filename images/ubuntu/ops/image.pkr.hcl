# ops flavor: basics + Ansible + Semaphore UI (web UI for Ansible) + ClickHouse
# + Grafana with the ClickHouse datasource plugin.
# Family: dz-ops.
#
# No Java, no Tomcat, no nginx. Named for its purpose, like mcp, rather
# than by joining its four tool names, which made the name too long. See ops.md.
packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = ">= 1.1.0"
    }
  }
}

variable "source_image_family" {
  type    = string
  default = "ubuntu-2404-lts-amd64"
}

variable "source_image_project_id" {
  type    = string
  default = "ubuntu-os-cloud"
}

# GCP target project and zone. Shared across all flavors; defaults baked in here.
# Override with -var as needed.
variable "project" {
  type    = string
  default = "dz-builds"
}

variable "zone" {
  type    = string
  default = "asia-east1-b"
}

# No defaults: Cloud Build (or a local build) MUST pass these. A null default
# makes Packer fail at `validate` if the value is missing, rather than silently
# baking a placeholder.
variable "image_version" {
  type    = string
  default = null
}

variable "git_sha" {
  type    = string
  default = null
}

# Tool versions come from scripts/ubuntu/versions.env — the same single source
# the installers use — so the labels can never drift from what is installed.
# Packer's file() can't read it directly (it resolves relative to path.root and
# strips any ".." above it), so cloudbuild.yaml sources versions.env and passes
# these as -var. null defaults => `validate` fails fast if one wasn't passed.
variable "ansible_version" {
  type    = string
  default = null
}

variable "semaphore_version" {
  type    = string
  default = null
}

variable "clickhouse_version" {
  type    = string
  default = null
}

variable "grafana_version" {
  type    = string
  default = null
}

source "googlecompute" "ops" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]
  ssh_username            = "packer"

  # BAKE VM SIZE AND DISK ARE SET BY install-python.sh, WHICH COMPILES CPYTHON
  # (PGO+LTO) ON EVERY FLAVOR -- see that script's header. On 8 vCPUs it is
  # minutes; on googlecompute's e2-standard-2 default, well over half an hour.
  # The disk must hold the base image, build-essential and a full CPython
  # source tree at once. This VM exists only for the bake. Keep these in step
  # with cloudbuild.yaml's `timeout`, not instead of it.
  #
  # 20GB also has to fit this flavor's own payload, the largest in the repo:
  # clickhouse-common-static alone is several hundred MB unpacked.
  machine_type = "e2-standard-8"
  disk_size    = 20

  image_name        = "dz-ops-${var.image_version}"
  image_family      = "dz-ops"
  image_description = "${var.source_image_family} + Semaphore UI ${var.semaphore_version} + Ansible ${var.ansible_version} + ClickHouse ${var.clickhouse_version} + Grafana ${var.grafana_version} (systemd). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor     = "ops"
    semaphore  = replace(var.semaphore_version, ".", "-")
    ansible    = replace(var.ansible_version, ".", "-")
    clickhouse = replace(var.clickhouse_version, ".", "-")
    grafana    = replace(var.grafana_version, ".", "-")
    built      = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.ops"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  # Recursive: this also carries the per-component subdirectories of
  # scripts/ubuntu/ (semaphore/, clickhouse/, otelcol/, ...) to the matching
  # subdirectory of /tmp/scripts/.
  provisioner "file" {
    source      = "scripts/ubuntu/"
    destination = "/tmp/scripts/"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "IMAGE_FLAVOR=ops",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-gcloud.sh",
      "bash /tmp/scripts/install-ansible.sh",
      "bash /tmp/scripts/semaphore/install-semaphore.sh",
      "bash /tmp/scripts/clickhouse/install-clickhouse.sh",
      "bash /tmp/scripts/install-grafana.sh",
      "bash /tmp/scripts/otelcol/install-otel.sh",
      "bash /tmp/scripts/cloud-sql-proxy/install-cloud-sql-proxy.sh",
      "bash /tmp/scripts/install-python.sh",
      "bash /tmp/scripts/logs/logs-system.sh",
      "bash /tmp/scripts/logs/logs-disk-tools.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
