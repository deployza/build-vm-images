# mcp flavor: basics + the runtime of the code knowledge-graph MCP server — a
# Python venv holding graphify (every tree-sitter grammar) and fastmcp.
# Family: dz-mcp.
#
# The first flavor with no Java and no Tomcat. It bakes NO application: the
# units, helpers, gateway and mcp.env are pushed by build-ops (vm/mcp-vm/).
# See mcp.md.
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
# the installer uses — so the label can never drift from what is installed.
# Packer's file() can't read it directly: file() resolves relative to path.root
# (the template dir) and strips any ".." that would climb above it, so a sibling
# like scripts/ubuntu/ is unreachable. Instead cloudbuild.yaml sources
# versions.env and passes this as -var.
variable "graphify_version" {
  type    = string
  default = null
}

# FastMCP, the OAuth gateway in front of graphify. Labelled separately from
# graphify_version because it is a second, independent upstream that sits in the
# AUTHENTICATION path — when a login stops working, the first question is which of
# the two moved.
variable "fastmcp_version" {
  type    = string
  default = null
}

source "googlecompute" "mcp" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]
  ssh_username            = "packer"

  # disk_size is also the resulting image's size, so a VM booting it needs a
  # boot disk of at least 10GB. The bake VM keeps googlecompute's default
  # machine type (e2-standard-2): no step in the bake is CPU-bound.
  disk_size = 10

  image_name              = "dz-mcp-${var.image_version}"
  image_family            = "dz-mcp"
  image_description       = "${var.source_image_family} + graphify ${var.graphify_version} + fastmcp ${var.fastmcp_version} venv (MCP server runtime; the app is pushed by build-ops). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor   = "mcp"
    graphify = replace(var.graphify_version, ".", "-")
    fastmcp  = replace(var.fastmcp_version, ".", "-")
    built    = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.mcp"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  # Recursive: this also carries the per-component subdirectories of
  # scripts/ubuntu/ (otelcol/, cloud-sql-proxy/, ... -- each holding an
  # installer alongside the units and config files it installs) to the matching
  # subdirectory of /tmp/scripts/.
  provisioner "file" {
    source      = "scripts/ubuntu/"
    destination = "/tmp/scripts/"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "IMAGE_FLAVOR=mcp",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-gcloud.sh",
      "bash /tmp/scripts/install-mcp.sh",
      "bash /tmp/scripts/otelcol/install-otel.sh",
      "bash /tmp/scripts/cloud-sql-proxy/install-cloud-sql-proxy.sh",
      "bash /tmp/scripts/logs/logs-system.sh",
      "bash /tmp/scripts/logs/logs-disk-tools.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
