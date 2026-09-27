#!/usr/bin/env bash
# Usage (run from INSIDE a consumer repo):
#   /path/to/baseline/scripts/agent/vendor.sh --profile <app|docs> [--overlay <dir> --public-repos <list>]
#
# Copies the profile's rules/skills/agents into ./.claude/ (generic SKILL.md only for the
# split skills -- never touches environment.md), replaces the marker-delimited block in
# ./CLAUDE.md and ./AGENTS.md with the baseline house-rules body, and writes
# ./.claude/.baseline-agent-version. The consumer then commits.
#
# --overlay <dir>: the estate's private values. Each "<!-- name-overlay -->" line in a
# house-rules body is replaced by <dir>/<name>.md. Without it the placeholders stay, which
# is right for a consumer outside any estate and for one the estate designates public.
# --overlay needs --public-repos <list>, the estate's designation list: before anything is
# written, scripts/publish-check/designation.sh classifies the consumer's push URLs, and
# only a `private` consumer receives the overlay. A `public` one, or one that cannot be
# classified, is refused. The overlay must sit in a Git work tree, so the stamp can name it.
#
# When ./.publish-allow.tsv exists, the rows the vendored files need (baseline-agent/
# publish-allow.tsv) are written into it between "# BEGIN baseline-agent allow" and
# "# END baseline-agent allow". Rows outside that block are the consumer's. The file is
# never created: its presence is the consumer's opt-in.
set -euo pipefail

profile=""
discovery=""
overlay=""
public_repos=""
while [ $# -gt 0 ]; do
  case "$1" in
    --codex-discovery) discovery="${2:?--codex-discovery needs legacy or repo}"; shift 2;;
    --profile) profile="${2:?--profile needs a value}"; shift 2;;
    --overlay) overlay="$(cd "${2:?--overlay needs a directory}" && pwd)"; shift 2;;
    --public-repos) public_repos="${2:?--public-repos needs a file}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$profile" ] || { echo "usage: vendor.sh --profile <name>" >&2; exit 2; }

script_dir="$(cd "$(dirname "$0")" && pwd)"
payload="$(cd "$script_dir/../../baseline-agent" && pwd)"
profiles="$payload/profiles.yaml"
version="$(cat "$payload/VERSION")"
consumer="$(pwd)"

# The leak direction is refused here, before any write: the estate's values go only into a
# consumer the estate's own list does not designate public, first vendor included.
if [ -n "$overlay" ]; then
  [ -n "$public_repos" ] || { echo "vendor: --overlay needs --public-repos <list>: a consumer is classified before it receives the estate's values" >&2; exit 2; }
  git -C "$overlay" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "vendor: overlay $overlay is not in a Git work tree; refused" >&2; exit 2; }
  designation="$("$script_dir/../publish-check/designation.sh" --list "$public_repos" --dir "$consumer")" \
    || { echo "vendor: $consumer cannot be classified against $public_repos; refused, nothing written" >&2; exit 2; }
  case "$designation" in
    private) ;;
    public) echo "vendor: $consumer is designated public; vendor without --overlay. Nothing written." >&2; exit 2 ;;
    *) echo "vendor: unexpected classification '$designation'; refused" >&2; exit 2 ;;
  esac
fi
if [ -z "$discovery" ]; then
  discovery="$(sed -n 's/^codex_discovery=//p' "$consumer/.claude/.baseline-agent-version" 2>/dev/null || true)"
  discovery="${discovery:-legacy}"
fi
case "$discovery" in legacy|repo) ;; *) echo "invalid codex discovery: $discovery" >&2; exit 2;; esac
python3 "$script_dir/contracts.py" --payload "$payload"

