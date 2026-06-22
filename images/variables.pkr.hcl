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
  default = "ubuntu-2504-amd64"
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
