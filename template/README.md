# Service repository scaffold

A starting point for an application repository that runs to this baseline: a Quarkus module,
its CI on the shared reusable workflows, GitOps manifests for Argo CD, and decision records.
Copy the directory, then work through the first steps.

## What's in here

| Path | Purpose |
|---|---|
| `.github/workflows/ci.yml` | Pull request: verify and validate manifests. `main`: verify, build and push the image, pin it by tag and digest in `gitops/prod/app/deployment.yaml`. All on the [shared workflows](../.github/workflows/README.md). |
| `.github/workflows/secret-scan.yml` | `gitleaks` over every pull request and push to `main`. |
| `.github/renovate.json` | Extends this repository's Renovate preset. |
| `apps/app/.mvn/{settings.xml,maven.config}` | Committed Maven settings: the build parent resolves from an authenticated registry, the token from `MAVEN_REGISTRY_TOKEN` ([why](../docs/maven-conventions.md#resolving-the-parent-needs-settingsxml-not-only-a-server-entry)). |
| `gitops/prod/kustomization.yaml` | The Argo CD entry point; starts empty and must always build. |
| `gitops/prod/postgres-statefulset.example.yaml` | A copy-rename database example, StatefulSet and headless Service: restricted Pod Security, non-root, digest-pinned image, opt-in file-system backup with a `pg_dump` hook that fails the backup when the dump fails. |
| `docs/adr/0000-template.md` | Decision record template. |

## First steps

1. Replace the placeholders: `<owner>`, `<repository>`, `<major>` in `.github/workflows/ci.yml`
   and the registry URL in `apps/app/.mvn/settings.xml`.
2. Replace every `@<sha>` with the full commit id of this repository you adopt. A floating tag
   can be moved; a commit id cannot. The conformance checker fails an unpinned `uses:`.
3. Put the Quarkus module under `apps/app/` and the manifests under `gitops/prod/`.
4. Create `gitops/prod/app/deployment.yaml` with the application's Deployment and list it in
   `gitops/prod/kustomization.yaml`, before the first push to `main`. Its image line has the
   form `image: ghcr.io/<owner>/<repository>/app:<tag>@sha256:<digest>`; the deploy job
   rewrites the tag and digest on every build, and fails with "manifest file not found" if the
   file is missing.
5. In the module's Dockerfile, mount the registry token under the name the committed settings
   read: `RUN --mount=type=secret,id=gh_token,env=MAVEN_REGISTRY_TOKEN ./mvnw -B package`
   (Dockerfile frontend 1.10 or later). Without `env=` the image build cannot resolve the
   build parent.
6. Set a `MAVEN_TOKEN` secret if the build parent lives in another repository's package
   registry; the job's own `GITHUB_TOKEN` reads only this repository's packages.

## Before you add a database

Backup of a volume is opt-in. The example StatefulSet carries the two things that make a
volume's data recoverable: the `backup.velero.io/backup-volumes` annotation, which puts the
volume into Velero's file-system backup, and a pre-backup hook that writes a `pg_dump` next to
the data directory. The raw files of a running database are not a consistent backup on their
own, so the hook runs with `on-error: Fail`: a dump that fails or times out marks the backup
`PartiallyFailed` instead of recording it as a success. Alert on that status, and test a
restore -- and a failing dump -- before you rely on it.
The conformance rule `manifest.pvc-backup-annotation` fails a volume without the annotation;
a volume that holds only regenerable data gets a deviation ADR instead.
