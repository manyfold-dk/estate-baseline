#!/bin/sh
# Read and validate a generic CI engine switch (engine-agnostic gating).
#
# Switch file format:
#   CI_MODE=blacksmith            -- GitHub Actions on Blacksmith runners run the heavy CI
#   DEPLOY_ENGINE=blacksmith|none -- whether that run may commit the image tag
#
# Tekton was the other engine until 2026-09-27; the values `tekton` and `dual` are refused
# so a stale switch file fails loudly.
#
# Lifted from the platform's scripts/ci/read-ci-engine-switch.sh for the shared
# baseline. Difference from the origin: no repo-root derivation (a relative
# --env-file resolves against $GITHUB_WORKSPACE or cwd).
set -eu

ENV_FILE=""
NAME="application"
GITHUB_OUTPUT_MODE=false
QUIET=false
FORCE_RUN=false
FORCE_DEPLOY=false

usage() {
  cat <<'EOF'
Usage:
  read-ci-engine-switch.sh --env-file PATH [options]

Options:
  --name NAME           Human-readable app name for validation messages
  --github-output       Append key=value pairs to $GITHUB_OUTPUT
  --force-run           Force run_blacksmith=true for manual dispatch
  --force-deploy        Force deploy_blacksmith=true for manual dispatch
  --quiet               Do not print key=value pairs
  -h, --help            Show this help
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      [ $# -ge 2 ] || die "--env-file requires a path argument"
      ENV_FILE="$2"
      shift 2
      ;;
    --name)
      [ $# -ge 2 ] || die "--name requires an argument"
      NAME="$2"
      shift 2
      ;;
    --github-output)
      GITHUB_OUTPUT_MODE=true
      shift
      ;;
    --force-run)
      FORCE_RUN=true
      shift
      ;;
    --force-deploy)
      FORCE_DEPLOY=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
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

[ -n "${ENV_FILE}" ] || die "--env-file is required"
# Resolve a relative switch path against the workspace (or cwd), not a repo root.
case "${ENV_FILE}" in
  /*) ;;
  *) ENV_FILE="${GITHUB_WORKSPACE:-$(pwd)}/${ENV_FILE}" ;;
esac
[ -f "${ENV_FILE}" ] || die "switch file not found for ${NAME}: ${ENV_FILE}"

read_key() {
  grep -E "^$1=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' "'"'" || true
}

CI_MODE=$(read_key CI_MODE)
DEPLOY_ENGINE=$(read_key DEPLOY_ENGINE)

[ -n "${CI_MODE}" ] || die "CI_MODE is missing from ${ENV_FILE}"
[ -n "${DEPLOY_ENGINE}" ] || die "DEPLOY_ENGINE is missing from ${ENV_FILE}"

case "${CI_MODE}" in
  blacksmith) ;;
  tekton|dual) die "CI_MODE '${CI_MODE}' for ${NAME}: Tekton was retired on 2026-09-27 (expected: blacksmith)" ;;
  *) die "invalid CI_MODE '${CI_MODE}' for ${NAME} (expected: blacksmith)" ;;
esac

case "${DEPLOY_ENGINE}" in
  blacksmith|none) ;;
  tekton) die "DEPLOY_ENGINE 'tekton' for ${NAME}: Tekton was retired on 2026-09-27 (expected: blacksmith, none)" ;;
  *) die "invalid DEPLOY_ENGINE '${DEPLOY_ENGINE}' for ${NAME} (expected: blacksmith, none)" ;;
esac

RUN_BLACKSMITH=true

case "${DEPLOY_ENGINE}" in
  blacksmith) DEPLOY_BLACKSMITH=true ;;
  none)       DEPLOY_BLACKSMITH=false ;;
esac

if [ "${FORCE_RUN}" = "true" ]; then
  RUN_BLACKSMITH=true
fi
if [ "${FORCE_DEPLOY}" = "true" ]; then
  RUN_BLACKSMITH=true
  DEPLOY_BLACKSMITH=true
fi

value_of() {
  case "$1" in
    run_blacksmith)    echo "${RUN_BLACKSMITH}" ;;
    deploy_blacksmith) echo "${DEPLOY_BLACKSMITH}" ;;
    ci_mode)           echo "${CI_MODE}" ;;
    deploy_engine)     echo "${DEPLOY_ENGINE}" ;;
    *) die "unknown output key: $1" ;;
  esac
}

KEYS="run_blacksmith deploy_blacksmith ci_mode deploy_engine"

if [ "${QUIET}" != "true" ]; then
  for k in ${KEYS}; do
    echo "${k}=$(value_of "${k}")"
  done
fi

if [ "${GITHUB_OUTPUT_MODE}" = "true" ]; then
  [ -n "${GITHUB_OUTPUT:-}" ] || die "--github-output set but \$GITHUB_OUTPUT is not defined"
  for k in ${KEYS}; do
    echo "${k}=$(value_of "${k}")" >> "${GITHUB_OUTPUT}"
  done
fi

exit 0
