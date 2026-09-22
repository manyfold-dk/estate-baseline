#!/usr/bin/env bats
# Round-trips vendor.sh -> check.sh against a synthetic consumer, then forces each drift kind.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VENDOR="$REPO/scripts/agent/vendor.sh"
  CHECK="$REPO/scripts/agent/check.sh"
  CONSUMER="$(mktemp -d)"
  ( cd "$CONSUMER" && git init -q )            # check.sh greps docs/adr; consumer just needs to be a dir
  printf '# Test Consumer\n' > "$CONSUMER/CLAUDE.md"
  printf '# AGENTS\n' > "$CONSUMER/AGENTS.md"
  mkdir -p "$CONSUMER/docs/adr"
}
teardown() { rm -rf "$CONSUMER"; }

vendor() { ( cd "$CONSUMER" && "$VENDOR" --profile "${1:-app}" ); }

@test "vendor then check: a freshly-vendored consumer conforms" {
  vendor app
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"conforms"* ]]
}

@test "version lag is reported and names agent-baseline-version" {
  vendor app
  sed -i.bak 's/^version=.*/version=agent-0.0.1/' "$CONSUMER/.claude/.baseline-agent-version"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent-baseline-version"* ]]
}

@test "content drift in a vendored rule is reported and names the asset" {
  vendor app
  printf '\nlocal edit\n' >> "$CONSUMER/.claude/rules/git-workflow.md"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rules/git-workflow.md"* ]]
}

@test "marker-block drift is reported" {
  vendor app
  # corrupt the block body
  perl -0pi -e 's/(<!-- BEGIN baseline-agent[^\n]*\n)/$1CORRUPT\n/' "$CONSUMER/CLAUDE.md"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE.baseline.md"* ]]
}

@test "an accepted deviation ADR suppresses the drift" {
  vendor app
  printf '\nlocal edit\n' >> "$CONSUMER/.claude/rules/git-workflow.md"
  cat > "$CONSUMER/docs/adr/0099-keep-local-git-workflow.md" <<'EOF'
---
status: accepted
field: rules/git-workflow.md
---
EOF
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
}

@test "never-vendored consumer fails" {
  run "$CHECK" "$CONSUMER"   # nothing vendored yet
  [ "$status" -ne 0 ]
  [[ "$output" == *"never vendored"* ]]
}

@test "vendor rejects an unknown profile (no stamp written)" {
  run bash -c "cd '$CONSUMER' && '$VENDOR' --profile bogus"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown or empty profile"* ]]
  [ ! -f "$CONSUMER/.claude/.baseline-agent-version" ]
}

@test "check rejects a stamp recording an unknown profile" {
  vendor app
  sed -i.bak 's/^profile=.*/profile=bogus/' "$CONSUMER/.claude/.baseline-agent-version"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown/empty profile"* ]]
}

@test "source policy blocks equal canonical POLICY and runtime adapters differ" {
  for runtime in AGENTS CLAUDE; do
    run bash -c "diff '$REPO/baseline-agent/POLICY.md' <(sed -n '/<!-- BEGIN policy -->/,/<!-- END policy -->/p' '$REPO/baseline-agent/$runtime.baseline.md' | sed '1d;\$d')"
    [ "$status" -eq 0 ]
  done
  ! cmp -s "$REPO/baseline-agent/AGENTS.baseline.md" "$REPO/baseline-agent/CLAUDE.baseline.md"
}

@test "docs ships review helper and all referenced skill resources" {
  vendor docs
  [ -f "$CONSUMER/.claude/helpers/review_scope.py" ]
  [ -f "$CONSUMER/.claude/skills/archive-plan/references/inspection.md" ]
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
}

@test "missing shipped reference cannot be hidden by a content deviation" {
  vendor docs
  rm "$CONSUMER/.claude/references/documentation/lifecycle.md"
  cat > "$CONSUMER/docs/adr/0098-reference.md" <<'EOF'
---
status: accepted
field: references/documentation/lifecycle.md
---
EOF
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONTRACT"* ]]
}

