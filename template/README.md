# Service repository scaffold

A starting point for an application repository that runs to this baseline: a Quarkus module,
its CI on the shared reusable workflows, GitOps manifests for Argo CD, and decision records.
Copy the directory, then work through the first steps.

## What's in here

| Path | Purpose |
|---|---|
| `.github/workflows/ci.yml` | Pull request: verify and validate manifests. `main`: verify, build and push the image, bump the GitOps deploy tag. All on the [shared workflows](../.github/workflows/README.md). |
| `.github/workflows/secret-scan.yml` | `gitleaks` over every pull request and push to `main`. |
| `.github/renovate.json` | Extends this repository's Renovate preset. |
| `apps/app/.mvn/{settings.xml,maven.config}` | Committed Maven settings: the build parent resolves from an authenticated registry, the token from `MAVEN_REGISTRY_TOKEN` ([why](../docs/maven-conventions.md#resolving-the-parent-needs-settingsxml-not-only-a-server-entry)). |
| `gitops/prod/kustomization.yaml` | The Argo CD entry point; starts empty and must always build. |
| `gitops/prod/postgres-statefulset.example.yaml` | A copy-rename database example: restricted Pod Security, non-root, digest-pinned image, opt-in file-system backup with a `pg_dump` hook. |
| `docs/adr/0000-template.md` | Decision record template. |

## First steps

1. Replace the placeholders: `<owner>`, `<repository>`, `<major>` in `.github/workflows/ci.yml`
   and the registry URL in `apps/app/.mvn/settings.xml`.
2. Replace every `@<sha>` with the full commit id of this repository you adopt. A floating tag
   can be moved; a commit id cannot. The conformance checker fails an unpinned `uses:`.
3. Put the Quarkus module under `apps/app/` and the manifests under `gitops/prod/`.
4. Set a `MAVEN_TOKEN` secret if the build parent lives in another repository's package
   registry; the job's own `GITHUB_TOKEN` reads only this repository's packages.

## Before you add a database

Backup of a volume is opt-in. The example StatefulSet carries the two things that make a
volume's data recoverable: the `backup.velero.io/backup-volumes` annotation, which puts the
volume into Velero's file-system backup, and a pre-backup hook that writes a `pg_dump` next to
the data directory, so every backup holds a consistent logical dump as well as the raw files.
The conformance rule `manifest.pvc-backup-annotation` fails a volume without the annotation;
a volume that holds only regenerable data gets a deviation ADR instead.
