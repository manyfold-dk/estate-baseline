#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/generate-adr-index.sh"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/docs/adr"
  # MADR frontmatter style
  cat > "$R/docs/adr/0001-first.md" <<'EOF'
---
status: accepted
---
# ADR 0001: First Decision
EOF
  # '## Status' heading style
  cat > "$R/docs/adr/0002-second.md" <<'EOF'
# ADR 0002: Second Decision

## Status

Proposed
EOF
  # superseded
  cat > "$R/docs/adr/0003-third.md" <<'EOF'
---
status: superseded by ADR-0002
---
# ADR 0003: Third Decision
EOF
  cat > "$R/docs/adr/README.md" <<'EOF'
# ADRs

<!-- adr-index:begin -->
<!-- adr-index:end -->
EOF
}

@test "generation produces the expected table (titles + statuses from the files)" {
  run "$SCRIPT" "$R"
  [ "$status" -eq 0 ]
  grep -q '| 0001 | \[First Decision\](0001-first.md) | accepted |' "$R/docs/adr/README.md"
  grep -q '| 0002 | \[Second Decision\](0002-second.md) | Proposed |' "$R/docs/adr/README.md"
  grep -q '| 0003 | \[Third Decision\](0003-third.md) | superseded by ADR-0002 |' "$R/docs/adr/README.md"
}

@test "generation is idempotent (second run = no diff)" {
  "$SCRIPT" "$R"
  cp "$R/docs/adr/README.md" "$BATS_TEST_TMPDIR/first.md"
  "$SCRIPT" "$R"
  diff "$BATS_TEST_TMPDIR/first.md" "$R/docs/adr/README.md"
}

@test "--check exits 0 when current" {
  "$SCRIPT" "$R"
  run "$SCRIPT" "$R" --check
  [ "$status" -eq 0 ]
}

@test "--check exits 3 when stale (a title changed)" {
  "$SCRIPT" "$R"
  sed -i.bak 's/First Decision/First Decision Renamed/' "$R/docs/adr/0001-first.md"
  run "$SCRIPT" "$R" --check
  [ "$status" -eq 3 ]
}

@test "missing markers is an error (neither 0 nor 3)" {
  printf '# ADRs\n(no markers here)\n' > "$R/docs/adr/README.md"
  run "$SCRIPT" "$R"
  [ "$status" -ne 0 ]
  [ "$status" -ne 3 ]
}
