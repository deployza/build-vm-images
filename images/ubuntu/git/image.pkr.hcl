# git flavor: basics + Gitea (self-hosted Git service + web UI, as systemd).
# Family: git.
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

# GCP target project and zone. Shared across all flavors; defaults baked in here
# (previously in images/ubuntu/variables.pkr.hcl). Override with -var as needed.
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
# baking a placeholder (e.g. version "1-0-0" or git "unknown").
variable "image_version" {
  type    = string
  default = null
}

variable "git_sha" {
  type    = string
  default = null
}

# Tool versions are read from scripts/ubuntu/versions.env — the same single
# source the installer uses — so the label can never drift from what is actually
# installed. Packer's file() refuses to read outside path.root (it strips leading
# ".." segments), so a path.root-relative traversal collapses and fails. The path
# is instead relative to packer's working directory, which is the repo root
# (/workspace) — the same assumption the `source = "scripts/ubuntu/"` file
# provisioner below already makes, and how every cloudbuild.yaml invokes it.
locals {
  versions      = file("scripts/ubuntu/versions.env")
  gitea_version = regex("(?m)^GITEA_VERSION=(\\S+)", local.versions)[0]
}

source "googlecompute" "git" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = var.source_image_project_id
  ssh_username            = "packer"
  image_name              = "git-v${var.image_version}"
  image_family            = "git"
  image_description       = "${var.source_image_family} + Gitea ${local.gitea_version} (systemd). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor = "git"
    gitea  = replace(local.gitea_version, ".", "-")
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.git"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  provisioner "file" {
    source      = "scripts/ubuntu/"
    destination = "/tmp/scripts/"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "IMAGE_FLAVOR=git",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-gitea.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
