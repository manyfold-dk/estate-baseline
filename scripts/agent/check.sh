#!/usr/bin/env bash
# Usage (run from the baseline repo): scripts/agent/check.sh [--overlay <dir>] <consumer-dir>
#
# Reports agent-asset drift in <consumer-dir> vs the CURRENT baseline-agent payload:
#   1. VERSION lag  -- consumer's recorded version != baseline VERSION
#   2. content drift -- a vendored asset or the CLAUDE.md/AGENTS.md marker block differs
# A drift is suppressed by an `accepted` deviation ADR in <consumer>/docs/adr whose `field:`
# names the asset path (e.g. rules/git-workflow.md) or the sentinel `agent-baseline-version`.
# environment.md overlays are never in a profile, so they are never checked.
# --overlay <dir> composes the estate's values into the expected block the way vendor.sh did.
# The stamp's source_commit must be the payload checkout this check runs from, and its
# overlay_commit the overlay checkout given: a consumer vendored from some other commit is
# drift (field agent-baseline-source), even when the content happens to match.
#
# The stamp records whether the overlay was applied. A consumer vendored one way and checked
# the other is `agent-baseline-overlay` drift, reported first and never suppressed by a
# deviation ADR: a consumer the estate designates public must not carry the estate's values,
# and one it does not designate must not silently lose them. This script does not read the
# designation list; the caller classifies the consumer and picks the mode.
# When <consumer>/.publish-allow.tsv exists, its baseline-agent allow block must equal the
# payload's rows (publish-allow.tsv), or it is `publish-allow` drift.
set -euo pipefail

overlay=""
if [ "${1:-}" = --overlay ]; then overlay="$(cd "${2:?--overlay needs a directory}" && pwd)"; shift 2; fi
consumer="${1:?consumer dir required}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
payload="$(cd "$script_dir/../../baseline-agent" && pwd)"
profiles="$payload/profiles.yaml"
current_ver="$(cat "$payload/VERSION")"
drift=0

has_deviation() { # $1 = field
  local field="$1" f
  while IFS= read -r f; do
    grep -q '^status:[[:space:]]*accepted' "$f" && return 0
  done < <(grep -rls "^field:[[:space:]]*${field}\$" "$consumer"/docs/adr 2>/dev/null)
  return 1
}
report() { # $1 = field, $2 = message
  has_deviation "$1" && return 0
  echo "DRIFT [$1]: $2"   # print the field so callers/tests can match on it
  drift=1
}
profile_assets() { # $1 = profile name
  awk -v prof="$1" '
    $0 ~ "^  " prof ":[[:space:]]*$" {inp=1; next}
    inp && /^  [A-Za-z]/ {inp=0}
    inp && /^    - / {sub(/^    - /,""); sub(/[[:space:]]*#.*/,""); gsub(/[[:space:]]+$/,""); if($0!="") print}
  ' "$profiles"
}
canon_block() {
  awk -v dir="$overlay" '
    /^## /{f=1}
    f && dir != "" && match($0, /^<!-- [a-z-]+-overlay -->$/) {
      name=$0; sub(/^<!-- /,"",name); sub(/-overlay -->$/,"",name)
      file=dir "/" name ".md"; n=0
      while ((getline l < file) > 0) { print l; n++ }
      close(file)
      if (n == 0) { print "check: overlay file missing or empty: " file > "/dev/stderr"; exit 2 }
      next
    }
    f' "$1"
}
extract_block() { awk '/<!-- BEGIN baseline-agent/{f=1;next} /<!-- END baseline-agent/{f=0} f' "$1"; }

stamp="$consumer/.claude/.baseline-agent-version"
if [ ! -f "$stamp" ]; then
  echo "DRIFT: $consumer has no .claude/.baseline-agent-version (never vendored)"
  exit 1
fi
recorded_ver="$(sed -n 's/^version=//p' "$stamp" | head -1)"
profile="$(sed -n 's/^profile=//p' "$stamp" | head -1)"

# A recorded profile that resolves to no assets is itself a drift (typo / removed profile).
assets="$(profile_assets "$profile")"
[ -n "$assets" ] || { echo "DRIFT [profile]: $consumer records unknown/empty profile '$profile' (not in profiles.yaml)"; exit 1; }

# 0) overlay mode. Four stamp shapes: overlay_applied recorded; else a tree id in
# overlay_tree (applied) or `none` (not applied); else neither field, a stamp older than the
# overlay fields, whose block carried the estate's values inline (applied).
applied="$(sed -n 's/^overlay_applied=//p' "$stamp" | head -1)"
if [ -z "$applied" ]; then
  tree_rec="$(sed -n 's/^overlay_tree=//p' "$stamp" | head -1)"
  if [ -z "$tree_rec" ] && ! grep -q '^overlay_tree=' "$stamp"; then applied=true
  elif [ "$tree_rec" = none ]; then applied=false
  else applied=true
  fi
fi
want="$([ -n "$overlay" ] && echo true || echo false)"
mode_ok=1
if [ "$applied" != "$want" ]; then
  mode_ok=0
  if [ "$applied" = true ]; then
    echo "DRIFT [agent-baseline-overlay]: $consumer was vendored with the estate overlay; this check runs without it (a consumer designated public must be re-vendored without --overlay)"
  else
    echo "DRIFT [agent-baseline-overlay]: $consumer was vendored without the estate overlay; this check runs with it"
  fi
  drift=1   # not through report(): no deviation ADR suppresses a mode mismatch
fi

discovery="$(sed -n 's/^codex_discovery=//p' "$stamp" | head -1)"
discovery="${discovery:-legacy}"
case "$discovery" in legacy|repo) ;; *) echo "DRIFT [discovery]: unsupported $discovery"; exit 1;; esac
python3 "$script_dir/contracts.py" --payload "$payload" --consumer "$consumer" --profile "$profile" --discovery "$discovery" || drift=1

