# nginx-python flavor: basics + nginx (systemd, static) + CPython under
# /opt/python. No Java, no Tomcat, no MySQL, and no MkDocs venv — the `nginx`
# flavor's Python-runtime sibling, for a VM that serves a Python application
# behind nginx rather than a docs bundle.
# Family: nginx-python.
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
# baking a placeholder (e.g. version "1-0-0" or git "unknown").
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
# Packer's file() can't read it directly: file() resolves relative to path.root
# (the template dir) and strips any ".." that would climb above it, so a sibling
# like scripts/ubuntu/ is unreachable. Instead cloudbuild.yaml sources
# versions.env and passes these as -var (the same path image_version/git_sha
# take).
variable "nginx_version" {
  type    = string
  default = null
}

variable "python_version" {
  type    = string
  default = null
}

source "googlecompute" "nginx-python" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]
  ssh_username            = "packer"

  # The one flavor that COMPILES its payload. install-python.sh runs a PGO+LTO
  # CPython build, which is almost entirely parallel `make`, so the bake VM's
  # core count is the whole bake time: on the googlecompute default
  # (e2-standard-2) it runs well over half an hour, on 8 vCPUs it is minutes.
  # This machine exists only for the duration of the bake. Raise
  # cloudbuild.yaml's `timeout` with it, not instead of it.
  machine_type = "e2-standard-8"

  # The default 10GB boot disk holds the base image, the apt build-essential
  # toolchain and a full CPython source tree plus its object files at once.
  disk_size = 20

  image_name        = "nginx-python-${var.image_version}"
  image_family      = "nginx-python"
  image_description = "${var.source_image_family} + nginx ${var.nginx_version} (systemd) + CPython ${var.python_version} (/opt/python/latest). No Java/Tomcat/MySQL. Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor = "nginx-python"
    nginx  = replace(var.nginx_version, ".", "-")
    python = replace(var.python_version, ".", "-")
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.nginx-python"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  provisioner "file" {
    source      = "scripts/ubuntu/"
    destination = "/tmp/scripts/"
  }

  # Same installer set as the `nginx` flavor minus install-mkdocs.sh, plus
  # install-python.sh. install-vm-startup.sh is included for the same reason it
  # is there: this flavor deploys the generic GCS-artifact/APP_NAME+APP_ENV way,
  # and the launcher's own requirements (git + curl, from install-basics.sh)
  # have no Tomcat dependency.
  #
  # nginx is installed BEFORE python only so a failed nginx config fails the
  # bake before the long compile, not after it; the two are independent.
  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "IMAGE_FLAVOR=nginx-python",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-nginx-static.sh",
      "bash /tmp/scripts/install-python.sh",
      "bash /tmp/scripts/install-vm-startup.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
