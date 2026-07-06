# java flavor: basics + Java. Family: java.
#
# The whole scripts/ directory is uploaded first (the install scripts
# source sibling files: versions.env, setenv.sh, tomcat.service), then the
# relevant scripts are run from that uploaded location.
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

# Tool versions come from scripts/ubuntu/versions.env — the same single source the
# installers use — so labels/description can never drift from what is installed.
# Packer's file() can't read it directly: file() resolves relative to path.root
# (the template dir) and strips any ".." that would climb above it, so a sibling
# like scripts/ubuntu/ is unreachable. Instead cloudbuild.yaml sources versions.env
# and passes this as -var (the same path image_version/git_sha take). null default
# => `validate` fails fast if a version wasn't passed, rather than baking a blank.
variable "jdk_version" {
  type    = string
  default = null
}

source "googlecompute" "java" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]
  ssh_username            = "packer"
  image_name              = "java-v${var.image_version}"
  image_family            = "java"
  image_description       = "${var.source_image_family} + JDK ${var.jdk_version}. Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor = "java"
    jdk    = replace(var.jdk_version, ".", "-")
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.java"]

  # Upload the shared installers so each script can source its siblings.
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
      "IMAGE_FLAVOR=java",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-java.sh",
      "bash /tmp/scripts/install-vm-startup.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
