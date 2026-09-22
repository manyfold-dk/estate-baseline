#!/bin/sh
# Bump a GitOps image tag, commit, and push with rebase-retry.
#
# Two mutually exclusive manifest flavours:
#   --manifest FILE       single Deployment manifest; replaces only the tag on the
#                         `image: <image-base>:<tag>` line, preserving any trailing
#                         comment (the tenant flavour).
#   --manifest-dir DIR    a directory whose deployment.yaml / backend-deployment.yaml
#                         and/or kustomization.yaml carry the image (the platform
#                         flavour).
#
# The commit lands in the CALLER's checkout with the CALLER's credentials
# (the deploy commit stays caller-side, never in the baseline). Rebase-retry
# up to 3x; after a reset, a clean diff means the remote already carries the tag
# (success, not failure).
set -eu

APP_NAME=""
IMAGE_BASE=""
TAG=""
MANIFEST=""
MANIFEST_DIR=""
BRANCH="main"

usage() {
  cat <<'EOF'
Usage:
  bump-deploy-tag.sh --app-name APP --image-base REPO --tag TAG \
    ( --manifest FILE | --manifest-dir DIR ) [--branch main]
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
    --image-base)
      [ $# -ge 2 ] || die "--image-base requires an argument"
      IMAGE_BASE="$2"
      shift 2
      ;;
    --tag)
      [ $# -ge 2 ] || die "--tag requires an argument"
      TAG="$2"
      shift 2
      ;;
    --manifest)
      [ $# -ge 2 ] || die "--manifest requires an argument"
      MANIFEST="$2"
      shift 2
      ;;
    --manifest-dir)
      [ $# -ge 2 ] || die "--manifest-dir requires an argument"
      MANIFEST_DIR="$2"
      shift 2
      ;;
    --branch)
      [ $# -ge 2 ] || die "--branch requires an argument"
      BRANCH="$2"
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
[ -n "${IMAGE_BASE}" ] || die "--image-base is required"
[ -n "${TAG}" ] || die "--tag is required"

if [ -n "${MANIFEST}" ] && [ -n "${MANIFEST_DIR}" ]; then
  die "--manifest and --manifest-dir are mutually exclusive"
fi
if [ -z "${MANIFEST}" ] && [ -z "${MANIFEST_DIR}" ]; then
  die "exactly one of --manifest or --manifest-dir is required"
fi

case "${TAG}" in
  *[!A-Za-z0-9._-]*) die "invalid tag '${TAG}': only A-Z a-z 0-9 . _ - are allowed" ;;
esac

[ -n "${GITHUB_ACTIONS:-}" ] || die "bump-deploy-tag is intended for GitHub Actions only"

if [ -n "${MANIFEST}" ]; then
  [ -f "${MANIFEST}" ] || die "manifest file not found: ${MANIFEST}"
  CHANGE_PATH="${MANIFEST}"
else
  [ -d "${MANIFEST_DIR}" ] || die "manifest directory not found: ${MANIFEST_DIR}"
  CHANGE_PATH="${MANIFEST_DIR}"
fi

# Single-file flavour: replace only the tag on the image-base line, preserving any
# trailing comment. '#' sed delimiter avoids escaping slashes in the image path.
# Writes via a temp file (portable across GNU/BSD sed; avoids the sed -i flag split).
update_file() {
  _uf_tmp=$(mktemp)
  sed -E "s#(image:[[:space:]]*${IMAGE_BASE}):[^[:space:]]+#\1:${TAG}#" "$1" > "${_uf_tmp}"
  mv "${_uf_tmp}" "$1"
}

