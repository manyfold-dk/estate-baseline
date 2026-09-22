#!/usr/bin/env bash
# secret-scan.sh -- run gitleaks over the commits an event introduced.
#
# The range, not the whole history: a pull request is judged on what it adds, so a finding
# from years ago cannot turn every later build red. `--full-history` is for a scheduled
# sweep. When a range cannot be worked out, the scan covers everything rather than nothing.
#
# Usage: secret-scan.sh [--event NAME] [--base SHA] [--head SHA] [--before SHA]
#                       [--full-history] [--print-range]
#   --event        pull_request | push | anything else
#   --base/--head  pull_request: the base and head commits
#   --before/--head push: the previous and new tip
#   --print-range  print the git log range and exit (tests; needs no gitleaks)
#
# Needs the full history in the checkout (actions/checkout fetch-depth: 0).
# Exit 0: clean. Exit 1: gitleaks found something, values redacted. Exit 2: could not run.

set -euo pipefail

event="" base="" head="" before="" full=false print=false
while [ $# -gt 0 ]; do
  case "$1" in
    --event) event="${2:-}"; shift ;;
    --base) base="${2:-}"; shift ;;
    --head) head="${2:-}"; shift ;;
    --before) before="${2:-}"; shift ;;
    --full-history) full=true ;;
    --print-range) print=true ;;
    *) echo "secret-scan: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

is_commit() { # a full hex object id that names a commit in this checkout
  [[ "$1" =~ ^[0-9a-f]{40,64}$ ]] && [[ ! "$1" =~ ^0+$ ]] \
    && git cat-file -e "$1^{commit}" 2>/dev/null
}

range="--all"
if [ "$full" = false ]; then
  case "$event" in
    pull_request|pull_request_target)
      if is_commit "$base" && is_commit "$head"; then range="$base..$head"; fi ;;
    push)
      # A new branch or a force push has no usable previous tip.
      if is_commit "$before" && is_commit "$head"; then range="$before..$head"; fi ;;
  esac
fi

if [ "$print" = true ]; then echo "$range"; exit 0; fi

command -v gitleaks >/dev/null 2>&1 || { echo "secret-scan: gitleaks not installed; nothing was scanned" >&2; exit 2; }
echo "secret-scan: git log range: $range"
if ! gitleaks git --redact --no-banner --verbose --log-level warn --log-opts="$range" .; then
  echo "secret-scan: gitleaks found a credential (values redacted above)." >&2
  echo "secret-scan: rotate it if it was real, then remove it from the branch history;" >&2
  echo "secret-scan: a false positive goes in .gitleaksignore by fingerprint." >&2
  exit 1
fi
echo "secret-scan: clean"
