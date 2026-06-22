# tomcat-mysql flavor: basics + Java + Tomcat (systemd) + MySQL (systemd).
# Family: tomcat-mysql. App server and database co-located on one VM.
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

source "googlecompute" "tomcat_mysql" {
  project_id          = var.project
  zone                = var.zone
  source_image_family = var.source_image_family
  ssh_username        = "packer"
  image_name          = "tomcat-mysql-v${var.image_version}"
  image_family        = "tomcat-mysql"
  image_labels = {
    flavor = "tomcat-mysql"
    jdk    = "24"
    tomcat = "11-0-8"
    mysql  = "8-4"
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.tomcat_mysql"]

  provisioner "file" {
    source      = "../../scripts"
    destination = "/tmp"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "FILES_BASE_URL=${var.files_base_url}",
      "IMAGE_FLAVOR=tomcat-mysql",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-java.sh",
      "bash /tmp/scripts/install-tomcat.sh",
      "bash /tmp/scripts/install-mysql.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
