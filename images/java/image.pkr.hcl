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

variable "project" {
  type    = string
  default = "tools-tech-463909"
}

variable "zone" {
  type    = string
  default = "asia-east1-b"
}

variable "source_image_family" {
  type    = string
  default = "ubuntu-2504-amd64"
}

variable "image_version" {
  type    = string
  default = "1-0-0"
}

variable "files_base_url" {
  type    = string
  default = "https://storage.googleapis.com/files.deployza.com"
}

variable "git_sha" {
  type    = string
  default = "unknown"
}

source "googlecompute" "java" {
  project_id          = var.project
  zone                = var.zone
  source_image_family = var.source_image_family
  ssh_username        = "packer"
  image_name          = "java-v${var.image_version}"
  image_family        = "java"
  image_labels = {
    flavor = "java"
    jdk    = "24"
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.java"]

  # Upload the shared installers so each script can source its siblings.
  provisioner "file" {
    source      = "../../scripts"
    destination = "/tmp"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "FILES_BASE_URL=${var.files_base_url}",
      "IMAGE_FLAVOR=java",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-java.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
