#!/usr/bin/env bash
# designation.sh -- is this repository designated public?
#
# Usage: designation.sh --list FILE (--url URL | --dir CHECKOUT)
#
# Prints exactly `public` or `private` and exits 0. Anything else -- a usage error, an
# unreadable list, a malformed row, a checkout with no remote -- exits 2 with nothing on
# stdout. A caller treats exit 2 as "stop for this repository", never as `private`.
#
# The list is the estate's own (private) designation list: one row per repository, either
# `org/name` on GitHub or a full URL for anywhere else. Blank lines and `#` lines are skipped;
# whitespace and a carriage return around a row are trimmed. A row that is neither is
# malformed: exit 2, never a silent skip.
#
# --url classifies one URL. --dir classifies every push URL of every remote of a checkout:
# one designated URL makes the checkout `public`, because a checkout that can push to a
# public repository is treated as one.
#
# A URL on GitHub (https://, http://, ssh://git@ or the scp form git@; host exactly
# github.com, any letter case, optional www.) reduces to `org/name`, compared without regard
# to letter case. Any other URL, including a lookalike host, is its own key and compared
# exactly. Both sides lose one trailing `/` and then one trailing `.git`.

set -euo pipefail

usage() { echo "usage: designation.sh --list FILE (--url URL | --dir CHECKOUT)" >&2; exit 2; }
fail() { echo "designation: $*" >&2; exit 2; }

list="" url="" dir=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --list) list="$2" ;;
    --url) url="$2" ;;
    --dir) dir="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$list" ] || usage
{ [ -n "$url" ] && [ -z "$dir" ]; } || { [ -z "$url" ] && [ -n "$dir" ]; } || usage
[ -f "$list" ] && [ -r "$list" ] || fail "cannot read list $list"

shopt -s nocasematch
name_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

strip() { # $1 = URL or row; one trailing / then one trailing .git
  local s="$1"
  s="${s%/}"
  s="${s%.git}"
  printf '%s' "$s"
}

key() { # $1 = URL; prints its comparison key
  local u="$1" path=""
  if [[ "$u" =~ ^https?://([^/@]+@)?(www\.)?github\.com(:[0-9]+)?/(.+)$ ]]; then
    path="${BASH_REMATCH[4]}"
  elif [[ "$u" =~ ^ssh://git@(www\.)?github\.com(:[0-9]+)?/(.+)$ ]]; then
    path="${BASH_REMATCH[3]}"
  elif [[ "$u" =~ ^git@(www\.)?github\.com:(.+)$ ]]; then
    path="${BASH_REMATCH[2]}"
  fi
  path="$(strip "$path")"
  if [ -n "$path" ] && [[ "$path" =~ $name_re ]]; then
    printf 'github:%s' "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  else
    printf 'url:%s' "$(strip "$u")"
  fi
}

# The designated keys, one per row.
keys=()
while IFS= read -r row || [ -n "$row" ]; do
  row="${row//$'\r'/}"
  row="${row#"${row%%[![:space:]]*}"}"
  row="${row%"${row##*[![:space:]]}"}"
  [ -n "$row" ] || continue
  case "$row" in \#*) continue ;; esac
  if [[ "$row" =~ $name_re ]]; then
    keys+=("github:$(strip "$row" | tr '[:upper:]' '[:lower:]')")
  elif [[ "$row" =~ ^[a-z][a-z0-9+.-]*://[^[:space:]]+$ ]] \
      || [[ "$row" =~ ^[^[:space:]@/:]+@[^[:space:]/:]+:[^[:space:]]+$ ]] \
      || [[ "$row" =~ ^/[^[:space:]]+$ ]]; then
    keys+=("$(key "$row")")
  else
    fail "malformed row in $list: $row"
  fi
done < "$list"

designated() { # $1 = URL
  local k want
  k="$(key "$1")"
  for want in "${keys[@]+"${keys[@]}"}"; do
    [ "$k" = "$want" ] && return 0   # exact: a GitHub key is already lower case
  done
  return 1
}

urls=()
if [ -n "$url" ]; then
  urls=("$url")
else
  [ -d "$dir" ] || fail "not a directory: $dir"
  # git's repository-local variables (a hook exports GIT_DIR) would point -C elsewhere.
  # shellcheck disable=SC2046 # one variable name per word
  dgit() { (unset $(git rev-parse --local-env-vars); git -C "$dir" "$@"); }
  dgit rev-parse --git-dir >/dev/null 2>&1 || fail "not a git checkout: $dir"
  remotes="$(dgit remote)" || fail "cannot list the remotes of $dir"
  [ -n "$remotes" ] || fail "$dir has no remote; it cannot be classified"
  while IFS= read -r r; do
    got="$(dgit remote get-url --push --all "$r")" || fail "cannot read the push URL of remote $r in $dir"
    while IFS= read -r u; do [ -z "$u" ] || urls+=("$u"); done <<< "$got"
  done <<< "$remotes"
fi

verdict=private
for u in "${urls[@]}"; do
  [ -n "$u" ] || fail "empty URL"
  if designated "$u"; then verdict=public; fi
done
echo "$verdict"
