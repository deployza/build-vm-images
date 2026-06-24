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

variable "mysql_version" {
  type    = string
  default = "8.4"
}

source "googlecompute" "tomcat_mysql" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = var.source_image_project_id
  ssh_username            = "packer"
  image_name              = "tomcat-mysql-v${var.image_version}"
  image_family            = "tomcat-mysql"
  image_description       = "Ubuntu 24.04 LTS + JDK ${var.jdk_version} + Tomcat ${var.tomcat_version} (systemd) + MySQL ${var.mysql_version} (systemd). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor = "tomcat-mysql"
    jdk    = replace(var.jdk_version, ".", "-")
    tomcat = replace(var.tomcat_version, ".", "-")
    mysql  = replace(var.mysql_version, ".", "-")
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.tomcat_mysql"]

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
