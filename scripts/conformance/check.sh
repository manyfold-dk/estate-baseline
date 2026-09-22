#!/usr/bin/env bash
# Usage: check.sh <consumer-dir> <baseline.json>
# Lists unexplained drift vs baseline.json for maven.compiler.release (pom-declared)
# and maven.wrapper.version (a file -- NOT carried by parent-POM inheritance).
# A drift is suppressed by an `accepted` deviation ADR whose `field:` matches.
#
# Exit codes: 0 = clean, 3 = drift, anything else = script/tooling error. The cron
# relies on this to tell real drift from a broken run -- a jq/grep failure must never
# be reported to a consumer as "drift".
set -euo pipefail

consumer="${1:?consumer dir required}"
baseline="${2:?baseline.json required}"
drift=0

# True if an accepted deviation ADR for field $1 exists in the consumer repo.
has_deviation() {
  local field="$1" f
  while IFS= read -r f; do
    grep -q '^status:[[:space:]]*accepted' "$f" && return 0
  done < <(grep -rls "^field:[[:space:]]*${field}\$" "$consumer"/docs/adr 2>/dev/null)
  return 1
}

report() {  # field, got, want, where
  has_deviation "$1" && return 0
  echo "DRIFT: $1 = $2 (baseline $3) in $4"
  drift=3
}

# --- maven.compiler.release (one per pom; inherited from the parent once repointed) ---
want="$(jq -r '.fields["maven.compiler.release"]' "$baseline")"
while IFS= read -r pom; do
  # `|| true`: a pom that does NOT declare the property (the normal case once it inherits
  # from the parent) makes grep exit non-zero; without this, set -euo pipefail would abort.
  got="$(grep -oE '<maven.compiler.release>[^<]+' "$pom" | head -1 | sed 's/.*>//' || true)"
  [ -z "$got" ] && continue
  [ "$got" = "$want" ] || report "maven.compiler.release" "$got" "$want" "$pom"
done < <(find "$consumer" -name pom.xml -not -path '*/target/*')

# --- maven.wrapper.version (NOT inheritable -- must be policed here) ---
want="$(jq -r '.fields["maven.wrapper.version"]' "$baseline")"
while IFS= read -r props; do
  got="$(grep -oE 'apache-maven-[0-9.]+-bin' "$props" | head -1 | sed -E 's/apache-maven-([0-9.]+)-bin/\1/' || true)"
  [ -z "$got" ] && continue
  [ "$got" = "$want" ] || report "maven.wrapper.version" "$got" "$want" "$props"
done < <(find "$consumer" -path '*/.mvn/wrapper/maven-wrapper.properties' -not -path '*/target/*')

# --- workflow.action-pinning: every remote `uses:` ref must be a 40-hex commit SHA ---
# Heuristic. Exempt: local `./` refs and `docker://` refs (no owner/repo@ref form so the regex
# never matches), commented-out lines, and same-repo self-references -- a repo's refs to its OWN
# actions/workflows cannot take a dynamic same-repo SHA and are not a third-party supply-chain
# risk (like `./` refs). A consumer referencing a DIFFERENT repo's actions is still flagged.
# Suppress an unavoidable case with a deviation ADR field=workflow.action-pinning.
if [ -d "$consumer/.github/workflows" ]; then
  self_slug="$(git -C "$consumer" config --get remote.origin.url 2>/dev/null \
    | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##' || true)"
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    f="${hit%%:*}"
    ref="$(printf '%s\n' "$hit" | sed -E 's/^[^:]*:[0-9]+:.*uses:[[:space:]]*//; s/[[:space:]].*$//')"
    ref_repo="$(printf '%s\n' "$ref" | cut -d/ -f1-2)"
    if [ -n "$self_slug" ] && [ "$ref_repo" = "$self_slug" ]; then continue; fi
    report "workflow.action-pinning" "$ref" "<owner>/<repo>@<40-hex-sha>" "$f"
  done < <(
    grep -RHnE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[^[:space:]#]+' \
      "$consumer/.github/workflows" 2>/dev/null \
      | grep -vE ':[0-9]+:[[:space:]]*#' \
      | grep -vE '@[0-9a-f]{40}([[:space:]#]|$)' || true
  )
fi

# --- workflow.permissions: every workflow must declare a top-level permissions: block ---
# Heuristic: a `permissions:` line at column 0. Job-level-only layouts are valid GitHub Actions
# but rare in this estate; a consumer using them records a deviation ADR.
if [ -d "$consumer/.github/workflows" ]; then
  while IFS= read -r wf; do
    grep -qE '^permissions:' "$wf" || report "workflow.permissions" "(none at top level)" "a top-level permissions: block" "$wf"
  done < <(find "$consumer/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)
fi

# --- manifest.image-digest: workload `image:` lines must be @sha256-pinned ---
# Heuristic: YAML outside .github/ whose `kind:` is a workload. `$`-templated images are skipped.
while IFS= read -r y; do
  grep -qE '^kind:[[:space:]]*(Deployment|StatefulSet|DaemonSet|CronJob|Job)[[:space:]]*$' "$y" || continue
  while IFS= read -r imgline; do
    if printf '%s\n' "$imgline" | grep -q '\$'; then continue; fi
    if printf '%s\n' "$imgline" | grep -q '@sha256:'; then continue; fi
    img="$(printf '%s\n' "$imgline" | sed -E 's/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*//; s/[[:space:]].*$//')"
    report "manifest.image-digest" "$img" "<image>@sha256:<digest>" "$y"
  done < <(grep -E '^[[:space:]]*-?[[:space:]]*image:[[:space:]]*[^[:space:]]' "$y" || true)
done < <(find "$consumer" -type f \( -name '*.yaml' -o -name '*.yml' \) \
           -not -path '*/.github/*' -not -path '*/target/*' -not -path '*/node_modules/*' 2>/dev/null)

# --- manifest.pvc-backup-annotation: PVC-bearing manifests need the Velero backup annotation ---
# Implements the platform's opt-in fs-backup model (its ADR-0020) (file-level heuristic); a
# legitimate opt-out (regeneratable data) records a deviation ADR field=manifest.pvc-backup-annotation.
while IFS= read -r y; do
  grep -qE 'volumeClaimTemplates:|persistentVolumeClaim:' "$y" || continue
  grep -q 'backup.velero.io/backup-volumes' "$y" || report "manifest.pvc-backup-annotation" "(PVC without backup annotation)" "backup.velero.io/backup-volumes present" "$y"
done < <(find "$consumer" -type f \( -name '*.yaml' -o -name '*.yml' \) \
           -not -path '*/.github/*' -not -path '*/target/*' -not -path '*/node_modules/*' 2>/dev/null)

exit "$drift"
