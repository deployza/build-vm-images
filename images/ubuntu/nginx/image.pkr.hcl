# nginx flavor: basics + nginx (systemd), serving static content. No Java, no
# Tomcat, no MySQL — the lean, Tomcat-free web front door.
# Family: nginx.
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
# baking a placeholder (e.g. version "1-0-0" or git "unknown").
variable "image_version" {
  type    = string
  default = null
}

variable "git_sha" {
  type    = string
  default = null
}

# Tool version comes from scripts/ubuntu/versions.env — the same single source
# the installer uses — so the label can never drift from what is installed.
# Packer's file() can't read it directly: file() resolves relative to path.root
# (the template dir) and strips any ".." that would climb above it, so a sibling
# like scripts/ubuntu/ is unreachable. Instead cloudbuild.yaml sources
# versions.env and passes this as -var (the same path image_version/git_sha
# take).
variable "nginx_version" {
  type    = string
  default = null
}

source "googlecompute" "nginx" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]
  ssh_username            = "packer"
  image_name              = "nginx-${var.image_version}"
  image_family            = "nginx"
  image_description       = "${var.source_image_family} + nginx ${var.nginx_version} (systemd), serving static content. No Java/Tomcat/MySQL. Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor = "nginx"
    nginx  = replace(var.nginx_version, ".", "-")
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.nginx"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  provisioner "file" {
    source      = "scripts/ubuntu/"
    destination = "/tmp/scripts/"
  }

  # install-vm-startup.sh IS included here, unlike mcp: this flavor deploys the
  # generic GCS-WAR/APP_NAME+APP_ENV way (an unpacked site under /var/www/app,
  # the same convention ziniapps-www.sh already uses against
  # install-nginx.sh-baked images), and vm-startup.sh's own requirements
  # (git + curl, both from install-basics.sh) have no Tomcat dependency.
  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "IMAGE_FLAVOR=nginx",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-nginx-static.sh",
      "bash /tmp/scripts/install-vm-startup.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
