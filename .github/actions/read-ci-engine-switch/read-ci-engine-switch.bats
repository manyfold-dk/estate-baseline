#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/read-ci-engine-switch.sh"
  TMP="$BATS_TEST_TMPDIR"
}

@test "valid dual switch -> run+deploy blacksmith true" {
  printf 'CI_MODE=dual\nDEPLOY_ENGINE=blacksmith\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env" --name testapp
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_blacksmith=true"* ]]
  [[ "$output" == *"deploy_blacksmith=true"* ]]
}

@test "blacksmith mode, deploy none -> run true, deploy false" {
  printf 'CI_MODE=blacksmith\nDEPLOY_ENGINE=none\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_blacksmith=true"* ]]
  [[ "$output" == *"deploy_blacksmith=false"* ]]
}

@test "missing switch file -> hard error" {
  run "$SCRIPT" --env-file "$TMP/nope.env" --name testapp
  [ "$status" -ne 0 ]
  [[ "$output" == *"switch file not found"* ]]
}

@test "invalid CI_MODE -> hard error" {
  printf 'CI_MODE=bogus\nDEPLOY_ENGINE=none\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid CI_MODE"* ]]
}

@test "inconsistent switch (deploy blacksmith but tekton-only) -> hard error" {
  printf 'CI_MODE=tekton\nDEPLOY_ENGINE=blacksmith\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires CI_MODE=dual or blacksmith"* ]]
}

@test "force-run overrides tekton-only mode" {
  printf 'CI_MODE=tekton\nDEPLOY_ENGINE=tekton\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env" --force-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_blacksmith=true"* ]]
}

@test "force-deploy overrides to blacksmith deploy" {
  printf 'CI_MODE=tekton\nDEPLOY_ENGINE=tekton\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env" --force-deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy_blacksmith=true"* ]]
  [[ "$output" == *"deploy_tekton=false"* ]]
}

@test "github-output mode writes keys to GITHUB_OUTPUT" {
  printf 'CI_MODE=dual\nDEPLOY_ENGINE=blacksmith\n' > "$TMP/switch.env"
  GITHUB_OUTPUT="$TMP/out.txt" run "$SCRIPT" --env-file "$TMP/switch.env" --github-output --quiet
  [ "$status" -eq 0 ]
  grep -q '^run_blacksmith=true$' "$TMP/out.txt"
  grep -q '^deploy_blacksmith=true$' "$TMP/out.txt"
}
