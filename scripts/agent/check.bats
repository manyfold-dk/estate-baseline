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
  # An invented designation list; the consumer pushes to an unlisted (private) repository.
  LIST="$(mktemp)"
  printf '# invented\nexample-org/public-thing\n' > "$LIST"
  git -C "$CONSUMER" remote add origin https://github.com/example-org/private-thing.git
}
teardown() { rm -rf "$CONSUMER" "$LIST"; }

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

overlay_dir() { # a scratch overlay checkout with one file, printed to stdout
  local d; d="$(mktemp -d)"
  printf '| Repo | Purpose |\n|---|---|\n| `example-umbrella` | The umbrella |\n' > "$d/working-across-repositories.md"
  git -C "$d" init -q && git -C "$d" add -A && git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q -m overlay
  echo "$d"
}
vendor_ov() { ( cd "$CONSUMER" && "$VENDOR" --profile "${2:-app}" --overlay "$1" --public-repos "$LIST" ); }
commit_all() { git -C "$CONSUMER" add -A && git -C "$CONSUMER" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "${1:-base}"; }

@test "vendor --overlay fills the placeholder and check --overlay conforms" {
  ov="$(overlay_dir)"
  vendor_ov "$ov"
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
  vendor_ov "$ov"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE.baseline.md"* ]]
  rm -rf "$ov"
}

@test "a missing overlay file is a tooling error, not a silent gap" {
  ov="$(mktemp -d)"; git -C "$ov" init -q
  run bash -c "cd '$CONSUMER' && '$VENDOR' --profile app --overlay '$ov' --public-repos '$LIST'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"overlay file missing"* ]]
  rm -rf "$ov"
}

@test "a consumer that hosts its own overlay does not drift by committing the stamp" {
  mkdir -p "$CONSUMER/estate"
  printf '| Repo | Purpose |\n|---|---|\n| `self` | This one |\n' > "$CONSUMER/estate/working-across-repositories.md"
  ( cd "$CONSUMER" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m base )
  vendor_ov "$CONSUMER/estate"
  ( cd "$CONSUMER" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m vendored )
  run "$CHECK" --overlay "$CONSUMER/estate" "$CONSUMER"
  [ "$status" -eq 0 ]
}

@test "an overlay file missing at check time is a tooling error, not drift" {
  ov="$(overlay_dir)"
  vendor_ov "$ov"
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

# --- designated public consumers ------------------------------------------------------
# A consumer the estate's list designates public never receives the overlay; vendor.sh
# refuses it before it writes anything, first vendor included.

refused_clean() { # $@ = vendor arguments; the consumer is committed first
  commit_all
  run bash -c "cd '$CONSUMER' && '$VENDOR' --profile app $*"
  [ "$status" -eq 2 ]
  [ -z "$(git -C "$CONSUMER" status --porcelain)" ]
  [ ! -e "$CONSUMER/.claude" ]
}

@test "--overlay without --public-repos is refused and writes nothing" {
  ov="$(overlay_dir)"
  refused_clean --overlay "'$ov'"
  [[ "$output" == *"--public-repos"* ]]
  rm -rf "$ov"
}

@test "--overlay into a consumer designated public is refused on its first vendor and writes nothing" {
  ov="$(overlay_dir)"
  git -C "$CONSUMER" remote set-url origin git@github.com:Example-Org/public-thing.git
  refused_clean --overlay "'$ov'" --public-repos "'$LIST'"
  [[ "$output" == *"designated public; vendor without --overlay"* ]]
  rm -rf "$ov"
}

@test "--overlay into a consumer that cannot be classified is refused and writes nothing" {
  ov="$(overlay_dir)"
  git -C "$CONSUMER" remote remove origin
  refused_clean --overlay "'$ov'" --public-repos "'$LIST'"
  [[ "$output" == *"cannot be classified"* ]]
  printf 'not a row\n' > "$LIST"
  git -C "$CONSUMER" remote add origin https://github.com/example-org/private-thing.git
  refused_clean --overlay "'$ov'" --public-repos "'$LIST'"
  rm -rf "$ov"
}

@test "an overlay outside a Git work tree is refused and writes nothing" {
  ov="$(mktemp -d)"
  printf 'x\n' > "$ov/working-across-repositories.md"
  refused_clean --overlay "'$ov'" --public-repos "'$LIST'"
  [[ "$output" == *"not in a Git work tree"* ]]
  rm -rf "$ov"
}

@test "without --overlay a designated public consumer vendors and checks clean" {
  git -C "$CONSUMER" remote set-url origin https://github.com/example-org/public-thing
  vendor app
  grep -q '^overlay_applied=false$' "$CONSUMER/.claude/.baseline-agent-version"
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
}

@test "the stamp records overlay_applied, and a check in the other mode is overlay drift, reported first" {
  ov="$(overlay_dir)"
  vendor_ov "$ov"
  grep -q '^overlay_applied=true$' "$CONSUMER/.claude/.baseline-agent-version"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "${lines[0]}" == *"DRIFT [agent-baseline-overlay]"* ]]
  vendor app
  run "$CHECK" --overlay "$ov" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "${lines[0]}" == *"DRIFT [agent-baseline-overlay]"* ]]
  rm -rf "$ov"
}

