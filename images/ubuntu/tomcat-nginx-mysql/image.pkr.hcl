# tomcat-nginx-mysql flavor: basics + Java + Tomcat (systemd) + nginx (systemd,
# reverse proxy to Tomcat) + MySQL (systemd).
# Family: dz-tomcat-nginx-mysql. Web front door, app server and database co-located
# on one VM.
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

# Tool versions come from scripts/ubuntu/versions.env — the same single source the
# installers use — so labels/description can never drift from what is installed.
# Packer's file() can't read it directly: file() resolves relative to path.root
# (the template dir) and strips any ".." that would climb above it, so a sibling
# like scripts/ubuntu/ is unreachable. Instead cloudbuild.yaml sources versions.env
# and passes these as -var (the same path image_version/git_sha take). null default
# => `validate` fails fast if a version wasn't passed, rather than baking a blank.
variable "jdk_version" {
  type    = string
  default = null
}

variable "tomcat_version" {
  type    = string
  default = null
}

variable "nginx_version" {
  type    = string
  default = null
}

variable "mysql_version" {
  type    = string
  default = null
}

source "googlecompute" "tomcat_nginx_mysql" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]
  ssh_username            = "packer"

  # BAKE VM SIZE AND DISK ARE SET BY install-basics.sh, WHICH COMPILES CPYTHON
  # (PGO+LTO) ON EVERY FLAVOR -- see that script's header. Bake time there is
  # almost entirely parallel `make`, so it tracks the bake VM's core count:
  # on googlecompute's e2-standard-2 default it runs well over half an hour,
  # on 8 vCPUs it is minutes. The disk must hold the base image,
  # build-essential and a full CPython source tree with its object files at
  # once, which 10GB does not do comfortably. This VM exists only for the bake.
  # Keep these in step with cloudbuild.yaml's `timeout`, not instead of it.
  machine_type = "e2-standard-8"
  disk_size    = 20

  image_name              = "dz-tomcat-nginx-mysql-${var.image_version}"
  image_family            = "dz-tomcat-nginx-mysql"
  image_description       = "${var.source_image_family} + JDK ${var.jdk_version} + Tomcat ${var.tomcat_version} (systemd) + nginx ${var.nginx_version} (systemd, reverse proxy to Tomcat) + MySQL ${var.mysql_version} (systemd). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor = "tomcat-nginx-mysql"
    jdk    = replace(var.jdk_version, ".", "-")
    tomcat = replace(var.tomcat_version, ".", "-")
    nginx  = replace(var.nginx_version, ".", "-")
    mysql  = replace(var.mysql_version, ".", "-")
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.tomcat_nginx_mysql"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  provisioner "file" {
    source      = "scripts/ubuntu/"
    destination = "/tmp/scripts/"
  }

  # install-nginx.sh runs after install-tomcat.sh: its config proxies to Tomcat on
  # 127.0.0.1:8080 and the installer runs `nginx -t` to fail the bake on a bad
  # config. nginx does not need Tomcat running to validate, but keeping the app
  # server first matches the read order of the resulting stack.
  #
  # nginx-tomcat.sh is a SEPARATE line, not called from install-nginx.sh: it
  # enables Tomcat's RemoteIpValve, i.e. tells Tomcat to believe the X-Forwarded-*
  # headers nginx sets. That is only safe on a flavor where nginx is the sole path
  # to the :8080 connector, so it stays an explicit per-flavor decision — the
  # plain `tomcat` / `tomcat-mysql` flavors must NOT add this line. It must run
  # after install-tomcat.sh (it edits Tomcat's server.xml) and is placed after
  # install-nginx.sh so the trust is granted only once the proxy exists.
  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "IMAGE_FLAVOR=tomcat-nginx-mysql",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-gcloud.sh",
      "bash /tmp/scripts/install-java.sh",
      "bash /tmp/scripts/tomcat/install-tomcat.sh",
      "bash /tmp/scripts/nginx/install-nginx.sh",
      "bash /tmp/scripts/tomcat/nginx-tomcat.sh",
      "bash /tmp/scripts/install-mysql.sh",
      "bash /tmp/scripts/otelcol/install-otel.sh",
      "bash /tmp/scripts/cloud-sql-proxy/install-cloud-sql-proxy.sh",
      "bash /tmp/scripts/install-python.sh",
      "bash /tmp/scripts/logs/logs-system.sh",
      "bash /tmp/scripts/logs/logs-disk-tools.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
