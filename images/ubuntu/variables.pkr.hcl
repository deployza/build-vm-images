# Shared Packer variables for all flavors.
#
# Packer does not merge .pkr.hcl files across directories, so each flavor's
# template under images/<flavor>/ declares its own copy of these variables. This
# file is the canonical reference for the defaults — keep the per-flavor copies
# in sync with it.

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

# The GCE project that hosts the source image family. Ubuntu families live in
# ubuntu-os-cloud; without this Packer scans GCE's full default public-image
# project list and 404s on the Ubuntu family.
variable "source_image_project_id" {
  type    = string
  default = "ubuntu-os-cloud"
}

variable "image_version" {
  type    = string
  default = "1-0-0"
}

# Where the install-*.sh scripts fetch tarballs from.
variable "files_base_url" {
  type    = string
  default = "https://storage.googleapis.com/files.deployza.com"
}

# Software versions. These feed BOTH image_labels (GCE-safe dash form, e.g.
# "11-0-8") and the human-readable image_description (dotted form, e.g.
# "11.0.8"), so each flavor template bumps a version in exactly one place.
# Keep these in sync with scripts/ubuntu/versions.env (the install-time source
# of truth). Only the flavors that install a given tool declare its variables.

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
