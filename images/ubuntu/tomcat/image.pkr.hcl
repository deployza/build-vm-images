# tomcat flavor: basics + Java + Tomcat (as systemd). Family: tomcat.
# (Tomcat implies Java; Maven is intentionally NOT installed — the WAR is built
# by the docker maven image at build time, not on the runtime VM.)
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
  default = "ubuntu-2404-lts-amd64"
}

variable "source_image_project_id" {
  type    = string
  default = "ubuntu-os-cloud"
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

# Dotted form feeds the description; the dash form (label-safe) is derived below.
variable "jdk_version" {
  type    = string
  default = "24"
}

variable "tomcat_version" {
  type    = string
  default = "11.0.8"
}

source "googlecompute" "tomcat" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = var.source_image_project_id
  ssh_username            = "packer"
  image_name              = "tomcat-v${var.image_version}"
  image_family            = "tomcat"
  image_description       = "Ubuntu 24.04 LTS + JDK ${var.jdk_version} + Tomcat ${var.tomcat_version} (systemd). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor = "tomcat"
    jdk    = replace(var.jdk_version, ".", "-")
    tomcat = replace(var.tomcat_version, ".", "-")
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.tomcat"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  provisioner "file" {
    source      = "../../../scripts/ubuntu/"
    destination = "/tmp/scripts/"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "FILES_BASE_URL=${var.files_base_url}",
      "IMAGE_FLAVOR=tomcat",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-java.sh",
      "bash /tmp/scripts/install-tomcat.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
