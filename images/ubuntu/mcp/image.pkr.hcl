# mcp flavor: basics + the code knowledge-graph MCP server (graphify), as systemd.
# Family: mcp.
#
# The first flavor with no Java and no Tomcat. It bakes a Python venv holding
# graphify and every tree-sitter grammar, plus the server and refresh units.
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

  # BAKE VM SIZE AND DISK ARE SET BY install-basics.sh, WHICH COMPILES CPYTHON
  # (PGO+LTO) ON EVERY FLAVOR -- see that script's header. Bake time there is
  # almost entirely parallel `make`, so it tracks the bake VM's core count:
  # on googlecompute's e2-standard-2 default it runs well over half an hour,
  # on 8 vCPUs it is minutes. The disk must hold the base image,
  # build-essential and a full CPython source tree with its object files at
  # once, which 10GB does not do comfortably. This VM exists only for the bake.
  # Keep these in step with cloudbuild.yaml's `timeout`, not instead of it.
  machine_type = "e2-standard-8"
  disk_size    = 20

  image_name              = "mcp-${var.image_version}"
  image_family            = "mcp"
  image_description       = "${var.source_image_family} + graphify ${var.graphify_version} MCP server behind a fastmcp ${var.fastmcp_version} OAuth gateway (systemd). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
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

  # Recursive: this also carries scripts/ubuntu/mcp/ (the units, helper
  # binaries and mcp.env) to /tmp/scripts/mcp/.
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
      "bash /tmp/scripts/mcp/install-mcp.sh",
      "bash /tmp/scripts/install-otel.sh",
      "bash /tmp/scripts/install-cloud-sql-proxy.sh",
      "bash /tmp/scripts/install-python.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
