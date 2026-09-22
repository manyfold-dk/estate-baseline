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

## Composite actions

Under `.github/actions/`. Logic lives in checked-in, `bats`-tested shell scripts.

| Action | Purpose | Key inputs |
|---|---|---|
| `secret-scan` | Install a checksum-verified `gitleaks` and scan the event's commit range, values redacted. Needs a `fetch-depth: 0` checkout. Bump `gitleaks-version` and both sha256 defaults together. | `full-history` |
| `bump-deploy-tag` | Update a GitOps image tag, commit, push with rebase-retry. Runs in the caller's checkout with the caller's credentials. Exactly one of `manifest` (one Deployment file) or `manifest-dir` (a directory of manifests). | `app-name`, `image-base`, `tag`, `manifest` \| `manifest-dir`, `branch` |
| `read-ci-engine-switch` | Read and validate a `CI_MODE` / `DEPLOY_ENGINE` switch file; emit run and deploy gating outputs. | `env-file`, `name`, `force-run`, `force-deploy` |
| `notify-deployment` | Post a Slack deploy notification; no-op when the webhook is empty. | `app-name`, `status`, `image-tag`, `argocd-url`, `slack-webhook-url` |

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
