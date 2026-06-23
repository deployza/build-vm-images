# `java` image

GCE image family **`java`**: Ubuntu + basic tools + gcloud CLI + JDK.

Use this when you need a JVM but not Tomcat (batch jobs, CLI tools, custom
launchers). For a web app server use [`tomcat`](../tomcat/) instead.

## Contents

- `install-basics.sh` — apt basics + gcloud CLI
- `install-java.sh` — JDK under `/opt/java`, symlinked `/opt/java/latest`

Versions are pinned in [`../../../scripts/ubuntu/versions.env`](../../../scripts/ubuntu/versions.env).

## Build

```bash
gcloud builds submit --config cloudbuild.yaml .
```

Local dry run (needs the Packer CLI + GCP creds):

```bash
cd images/ubuntu/java
packer init image.pkr.hcl
packer build -var=image_version=1-0-0 image.pkr.hcl
```

Image names are unique per project, so re-running with an unchanged
`image_version` **fails** at the image-create step (GCE `409 alreadyExists`) —
GCE never overwrites an existing image. Bump the version to publish a new one.
(The `java` family pointer just moves to the newest image.)

Consumers launch with `--image-family=java --image-project=tools-tech-463909`.

## Changelog

| Version | Date       | Change                          |
| ------- | ---------- | ------------------------------- |
| 1-0-0   | 2026-06-22 | Initial image. JDK 24.          |
