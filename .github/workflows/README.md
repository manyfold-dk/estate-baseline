# Reusable CI -- workflows and composite actions

Consume by **full commit SHA** (`uses: manyfold-dk/estate-baseline/.github/workflows/<name>.yml@<40-hex-sha>`).
A floating tag can be repointed by anyone with write access; a commit id cannot.

## Workflows

| Workflow | Purpose | Trigger |
|---|---|---|
| `secret-scan.yml` | `gitleaks` over the commits a pull request or push introduced; `full-history: true` for a scheduled sweep. Needs no inputs beyond that. | `workflow_call` |
| `docs-link-check.yml` | `lychee` over Markdown, offline by default: relative links and anchors. `args` opts into online checking or scopes paths; a repo-local `.lycheeignore` is honoured. | `workflow_call` |
| `manifest-validate.yml` | `kustomize build` plus `kubeconform` over a GitOps directory, tools pinned and checksummed. | `workflow_call` |
| `blacksmith-node-app-ci.yml` | A Node/pnpm app: verify, build and push an image, bump the GitOps tag, notify. Runs on Blacksmith runners. | `workflow_call` |
| `quarkus-build.yml` | Pull-request verify for a Maven module (`mvn verify`); nothing published. | `workflow_call` |
| `quarkus-image-build-push.yml` | Push-to-main verify, then build and push an image; `github` or `blacksmith` engine. | `workflow_call` |

## Composite actions

Under `.github/actions/`. Logic lives in checked-in, `bats`-tested shell scripts.

| Action | Purpose | Key inputs |
|---|---|---|
| `secret-scan` | Install a checksum-verified `gitleaks` and scan the event's commit range, values redacted. Needs a `fetch-depth: 0` checkout. Bump `gitleaks-version` and both sha256 defaults together. | `full-history` |
| `bump-deploy-tag` | Update a GitOps image tag, commit, push with rebase-retry. Runs in the caller's checkout with the caller's credentials. Exactly one of `manifest` (one Deployment file) or `manifest-dir` (a directory of manifests). `digest` pins the image as `<tag>@sha256:...`; `manifest` only. | `app-name`, `image-base`, `tag`, `digest`, `manifest` \| `manifest-dir`, `branch` |
| `read-ci-engine-switch` | Read and validate a `CI_MODE` / `DEPLOY_ENGINE` switch file; emit run and deploy gating outputs. | `env-file`, `name`, `force-run`, `force-deploy` |
| `notify-deployment` | Post a Slack deploy notification; no-op when the webhook is empty. | `app-name`, `status`, `image-tag`, `argocd-url`, `slack-webhook-url` |
| `setup-maven-registry` | Write `~/.m2/settings.xml` with one authenticated repository in an active profile, so a parent POM resolves from it. Mode 0600, values XML-escaped, token never printed. | `repository-url`, `username`, `token`, `server-id` |

## blacksmith-node-app-ci caller contract

- **Repo layout:** `apps/<app-name>/` containing a `Dockerfile` and `pnpm-lock.yaml`.
- **Switch file:** a file (path passed as `switch-file`) with `CI_MODE=tekton|dual|blacksmith`
  and `DEPLOY_ENGINE=tekton|blacksmith|none`.
- **Secrets:** `PUSH_TOKEN` (required: ghcr push and GitOps push; a fine-grained PAT) and
  optionally `SLACK_WEBHOOK_DEPLOYMENTS_URL`, passed in an explicit `secrets:` block.
  `secrets: inherit` is not supported.
- **Inputs:** `app-name`, `image-base`, `manifest-dir`, `switch-file` (required);
  `node-version`, `pnpm-version`, `argocd-url`, `force-run`, `force-deploy`.
- **No caller-side scripts.** The three scripts this workflow depends on are composite
  actions here.

## Quarkus caller contract

- **Two halves.** Gate pull requests with `quarkus-build`; build and push `main` with
  `quarkus-image-build-push`. Both take `working-directory` and `java-version` (required;
  no default, the caller states its JDK).
- **Maven registry.** Pass `maven-repository-url` when a dependency or the parent POM lives in
  an authenticated repository; leave it empty for Maven Central only. `maven-server-id`
  (default `github`) must match any committed `.mvn/settings.xml`. The token comes from the
  optional `maven-token` secret, else the job's `GITHUB_TOKEN`, which reads only the calling
  repository's packages. A committed settings file reads it as `MAVEN_REGISTRY_TOKEN` or
  `GITHUB_PERSONAL_ACCESS_TOKEN`.
- **Image.** `image-base` (required), `dockerfile`, `build-args`, `registry-cache`. The
  Dockerfile receives the token as the BuildKit secret `gh_token`
  (`RUN --mount=type=secret,id=gh_token ...`). The image job runs only on `refs/heads/main`
  and needs `packages: write` from the caller.
- **Engine.** `engine: blacksmith` with `runner-verify` and `runner-image` set to Blacksmith
  labels; the default `github` needs nothing.
- **Caller-side.** Frontend jobs, the GitOps tag bump (`bump-deploy-tag`) and smoke tests.
