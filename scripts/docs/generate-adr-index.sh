#!/usr/bin/env bash
# Usage: generate-adr-index.sh <repo-dir> [--check]
#
# Regenerates the | ADR | Title | Status | table between the markers
#   <!-- adr-index:begin -->  ...  <!-- adr-index:end -->
# in <repo-dir>/docs/adr/README.md, sourced from the ADR files themselves
# (docs/adr/[0-9]*.md) so titles/statuses are never hand-typed.
#
# Title  = first '# ' heading, with a leading 'ADR NNNN:' prefix stripped.
# Status = MADR frontmatter 'status:' if present, else the first non-empty line
#          under a '## Status' heading (both styles exist across the estate).
#
# --check: exit 3 if the index is stale (CI gate), 0 if current.
# Exit codes: 0 ok, 3 stale (--check), anything else = error (e.g. missing markers).
set -euo pipefail

repo="${1:?repo-dir required}"
mode="${2:-write}"
adr_dir="$repo/docs/adr"
readme="$adr_dir/README.md"
begin='<!-- adr-index:begin -->'
end='<!-- adr-index:end -->'

[ -f "$readme" ] || { echo "ERROR: $readme not found" >&2; exit 2; }
grep -qF "$begin" "$readme" || { echo "ERROR: missing marker '$begin' in $readme" >&2; exit 2; }
grep -qF "$end" "$readme" || { echo "ERROR: missing marker '$end' in $readme" >&2; exit 2; }

rows=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  num="${base%%-*}"
  title="$(grep -m1 '^# ' "$f" | sed -E 's/^#[[:space:]]+//; s/^ADR[[:space:]-]*[0-9]+:?[[:space:]]*//')"
  status="$(awk '/^status:[[:space:]]*/ { sub(/^status:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$f")"
  if [ -z "$status" ]; then
    status="$(awk '
      /^##[[:space:]]+Status/ { instatus=1; next }
      instatus && /^##[[:space:]]/ { exit }
      instatus && NF { print; exit }
    ' "$f" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  fi
  [ -n "$title" ] || title="$base"
  [ -n "$status" ] || status="(unknown)"
  rows="${rows}| ${num} | [${title}](${base}) | ${status} |"$'\n'
done < <(find "$adr_dir" -maxdepth 1 -name '[0-9]*.md' | sort)

table="| ADR | Title | Status |"$'\n'"|---|---|---|"$'\n'"${rows}"

tmptable="$(mktemp)"
printf '%s' "$table" > "$tmptable"
gen="$(awk -v begin="$begin" -v end="$end" -v tf="$tmptable" '
  index($0, begin) { print; while ((getline l < tf) > 0) print l; close(tf); skip=1; next }
  index($0, end)   { skip=0 }
  !skip { print }
' "$readme")"
rm -f "$tmptable"

if [ "$mode" = "--check" ]; then
  if printf '%s\n' "$gen" | diff -q - "$readme" >/dev/null 2>&1; then
    exit 0
  fi
  echo "ADR index is stale; run: generate-adr-index.sh $repo" >&2
  exit 3
fi

printf '%s\n' "$gen" > "$readme"
echo "Wrote ADR index to $readme"
