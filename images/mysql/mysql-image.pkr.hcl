# mysql flavor: basics + MySQL daemon (as systemd). Family: mysql.
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

source "googlecompute" "mysql" {
  project_id          = var.project
  zone                = var.zone
  source_image_family = var.source_image_family
  ssh_username        = "packer"
  image_name          = "mysql-v${var.image_version}"
  image_family        = "mysql"
  image_labels = {
    flavor = "mysql"
    mysql  = "8-4"
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.mysql"]

  provisioner "file" {
    source      = "../common/install"
    destination = "/tmp"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "FILES_BASE_URL=${var.files_base_url}",
      "IMAGE_FLAVOR=mysql",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/install/install-basics.sh",
      "bash /tmp/install/install-mysql.sh",
      "bash /tmp/install/write-manifest.sh",
    ]
  }
}