@test "mode inference covers all four stamp shapes" {
  vendor app
  stamp="$CONSUMER/.claude/.baseline-agent-version"
  # 1. overlay_applied recorded
  sed -i.bak 's/^overlay_applied=.*/overlay_applied=true/' "$stamp"
  run "$CHECK" "$CONSUMER"
  [[ "$output" == *"agent-baseline-overlay"* ]]
  # 2. no overlay_applied, overlay_tree a tree id: applied
  sed -i.bak '/^overlay_applied=/d; s/^overlay_tree=.*/overlay_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904/' "$stamp"
  run "$CHECK" "$CONSUMER"
  [[ "$output" == *"agent-baseline-overlay"* ]]
  # 3. overlay_tree none: not applied
  sed -i.bak 's/^overlay_tree=.*/overlay_tree=none/' "$stamp"
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
  # 4. neither field (a stamp older than the overlay fields): the values were inline, applied
  sed -i.bak '/^overlay_/d' "$stamp"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent-baseline-overlay"* ]]
}

@test "a deviation ADR does not suppress an overlay mode mismatch" {
  ov="$(overlay_dir)"
  vendor_ov "$ov"
  for f in agent-baseline-overlay CLAUDE.baseline.md AGENTS.baseline.md; do
    printf -- '---\nstatus: accepted\nfield: %s\n---\n' "$f" > "$CONSUMER/docs/adr/0097-$f.md"
  done
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT [agent-baseline-overlay]"* ]]
  rm -rf "$ov"
}

@test "the allow block is written, keeps the consumer's rows, is replaced on re-vendor, and drift is reported" {
  printf '# mine\nexact version\t9.9.1\n' > "$CONSUMER/.publish-allow.tsv"
  vendor app
  grep -q '^# BEGIN baseline-agent allow' "$CONSUMER/.publish-allow.tsv"
  grep -q '^exact version	9.9.1$' "$CONSUMER/.publish-allow.tsv"
  grep -q '^exact version	\*	.claude/.baseline-agent-version$' "$CONSUMER/.publish-allow.tsv"
  ! grep -q '@VERSION@' "$CONSUMER/.publish-allow.tsv" || false
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
  printf 'exact version\t9.9.0\n' > "$CONSUMER/row"
  sed -i.bak '/^# BEGIN baseline-agent allow/r '"$CONSUMER/row" "$CONSUMER/.publish-allow.tsv"; rm "$CONSUMER/row"
  run "$CHECK" "$CONSUMER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT [publish-allow]"* ]]
  vendor app
  [ "$(grep -c '^# BEGIN baseline-agent allow' "$CONSUMER/.publish-allow.tsv")" -eq 1 ]
  ! grep -q '9.9.0' "$CONSUMER/.publish-allow.tsv" || false
  grep -q '^exact version	9.9.1$' "$CONSUMER/.publish-allow.tsv"
  run "$CHECK" "$CONSUMER"
  [ "$status" -eq 0 ]
  # an allow file without the block drifts too
  printf '# mine\n' > "$CONSUMER/.publish-allow.tsv"
  run "$CHECK" "$CONSUMER"
  [[ "$output" == *"DRIFT [publish-allow]"* ]]
}

@test "without an allow file vendor creates none" {
  vendor app
  [ ! -e "$CONSUMER/.publish-allow.tsv" ]
}

@test "the payload's allow rows are complete: every profile vendored overlay-free passes the shape gate" {
  for t in gitleaks trufflehog jq python3; do command -v "$t" >/dev/null 2>&1 || skip "$t not installed"; done
  for prof in $(awk '/^profiles:/{p=1;next} p && /^  [A-Za-z]/{sub(/:.*/,""); gsub(/ /,""); print}' "$REPO/baseline-agent/profiles.yaml"); do
    rm -rf "$CONSUMER/.claude" "$CONSUMER/.agents"
    printf '# Test Consumer\n' > "$CONSUMER/CLAUDE.md"; printf '# AGENTS\n' > "$CONSUMER/AGENTS.md"
    : > "$CONSUMER/.publish-allow.tsv"
    vendor "$prof"
    run "$REPO/scripts/publish-check/publish-check.sh" "$CONSUMER" --names none --allow "$CONSUMER/.publish-allow.tsv"
    [ "$status" -eq 0 ] || { echo "profile $prof: $output"; false; }
  done
}