# 1) VERSION lag
[ "$recorded_ver" = "$current_ver" ] || \
  report "agent-baseline-version" "$consumer pinned at '$recorded_ver', baseline is '$current_ver'"

# 1b) provenance: the recorded commits are the checkouts this check runs from
source_now="$(git -C "$payload" rev-parse HEAD 2>/dev/null || echo unknown)"
source_rec="$(sed -n 's/^source_commit=//p' "$stamp" | head -1)"
if [ "$source_now" != unknown ] && [ "$source_rec" != "$source_now" ]; then
  report "agent-baseline-source" "$consumer was vendored from source_commit '$source_rec', this checkout is '$source_now'"
fi
if [ -n "$overlay" ] && [ "$mode_ok" -eq 1 ]; then
  # By tree, not commit: a consumer that hosts the overlay itself moves HEAD by committing
  # the stamp, and the overlay's content is what matters.
  overlay_now="$(git -C "$overlay" rev-parse "HEAD:./" 2>/dev/null || echo unknown)"
  overlay_rec="$(sed -n 's/^overlay_tree=//p' "$stamp" | head -1)"
  if [ "$overlay_now" != unknown ] && [ "$overlay_rec" != "$overlay_now" ]; then
    report "agent-baseline-source" "$consumer was vendored with overlay_tree '$overlay_rec', this overlay is '$overlay_now'"
  fi
fi

# 2) content drift, per profile asset
while IFS= read -r asset; do
  case "$asset" in
    CLAUDE.baseline.md|AGENTS.baseline.md)
      target="$consumer/${asset%.baseline.md}.md"   # CLAUDE.baseline.md -> CLAUDE.md
      if [ ! -f "$target" ]; then report "$asset" "missing $target"; continue; fi
      # Compose the expected block first: a composition failure (a missing overlay file) is a
      # tooling error, never drift that a deviation could suppress.
      expected="$(mktemp)"
      canon_block "$payload/$asset" > "$expected" || { rm -f "$expected"; echo "check: could not compose $asset" >&2; exit 2; }
      if ! diff -q <(extract_block "$target") "$expected" >/dev/null; then
        report "$asset" "marker block in $target differs from baseline $asset"
      fi
      rm -f "$expected"
      ;;
    *)
      got="$consumer/.claude/$asset"
      if [ ! -f "$got" ]; then report "$asset" "missing $got"; continue; fi
      diff -q "$payload/$asset" "$got" >/dev/null || report "$asset" "$got differs from baseline $asset"
      ;;
  esac
done <<< "$assets"

# 3) the allow block, when the consumer keeps an allow file
if [ -f "$consumer/.publish-allow.tsv" ]; then
  if ! diff -q \
      <(awk '/^# BEGIN baseline-agent allow/{f=1;next} /^# END baseline-agent allow/{f=0} f' "$consumer/.publish-allow.tsv") \
      <(sed "s/@VERSION@/${current_ver#agent-}/g" "$payload/publish-allow.tsv") >/dev/null \
      || ! grep -q '^# BEGIN baseline-agent allow' "$consumer/.publish-allow.tsv"; then
    report "publish-allow" "the baseline-agent allow block in $consumer/.publish-allow.tsv differs from baseline publish-allow.tsv"
  fi
fi

[ "$drift" -eq 0 ] && echo "OK: $consumer conforms to baseline-agent $current_ver (profile $profile)"
exit "$drift"
