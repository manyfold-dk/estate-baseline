#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/read-ci-engine-switch.sh"
  TMP="$BATS_TEST_TMPDIR"
}

@test "blacksmith mode, deploy blacksmith -> run+deploy blacksmith true" {
  printf 'CI_MODE=blacksmith\nDEPLOY_ENGINE=blacksmith\n' > "$TMP/switch.env"
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

@test "invalid DEPLOY_ENGINE -> hard error" {
  printf 'CI_MODE=blacksmith\nDEPLOY_ENGINE=bogus\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid DEPLOY_ENGINE"* ]]
}

@test "retired CI_MODE values tekton and dual are refused with the retirement date" {
  for mode in tekton dual; do
    printf 'CI_MODE=%s\nDEPLOY_ENGINE=none\n' "$mode" > "$TMP/switch.env"
    run "$SCRIPT" --env-file "$TMP/switch.env" --name testapp
    [ "$status" -ne 0 ]
    [[ "$output" == *"CI_MODE '$mode' for testapp: Tekton was retired on 2026-09-27"* ]]
  done
}

@test "retired DEPLOY_ENGINE tekton is refused with the retirement date" {
  printf 'CI_MODE=blacksmith\nDEPLOY_ENGINE=tekton\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env" --name testapp
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEPLOY_ENGINE 'tekton' for testapp: Tekton was retired on 2026-09-27"* ]]
}

@test "force flags do not bypass a retired value" {
  printf 'CI_MODE=tekton\nDEPLOY_ENGINE=tekton\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env" --force-run --force-deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tekton was retired"* ]]
}

@test "force-run is accepted and leaves deploy alone" {
  printf 'CI_MODE=blacksmith\nDEPLOY_ENGINE=none\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env" --force-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_blacksmith=true"* ]]
  [[ "$output" == *"deploy_blacksmith=false"* ]]
}

@test "force-deploy overrides deploy none" {
  printf 'CI_MODE=blacksmith\nDEPLOY_ENGINE=none\n' > "$TMP/switch.env"
  run "$SCRIPT" --env-file "$TMP/switch.env" --force-deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy_blacksmith=true"* ]]
}

@test "github-output mode writes exactly the four keys" {
  printf 'CI_MODE=blacksmith\nDEPLOY_ENGINE=blacksmith\n' > "$TMP/switch.env"
  GITHUB_OUTPUT="$TMP/out.txt" run "$SCRIPT" --env-file "$TMP/switch.env" --github-output --quiet
  [ "$status" -eq 0 ]
  [ "$(cut -d= -f1 "$TMP/out.txt" | tr '\n' ' ')" = "run_blacksmith deploy_blacksmith ci_mode deploy_engine " ]
  grep -q '^run_blacksmith=true$' "$TMP/out.txt"
  grep -q '^deploy_blacksmith=true$' "$TMP/out.txt"
}
