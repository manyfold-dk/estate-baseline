#!/bin/sh
# Send a deployment notification to Slack from CI.
#
# Lifted verbatim from the platform's scripts/ci/notify-deployment.sh for the
# shared baseline (the origin already carries no repo-root assumptions). The
# caller passes the webhook explicitly via SLACK_WEBHOOK_URL (composite actions
# cannot read secrets directly); an empty webhook is a successful no-op.
set -eu

APP_NAME=""
PIPELINE_NAME="${GITHUB_WORKFLOW:-GitHub Actions}"
STATUS="succeeded"
ENGINE="github-actions"
ENVIRONMENT="cloud"
RUN_NAME=""
RUN_URL=""
COMMIT_SHA="${GITHUB_SHA:-}"
REPO_URL=""
IMAGE_TAG=""
# The Argo CD link in the message; no link when empty. The caller knows its own URL.
ARGOCD_URL="${ARGOCD_URL:-}"

usage() {
  cat <<'EOF'
Usage:
  notify-deployment.sh --app-name APP --status STATUS --image-tag TAG [options]

Options:
  --pipeline-name NAME  CI workflow or pipeline name
  --engine ENGINE       CI/deploy engine: github-actions, blacksmith, tekton
  --environment ENV     Deployment environment label (default: cloud)
  --run-name NAME       Human-readable run name
  --run-url URL         Link to the CI run
  --commit-sha SHA      Source commit SHA
  --repo-url URL        Repository URL used for commit links
  --argocd-url URL      ArgoCD base URL
  -h, --help            Show this help

Environment:
  SLACK_WEBHOOK_URL must contain the Slack incoming webhook URL. If it is not
  set, the script logs a skip and exits successfully.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app-name)
      [ $# -ge 2 ] || die "--app-name requires an argument"
      APP_NAME="$2"
      shift 2
      ;;
    --pipeline-name)
      [ $# -ge 2 ] || die "--pipeline-name requires an argument"
      PIPELINE_NAME="$2"
      shift 2
      ;;
    --status)
      [ $# -ge 2 ] || die "--status requires an argument"
      STATUS="$2"
      shift 2
      ;;
    --engine)
      [ $# -ge 2 ] || die "--engine requires an argument"
      ENGINE="$2"
      shift 2
      ;;
    --environment)
      [ $# -ge 2 ] || die "--environment requires an argument"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --run-name)
      [ $# -ge 2 ] || die "--run-name requires an argument"
      RUN_NAME="$2"
      shift 2
      ;;
    --run-url)
      [ $# -ge 2 ] || die "--run-url requires an argument"
      RUN_URL="$2"
      shift 2
      ;;
    --commit-sha)
      [ $# -ge 2 ] || die "--commit-sha requires an argument"
      COMMIT_SHA="$2"
      shift 2
      ;;
    --repo-url)
      [ $# -ge 2 ] || die "--repo-url requires an argument"
      REPO_URL="$2"
      shift 2
      ;;
    --image-tag)
      [ $# -ge 2 ] || die "--image-tag requires an argument"
      IMAGE_TAG="$2"
      shift 2
      ;;
    --argocd-url)
      [ $# -ge 2 ] || die "--argocd-url requires an argument"
      ARGOCD_URL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (use --help)"
      ;;
  esac
done

[ -n "${APP_NAME}" ] || die "--app-name is required"
[ -n "${STATUS}" ] || die "--status is required"

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "Slack deployment webhook not configured; skipping notification."
  exit 0
fi

case "${ENGINE}" in
  blacksmith|github-actions|github_actions)
    ENGINE_LABEL="GitHub Actions / Blacksmith"
    ;;
  tekton)
    ENGINE_LABEL="Tekton"
    ;;
  *)
    ENGINE_LABEL="${ENGINE}"
    ;;
esac

case "${STATUS}" in
  success|succeeded)
    STATUS_TEXT="succeeded"
    EMOJI=":white_check_mark:"
    COLOR="#36a64f"
    ;;
  failure|failed)
    STATUS_TEXT="failed"
    EMOJI=":x:"
    COLOR="#dc3545"
    ;;
  cancelled|canceled)
    STATUS_TEXT="was cancelled"
    EMOJI=":warning:"
    COLOR="#ffc107"
    ;;
  *)
    STATUS_TEXT="completed with status: ${STATUS}"
    EMOJI=":grey_question:"
    COLOR="#6c757d"
    ;;
esac

if [ -z "${RUN_NAME}" ]; then
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    RUN_NAME="run ${GITHUB_RUN_ID}"
  else
    RUN_NAME="CI run"
  fi
fi

if [ -z "${RUN_URL}" ] && [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

if [ -z "${REPO_URL}" ] && [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  REPO_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
fi

SHORT_SHA=""
COMMIT_LINK=""
if [ -n "${COMMIT_SHA}" ]; then
  SHORT_SHA=$(printf "%s" "${COMMIT_SHA}" | cut -c1-7)
  if [ -n "${REPO_URL}" ]; then
    COMMIT_LINK="${REPO_URL%/}/commit/${COMMIT_SHA}"
  fi
fi

payload=$(python3 - "$EMOJI" "$STATUS_TEXT" "$COLOR" "$ENVIRONMENT" "$APP_NAME" \
  "$PIPELINE_NAME" "$ENGINE_LABEL" "$RUN_NAME" "$RUN_URL" "$SHORT_SHA" "$COMMIT_LINK" \
  "$IMAGE_TAG" "$ARGOCD_URL" <<'PY'
import json
import sys

(
    emoji,
    status_text,
    color,
    environment,
    app_name,
    pipeline_name,
    engine_label,
    run_name,
    run_url,
    short_sha,
    commit_link,
    image_tag,
    argocd_url,
) = sys.argv[1:]

env_label = environment.upper()
run_text = f"<{run_url}|{run_name}>" if run_url else run_name
commit_text = f"<{commit_link}|{short_sha}>" if commit_link else short_sha

lines = [
    f"{emoji} *Deployment pipeline {status_text}*",
    f"*Environment:* {env_label}",
    f"*Application:* {app_name}",
    f"*Pipeline:* {pipeline_name}",
    f"*Deploy engine:* {engine_label}",
    f"*Run:* {run_text}",
]

if commit_text:
    lines.append(f"*Commit:* {commit_text}")
if image_tag:
    lines.append(f"*Image:* {image_tag}")

blocks = [
    {
        "type": "section",
        "text": {"type": "mrkdwn", "text": "\n".join(lines)},
    },
]

context = []
if run_url:
    context.append({"type": "mrkdwn", "text": f":link: <{run_url}|View GitHub Actions run>"})
if argocd_url:
    context.append({"type": "mrkdwn", "text": f":rocket: <{argocd_url.rstrip('/')}/applications/{app_name}|View in ArgoCD>"})
if context:
    blocks.append({"type": "context", "elements": context})

print(json.dumps({"blocks": blocks, "attachments": [{"color": color, "blocks": []}]}))
PY
)

echo "Sending Slack deployment notification for ${APP_NAME} (${STATUS})..."
set +e
http_status=$(curl -sS -o /tmp/slack-notify-response.txt -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "${payload}" \
  "${SLACK_WEBHOOK_URL}")
curl_status=$?
set -e

if [ "${curl_status}" -ne 0 ] && [ -z "${http_status}" ]; then
  http_status="000"
fi

if [ "${http_status}" = "200" ]; then
  echo "Slack deployment notification sent."
else
  echo "WARNING: Slack deployment notification failed (HTTP ${http_status})." >&2
  cat /tmp/slack-notify-response.txt >&2 2>/dev/null || true
fi
