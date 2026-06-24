# Shared Packer variables for all flavors.
#
# Passed to every `packer build` alongside the flavor's image.pkr.hcl (see each
# flavor's cloudbuild.yaml). Holds only the variables that are identical for
# every flavor; per-flavor and per-build values (source image, image_version,
# tool versions) stay in the flavor template / versions.env.
#
# Packer does not auto-merge .pkr.hcl across directories, so this file only takes
# effect because the build steps pass it explicitly. A local single-file
# `packer build images/ubuntu/<flavor>/image.pkr.hcl` must pass this file too.

variable "project" {
  type    = string
  default = "tools-tech-463909"
}

variable "zone" {
  type    = string
  default = "asia-east1-b"
}
