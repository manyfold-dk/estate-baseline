#!/usr/bin/env bats
# Nothing token-shaped is stored here: each test generates its own, so this file passes the
# scan it tests.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/secret-scan.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"; cd "$REPO"
  git init -q -b main
  git config user.name test; git config user.email test@example.invalid
  git config core.hooksPath /dev/null
  echo one > a.txt; git add a.txt; git commit -q -m one
  BASE="$(git rev-parse HEAD)"
}

commit_token() { # commits a GitHub-PAT-shaped string; prints its random part
  local body
  body="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
  printf 'token = "ghp_%s"\n' "$body" > config.txt
  git add config.txt; git commit -q -m "add config"
  printf '%s' "$body"
}

commit_clean() { echo "$1" >> a.txt; git add a.txt; git commit -q -m "$1"; }

need_gitleaks() { command -v gitleaks >/dev/null 2>&1 || skip "gitleaks not installed"; }

@test "pull_request: the range is base..head" {
  commit_clean two; HEAD_SHA="$(git rev-parse HEAD)"
  run "$SCRIPT" --event pull_request --base "$BASE" --head "$HEAD_SHA" --print-range
  [ "$status" -eq 0 ]
  [ "$output" = "$BASE..$HEAD_SHA" ]
}

@test "push: the range is before..head" {
  commit_clean two; HEAD_SHA="$(git rev-parse HEAD)"
  run "$SCRIPT" --event push --before "$BASE" --head "$HEAD_SHA" --print-range
  [ "$output" = "$BASE..$HEAD_SHA" ]
}

@test "push of a new branch (all-zero before) scans everything rather than nothing" {
  run "$SCRIPT" --event push --before 0000000000000000000000000000000000000000 --head "$BASE" --print-range
  [ "$output" = "--all" ]
}

@test "a before commit this checkout does not have (force push) scans everything" {
  run "$SCRIPT" --event push --before 1111111111111111111111111111111111111111 --head "$BASE" --print-range
  [ "$output" = "--all" ]
}

@test "a value that is not an object id never reaches git log" {
  run "$SCRIPT" --event pull_request --base "--output=/tmp/x" --head "$BASE" --print-range
  [ "$output" = "--all" ]
}

@test "schedule, workflow_dispatch and --full-history scan everything" {
  run "$SCRIPT" --event schedule --print-range
  [ "$output" = "--all" ]
  run "$SCRIPT" --event pull_request --base "$BASE" --head "$BASE" --full-history --print-range
  [ "$output" = "--all" ]
}

@test "a pull request that adds a token-shaped string fails, value redacted" {
  need_gitleaks
  body="$(commit_token)"
  run "$SCRIPT" --event pull_request --base "$BASE" --head "$(git rev-parse HEAD)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config.txt"* ]]
  [[ "$output" != *"$body"* ]]
}

@test "a clean pull request passes even when an older commit holds a finding" {
  need_gitleaks
  commit_token >/dev/null; OLD="$(git rev-parse HEAD)"
  commit_clean three
  run "$SCRIPT" --event pull_request --base "$OLD" --head "$(git rev-parse HEAD)"
  [ "$status" -eq 0 ]
  run "$SCRIPT" --event schedule
  [ "$status" -eq 1 ]
}

@test "removing the string in a later commit of the same pull request still fails" {
  need_gitleaks
  commit_token >/dev/null
  git rm -q config.txt; git commit -q -m "remove config"
  run "$SCRIPT" --event pull_request --base "$BASE" --head "$(git rev-parse HEAD)"
  [ "$status" -eq 1 ]
}

@test "an unknown argument is a usage error" {
  run "$SCRIPT" --nope
  [ "$status" -eq 2 ]
}