@test "explicit repo discovery stays local and repeated vendor preserves mode" {
  (cd "$CONSUMER" && "$VENDOR" --profile docs --codex-discovery repo)
  [ "$(readlink "$CONSUMER/.agents/skills/plan-design")" = '../../.claude/skills/plan-design' ]
  vendor docs
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
  rm "$CONSUMER/.agents/skills/plan-design"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
}

# --- estate overlay -------------------------------------------------------------------
# The payload carries a placeholder where the estate's own values go; the private overlay
# fills it at vendor time and check composes the same way.

overlay_dir() { # a scratch overlay with one file, printed to stdout
  local d; d="$(mktemp -d)"
  printf '| Repo | Purpose |\n|---|---|\n| `example-umbrella` | The umbrella |\n' > "$d/working-across-repositories.md"
  echo "$d"
}

@test "vendor --overlay fills the placeholder and check --overlay conforms" {
  ov="$(overlay_dir)"
  ( cd "$CONSUMER" && "$VENDOR" --profile app --overlay "$ov" )
  ! grep -q 'working-across-repositories-overlay' "$CONSUMER/CLAUDE.md" || false
  grep -q 'example-umbrella' "$CONSUMER/CLAUDE.md"
  grep -q 'example-umbrella' "$CONSUMER/AGENTS.md"
  grep -q '^overlay_commit=' "$CONSUMER/.claude/.baseline-agent-version"
  run "$CHECK" --overlay "$ov" "$CONSUMER"
  [ "$status" -eq 0 ]
  rm -rf "$ov"
}

@test "without --overlay the placeholder stays and the stamp says so" {
  vendor app
  grep -q '^<!-- working-across-repositories-overlay -->$' "$CONSUMER/CLAUDE.md"
  grep -q '^overlay_commit=none$' "$CONSUMER/.claude/.baseline-agent-version"
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
}

@test "check without the overlay a consumer was vendored with reports the block as drift" {
  ov="$(overlay_dir)"
  ( cd "$CONSUMER" && "$VENDOR" --profile app --overlay "$ov" )
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE.baseline.md"* ]]
  rm -rf "$ov"
}

@test "a missing overlay file is a tooling error, not a silent gap" {
  ov="$(mktemp -d)"
  run bash -c "cd '$CONSUMER' && '$VENDOR' --profile app --overlay '$ov'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"overlay file missing"* ]]
  rm -rf "$ov"
}

@test "a consumer that hosts its own overlay does not drift by committing the stamp" {
  mkdir -p "$CONSUMER/estate"
  printf '| Repo | Purpose |\n|---|---|\n| `self` | This one |\n' > "$CONSUMER/estate/working-across-repositories.md"
  ( cd "$CONSUMER" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m base )
  ( cd "$CONSUMER" && "$VENDOR" --profile app --overlay "$CONSUMER/estate" )
  ( cd "$CONSUMER" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m vendored )
  run "$CHECK" --overlay "$CONSUMER/estate" "$CONSUMER"
  [ "$status" -eq 0 ]
}

@test "an overlay file missing at check time is a tooling error, not drift" {
  ov="$(overlay_dir)"
  ( cd "$CONSUMER" && "$VENDOR" --profile app --overlay "$ov" )
  rm "$ov/working-across-repositories.md"
  run "$CHECK" --overlay "$ov" "$CONSUMER"
  [ "$status" -eq 2 ]
  rm -rf "$ov"
}

@test "PUBLISH-02 is in the vendored policy" {
  vendor app
  grep -q 'PUBLISH-02' "$CONSUMER/CLAUDE.md"
  grep -q 'PUBLISH-02' "$CONSUMER/AGENTS.md"
}

@test "the stamp records full commit ids, and check reports a consumer vendored from another commit" {
  vendor app
  src="$(sed -n 's/^source_commit=//p' "$CONSUMER/.claude/.baseline-agent-version")"
  [ "${#src}" -ge 40 ] || [ "$src" = unknown ]
  grep -q '^source_dirty=' "$CONSUMER/.claude/.baseline-agent-version"
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
  sed -i.bak 's/^source_commit=.*/source_commit=0000000000000000000000000000000000000000/' "$CONSUMER/.claude/.baseline-agent-version"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent-baseline-source"* ]]
}
