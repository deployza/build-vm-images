# graphify flavor: basics + the graphify MCP server (as systemd).
# Family: graphify.
#
# The first flavor with no Java and no Tomcat. It bakes a Python venv holding
# graphify and every tree-sitter grammar, plus the server and refresh units.
# See graphify.md.
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
  default = "tools-tech-463909"
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

source "googlecompute" "graphify" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]
  ssh_username            = "packer"
  image_name              = "graphify-${var.image_version}"
  image_family            = "graphify"
  image_description       = "${var.source_image_family} + graphify ${var.graphify_version} MCP server (systemd). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor   = "graphify"
    graphify = replace(var.graphify_version, ".", "-")
    built    = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.graphify"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  # Recursive: this also carries scripts/ubuntu/graphify/ (the units, helper
  # binaries and graphify.env) to /tmp/scripts/graphify/.
  provisioner "file" {
    source      = "scripts/ubuntu/"
    destination = "/tmp/scripts/"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "IMAGE_FLAVOR=graphify",
      "GIT_SHA=${var.git_sha}",
    ]
    # install-vm-startup.sh is deliberately ABSENT. That launcher requires
    # APP_NAME and APP_ENV metadata and fails the boot without them, then clones
    # build-app-install and runs vm/<APP_NAME>.sh — a contract built around
    # pulling a WAR and conf/ from GCS and deploying into Tomcat. graphify has no
    # WAR, no conf/ and no Tomcat; its per-instance boot work is a disk mount,
    # which build-terraform does in the VM's own startup script.
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/graphify/install-graphify.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
