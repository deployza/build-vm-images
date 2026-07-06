# `java` image

GCE image family **`java`**: Ubuntu + basic tools + gcloud CLI + JDK.

Use this when you need a JVM but not Tomcat (batch jobs, CLI tools, custom
launchers). For a web app server use [`tomcat`](../tomcat/) instead.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-java.sh` — JDK under `/opt/java`, symlinked `/opt/java/latest`

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## Build

Run from the **repo root** (the build context must include `scripts/`, and the
Packer templates reference installers by repo-root-relative path):

```bash
gcloud builds submit --config images/ubuntu/java/cloudbuild.yaml .
```

Local dry run (needs the Packer CLI + GCP creds), also from the repo root:

```bash
packer init images/ubuntu/java/image.pkr.hcl
packer build -var=image_version=1-0-0 \
  images/ubuntu/java/image.pkr.hcl
```

`project`/`zone` are declared (with defaults) inside the flavor template itself;
override either with `-var=project=…` / `-var=zone=…` if needed.

Image names are unique per project, so re-running with an unchanged
`image_version` **fails** at the image-create step (GCE `409 alreadyExists`) —
GCE never overwrites an existing image. Bump the version to publish a new one.
(The `java` family pointer just moves to the newest image.)

Consumers launch with `--image-family=java --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                          |
| ------- | ---------- | ------------------------------- |
| 1-0-0   | 2026-06-22 | Initial image. JDK 24.          |