# Dir flavour: update `image:` lines and/or kustomization name/newTag pairs for
# IMAGE_BASE across the deployment + kustomization manifests in the directory.
update_dir() {
  dir="$1"
  files=""
  for candidate in "${dir}/backend-deployment.yaml" "${dir}/deployment.yaml"; do
    [ -f "${candidate}" ] && files="${files} ${candidate}"
  done
  [ -f "${dir}/kustomization.yaml" ] && files="${files} ${dir}/kustomization.yaml"
  [ -n "${files}" ] || die "no deployment or kustomization manifest found in ${dir}"

  has_kustomization_image=false
  if [ -f "${dir}/kustomization.yaml" ] && \
     grep -qE "^[[:space:]]*-?[[:space:]]*name:[[:space:]]*${IMAGE_BASE}[[:space:]]*$" "${dir}/kustomization.yaml"; then
    has_kustomization_image=true
  fi

  tmp_dir=$(mktemp -d)
  matched=false
  for file in ${files}; do
    tmp="${tmp_dir}/$(basename "${file}").tmp"
    status=0
    awk -v image="${IMAGE_BASE}" -v tag="${TAG}" -v has_kustomization_image="${has_kustomization_image}" '
      BEGIN { pending = 0 }
      {
        line = $0
        trimmed = line
        sub(/^[[:space:]]*/, "", trimmed)
        if (trimmed ~ /^image:[[:space:]]*/) {
          value = trimmed
          sub(/^image:[[:space:]]*/, "", value)
          if (index(value, image) == 1 && (length(value) == length(image) || substr(value, length(image) + 1, 1) == ":")) {
            if (length(value) == length(image) && has_kustomization_image == "true") {
              matched = 1
            } else {
              sub("image:[[:space:]]*" image "(:[^[:space:]]*)?", "image: " image ":" tag)
              matched = 1
            }
          }
        } else {
          name_line = trimmed
          sub(/^-?[[:space:]]*/, "", name_line)
          if (name_line ~ /^name:[[:space:]]*/) {
            name_value = name_line
            sub(/^name:[[:space:]]*/, "", name_value)
            if (name_value == image) {
              pending = 1
              matched = 1
            }
          } else if (pending == 1 && trimmed ~ /^newTag:[[:space:]]*/) {
            sub("newTag:[[:space:]]*.*", "newTag: " tag)
            pending = 0
          } else if (trimmed !~ /^$/ && trimmed !~ /^#/) {
            pending = 0
          }
        }
        print
      }
      END { if (matched == 1) exit 0; exit 2 }
    ' "${file}" > "${tmp}" || status=$?
    if [ "${status}" -eq 0 ]; then
      matched=true
      cmp -s "${file}" "${tmp}" || mv "${tmp}" "${file}"
    elif [ "${status}" -eq 2 ]; then
      :
    else
      rm -rf "${tmp_dir}"
      die "failed to process ${file} (awk exit ${status})"
    fi
  done
  rm -rf "${tmp_dir}"
  [ "${matched}" = "true" ] || die "no '${IMAGE_BASE}' image reference found in ${dir}"
}

update_tag() {
  if [ -n "${MANIFEST}" ]; then
    update_file "${MANIFEST}"
  else
    update_dir "${MANIFEST_DIR}"
  fi
}

update_tag

if git diff --quiet -- "${CHANGE_PATH}"; then
  echo "Manifest already at ${TAG} -- nothing to commit."
  exit 0
fi

git config user.name "manyfold-ci[bot]"
git config user.email "ci@manyfold.dk"

MSG="chore(deploy): update ${APP_NAME} image tag to ${TAG} [skip ci]"
BODY="Automated commit by the ${APP_NAME} CI workflow."

for attempt in 1 2 3; do
  git add "${CHANGE_PATH}"
  git commit -m "${MSG}" -m "${BODY}" || true

  if git push origin "HEAD:${BRANCH}"; then
    echo "Pushed deploy commit (attempt ${attempt})"
    exit 0
  fi

  echo "Push failed; rebasing onto latest ${BRANCH} (attempt ${attempt})..."
  git fetch origin "${BRANCH}"
  git reset --hard "origin/${BRANCH}"
  update_tag

  if git diff --quiet -- "${CHANGE_PATH}"; then
    echo "Remote ${BRANCH} already has the target tag."
    exit 0
  fi
done

die "failed to push deploy commit after 3 attempts"