profile_assets() { # $1 = profile name
  awk -v prof="$1" '
    $0 ~ "^  " prof ":[[:space:]]*$" {inp=1; next}
    inp && /^  [A-Za-z]/ {inp=0}
    inp && /^    - / {sub(/^    - /,""); sub(/[[:space:]]*#.*/,""); gsub(/[[:space:]]+$/,""); if($0!="") print}
  ' "$profiles"
}

# Canonical marker-block body: the baseline file from its first "## " heading to EOF, with
# every overlay placeholder filled when --overlay is given.
canon_block() {
  awk -v dir="$overlay" '
    /^## /{f=1}
    f && dir != "" && match($0, /^<!-- [a-z-]+-overlay -->$/) {
      name=$0; sub(/^<!-- /,"",name); sub(/-overlay -->$/,"",name)
      file=dir "/" name ".md"; n=0
      while ((getline l < file) > 0) { print l; n++ }
      close(file)
      if (n == 0) { print "vendor: overlay file missing or empty: " file > "/dev/stderr"; exit 2 }
      next
    }
    f' "$1"
}

inject_block() { # $1 = consumer markdown file, $2 = baseline source (CLAUDE.baseline.md / AGENTS.baseline.md)
  local file="$1" src="$2"
  local begin="<!-- BEGIN baseline-agent (vendored from baseline-agent @ ${version}; do not edit) -->"
  local end="<!-- END baseline-agent -->"
  local bodyfile tmp; bodyfile="$(mktemp)"; tmp="$(mktemp)"
  canon_block "$src" > "$bodyfile"   # body in a file -> robust against newlines/backslashes
  if [ -f "$file" ] && grep -q '<!-- BEGIN baseline-agent' "$file"; then
    awk -v b="$begin" -v e="$end" -v bf="$bodyfile" '
      /<!-- BEGIN baseline-agent/ { print b; while ((getline l < bf) > 0) print l; close(bf); skip=1; next }
      /<!-- END baseline-agent/   { print e; skip=0; next }
      skip!=1 { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    # No markers yet: append a fresh block at EOF (the consumer can reposition once).
    { [ -f "$file" ] && cat "$file"; printf '\n%s\n' "$begin"; cat "$bodyfile"; printf '%s\n' "$end"; } > "$tmp"
    mv "$tmp" "$file"
    echo "note: appended a new baseline-agent block at the end of $file -- reposition the markers if you want it elsewhere; vendor only replaces between them afterwards." >&2
  fi
  rm -f "$bodyfile"
}

# The allow rows the vendored files need, the marker version filled in (publish-allow.tsv).
allow_rows() { sed "s/@VERSION@/${version#agent-}/g" "$payload/publish-allow.tsv"; }

inject_allow() { # $1 = the consumer's .publish-allow.tsv
  local file="$1" tmp rows
  tmp="$(mktemp)"; rows="$(mktemp)"
  allow_rows > "$rows"
  if grep -q '^# BEGIN baseline-agent allow' "$file"; then
    awk -v rf="$rows" '
      /^# BEGIN baseline-agent allow/ { print; while ((getline l < rf) > 0) print l; close(rf); skip=1; next }
      /^# END baseline-agent allow/   { print; skip=0; next }
      skip!=1 { print }
    ' "$file" > "$tmp"
  else
    { cat "$file"; [ -z "$(tail -c1 "$file")" ] || echo
      echo "# BEGIN baseline-agent allow (vendored; do not edit)"; cat "$rows"; echo "# END baseline-agent allow"; } > "$tmp"
  fi
  cat "$tmp" > "$file"
  rm -f "$tmp" "$rows"
}

assets="$(profile_assets "$profile")"
[ -n "$assets" ] || { echo "error: unknown or empty profile '$profile' (see baseline-agent/profiles.yaml)" >&2; exit 2; }

# Refuse all existing customized/wrong discovery entries before copying any payload.
python3 "$script_dir/contracts.py" --payload "$payload" --consumer "$consumer" --profile "$profile" --discovery "$discovery" --preflight-discovery
mkdir -p "$consumer/.claude"

while IFS= read -r asset; do
  case "$asset" in
    CLAUDE.baseline.md) inject_block "$consumer/CLAUDE.md" "$payload/$asset" ;;
    AGENTS.baseline.md) inject_block "$consumer/AGENTS.md" "$payload/$asset" ;;
    *)
      dest="$consumer/.claude/$asset"
      mkdir -p "$(dirname "$dest")"
      cp "$payload/$asset" "$dest"
      ;;
  esac
done <<< "$assets"

if [ "$discovery" = repo ]; then
  # Caller owns the runtime activation gate. All links resolve inside this consumer.
  while IFS= read -r name; do
    link="$consumer/.agents/skills/$name"
    target="../../.claude/skills/$name"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
      mkdir -p "$(dirname "$link")"
      ln -s "$target" "$link"
    fi
  done < <(printf '%s\n' "$assets" | awk -F/ '$1=="skills" {print $2}' | sort -u)
fi

if [ -f "$consumer/.publish-allow.tsv" ]; then inject_allow "$consumer/.publish-allow.tsv"; fi

python3 "$script_dir/contracts.py" --payload "$payload" --consumer "$consumer" --profile "$profile" --discovery "$discovery"
cat > "$consumer/.claude/.baseline-agent-version" <<EOF
version=$version
profile=$profile
codex_discovery=$discovery
source_commit=$(git -C "$payload" rev-parse HEAD 2>/dev/null || echo unknown)
source_dirty=$([ -n "$(git -C "$payload" status --porcelain -- . 2>/dev/null)" ] && echo true || echo false)
overlay_commit=$([ -n "$overlay" ] && git -C "$overlay" rev-parse HEAD 2>/dev/null || echo none)
overlay_tree=$([ -n "$overlay" ] && git -C "$overlay" rev-parse "HEAD:./" 2>/dev/null || echo none)
overlay_applied=$([ -n "$overlay" ] && echo true || echo false)
overlay_dirty=$([ -n "$overlay" ] && [ -n "$(git -C "$overlay" status --porcelain -- . 2>/dev/null)" ] && echo true || echo false)
vendored_at=$(date -u +%FT%TZ)
EOF

echo "vendored profile '$profile' ($version) into $consumer"
