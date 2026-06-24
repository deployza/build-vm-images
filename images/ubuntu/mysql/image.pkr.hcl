# mysql flavor: basics + MySQL daemon (as systemd). Family: mysql.
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
# source the installers use — so labels/description can never drift from what is
# actually installed. path.root is this template's directory, so the relative
# path is stable whether packer runs from /workspace or this folder.
locals {
  versions      = file("${path.root}/../../../scripts/ubuntu/versions.env")
  mysql_version = regex("(?m)^MYSQL_VERSION=(\\S+)", local.versions)[0]
}

source "googlecompute" "mysql" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = var.source_image_project_id
  ssh_username            = "packer"
  image_name              = "mysql-v${var.image_version}"
  image_family            = "mysql"
  image_description       = "${var.source_image_family} + MySQL ${local.mysql_version} daemon (systemd). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor = "mysql"
    mysql  = replace(local.mysql_version, ".", "-")
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.mysql"]

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
      "IMAGE_FLAVOR=mysql",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-mysql.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
