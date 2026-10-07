# ai-coding flavor: the VM that runs Deployza's automated coding system
# (ai-coding-server + ai-coding-ui) and its AI agents. Family: dz-ai-coding.
#
# Software only, per this repo's split. It bakes the web runtime (JDK, Tomcat,
# nginx), the toolchains the agents build with (Maven, Node, gcc and Python
# headers), the agent runtime (Claude Code, srt and its sandbox dependencies),
# Playwright with Chromium, and the Reposilite jar. The agent user, the sudo
# rule and launcher, secrets, Maven settings, Reposilite's config and unit, and
# both WARs are pushed by build-ops. See ai-coding.md.
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

# Tool versions come from scripts/ubuntu/versions.env, passed as -var by
# cloudbuild.yaml (see the tomcat flavor's template for why file() cannot read
# it). null default => `validate` fails fast if a version wasn't passed.
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

variable "maven_version" {
  type    = string
  default = null
}

variable "node_version" {
  type    = string
  default = null
}

variable "claude_code_version" {
  type    = string
  default = null
}

variable "sandbox_runtime_version" {
  type    = string
  default = null
}

variable "playwright_version" {
  type    = string
  default = null
}

variable "reposilite_version" {
  type    = string
  default = null
}

source "googlecompute" "ai_coding" {
  project_id              = var.project
  zone                    = var.zone
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]
  ssh_username            = "packer"

  # disk_size is also the resulting image's size, so a VM booting it needs a
  # boot disk of at least 10GB. This flavor uses about 7 GB of it. Clones,
  # worktrees, dependency caches and the run log spool need far more: grow the
  # boot disk (or attach a data disk) at VM launch, not here.
  disk_size = 10

  image_name        = "dz-ai-coding-${var.image_version}"
  image_family      = "dz-ai-coding"
  image_description = "${var.source_image_family} + JDK ${var.jdk_version} + Tomcat ${var.tomcat_version} + nginx ${var.nginx_version} + Maven ${var.maven_version} + Node ${var.node_version} + Claude Code ${var.claude_code_version} + srt ${var.sandbox_runtime_version} + Playwright ${var.playwright_version} (Chromium) + Reposilite ${var.reposilite_version} (jar). Configured by build-ops. Built by Cloud Build (git ${var.git_sha}). Run 'cat /etc/image-manifest.txt' on a VM for full package versions."
  image_labels = {
    flavor     = "ai-coding"
    jdk        = replace(var.jdk_version, ".", "-")
    tomcat     = replace(var.tomcat_version, ".", "-")
    nginx      = replace(var.nginx_version, ".", "-")
    maven      = replace(var.maven_version, ".", "-")
    node       = replace(var.node_version, ".", "-")
    claude     = replace(var.claude_code_version, ".", "-")
    srt        = replace(var.sandbox_runtime_version, ".", "-")
    playwright = replace(var.playwright_version, ".", "-")
    reposilite = replace(var.reposilite_version, ".", "-")
    built      = "cloudbuild"
  }
}

build {
  sources = ["source.googlecompute.ai_coding"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  provisioner "file" {
    source      = "scripts/ubuntu/"
    destination = "/tmp/scripts/"
  }

  # Order:
  #   * Tomcat, then nginx, then nginx-tomcat.sh, as on tomcat-mysql-nginx.
  #     nginx is the only path to Tomcat here (both WARs under one domain), so
  #     the RemoteIpValve trust is safe to grant.
  #   * install-node.sh before install-sandbox.sh and install-playwright.sh,
  #     which install into its global npm prefix.
  #   * install-sandbox.sh before install-claude.sh: Claude Code's own sandbox
  #     needs bwrap, socat and the AppArmor profile it installs.
  #   * install-playwright.sh is the last apt user before the logs scripts
  #     (`apt-get clean` in logs-disk-tools.sh reclaims its downloads).
  provisioner "shell" {
    # {{ .Vars }} is how environment_vars reach the script; bash -e stops the
    # bake at the first failing installer.
    execute_command = "sudo -E env {{ .Vars }} bash -e '{{ .Path }}'"
    environment_vars = [
      "IMAGE_FLAVOR=ai-coding",
      "GIT_SHA=${var.git_sha}",
    ]
    inline = [
      "bash /tmp/scripts/install-basics.sh",
      "bash /tmp/scripts/install-gcloud.sh",
      "bash /tmp/scripts/install-java.sh",
      "bash /tmp/scripts/tomcat/install-tomcat.sh",
      "bash /tmp/scripts/nginx/install-nginx.sh",
      "bash /tmp/scripts/tomcat/nginx-tomcat.sh",
      "bash /tmp/scripts/install-maven.sh",
      "bash /tmp/scripts/install-node.sh",
      "bash /tmp/scripts/ai-coding/install-build-tools.sh",
      "bash /tmp/scripts/ai-coding/install-sandbox.sh",
      "bash /tmp/scripts/ai-coding/install-claude.sh",
      "bash /tmp/scripts/ai-coding/install-playwright.sh",
      "bash /tmp/scripts/ai-coding/install-reposilite.sh",
      "bash /tmp/scripts/otelcol/install-otel.sh",
      "bash /tmp/scripts/cloud-sql-proxy/install-cloud-sql-proxy.sh",
      "bash /tmp/scripts/logs/logs-system.sh",
      "bash /tmp/scripts/logs/logs-disk-tools.sh",
      "bash /tmp/scripts/write-manifest.sh",
    ]
  }
}
