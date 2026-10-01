# tomcat-mysql-nginx flavor: basics + Java + Tomcat (systemd) + nginx (systemd,
# reverse proxy to Tomcat) + MySQL (systemd).
# Family: dz-tomcat-mysql-nginx. Web front door, app server and database co-located
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

source "googlecompute" "tomcat_mysql_nginx" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]
  ssh_username            = "packer"

  # disk_size is also the resulting image's size, so a VM booting it needs a
  # boot disk of at least 10GB. The bake VM keeps googlecompute's default
  # machine type (e2-standard-2): no step in the bake is CPU-bound.
  disk_size = 10

  image_name              = "dz-tomcat-mysql-nginx-${var.image_version}"
  image_family            = "dz-tomcat-mysql-nginx"
  image_description       = "${var.source_image_family} + JDK ${var.jdk_version} + Tomcat ${var.tomcat_version} (systemd) + nginx ${var.nginx_version} (systemd, reverse proxy to Tomcat) + MySQL ${var.mysql_version} (systemd). Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor = "tomcat-mysql-nginx"
    jdk    = replace(var.jdk_version, ".", "-")
    tomcat = replace(var.tomcat_version, ".", "-")
    nginx  = replace(var.nginx_version, ".", "-")
    mysql  = replace(var.mysql_version, ".", "-")
    built  = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.tomcat_mysql_nginx"]

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
    # {{ .Vars }} is how environment_vars reach the script; bash -e stops the
    # bake at the first failing installer. Without either, the manifest read
    # "unknown" and a failed install-*.sh still produced an image.
    execute_command = "sudo -E env {{ .Vars }} bash -e '{{ .Path }}'"
    environment_vars = [
      "IMAGE_FLAVOR=tomcat-mysql-nginx",
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
      "bash /tmp/scripts/logs/logs-system.sh",
      "bash /tmp/scripts/logs/logs-disk-tools.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
