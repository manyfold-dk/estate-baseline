#!/usr/bin/env bats

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/apps/portal/.mvn/wrapper" "$TMP/docs/adr"
  # A fixture, not the live baseline.json: the tests exercise the checker, and the live file
  # is checked by the conformance workflow. Invented versions; none is a version in use.
  BASELINE="$TMP/baseline.json"
  printf '{"fields":{"maven.compiler.release":"25","maven.wrapper.version":"9.9.1"},"enforcement":{"policed":["maven.wrapper.version"],"inherited":["maven.compiler.release"]}}' > "$BASELINE"
  wrapper 9.9.1   # default to aligned wrapper; tests override as needed
}

teardown() { rm -rf "$TMP"; }

pom() {
  printf '<project><properties><maven.compiler.release>%s</maven.compiler.release></properties></project>' "$1" \
    > "$TMP/apps/portal/pom.xml"
}

wrapper() {
  printf 'distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/%s/apache-maven-%s-bin.zip\n' "$1" "$1" \
    > "$TMP/apps/portal/.mvn/wrapper/maven-wrapper.properties"
}

@test "aligned consumer passes" {
  pom 25
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 0 ]
}

@test "compiler-release drift fails and names the field" {
  pom 21
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"maven.compiler.release"* ]]
}

@test "maven-wrapper drift fails and names the field" {
  pom 25
  wrapper 9.9.0
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"maven.wrapper.version"* ]]
}

@test "drift with an accepted deviation ADR passes" {
  pom 26
  cat > "$TMP/docs/adr/0099-jdk26.md" <<'EOF'
---
status: accepted
field: maven.compiler.release
tenant-value: "26"
baseline-value: "25"
---
EOF
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 0 ]
}

@test "inherited consumer (pom omits maven.compiler.release) passes" {
  # The normal post-repoint state: the property is inherited from the parent and absent
  # from the app pom. The checker must skip it, not crash under set -euo pipefail.
  printf '<project><parent><artifactId>platform-parent</artifactId></parent></project>' \
    > "$TMP/apps/portal/pom.xml"
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 0 ]
}

@test "malformed baseline.json is a script error, not drift" {
  pom 25
  printf '{ "fields": {' > "$TMP/bad-baseline.json"   # truncated JSON -> jq fails
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$TMP/bad-baseline.json"
  [ "$status" -ne 0 ]
  [ "$status" -ne 3 ]
}

# --- workflow.action-pinning ---

@test "action-pinning: an unpinned uses -> drift naming the ref" {
  mkdir -p "$TMP/.github/workflows"
  printf 'permissions:\n  contents: read\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n' \
    > "$TMP/.github/workflows/x.yml"
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"workflow.action-pinning"* ]]
  [[ "$output" == *"actions/checkout@v4"* ]]
}

@test "action-pinning: 40-hex pin + local ./ + commented uses are clean" {
  mkdir -p "$TMP/.github/workflows"
  cat > "$TMP/.github/workflows/x.yml" <<'EOF'
permissions:
  contents: read
jobs:
  a:
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111 # v4
      - uses: ./.github/actions/local
      # - uses: actions/setup-node@v4
EOF
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 0 ]
}

@test "action-pinning: same-repo self-reference is exempt" {
  git init -q "$TMP/selfrepo"
  git -C "$TMP/selfrepo" remote add origin https://github.com/example-org/baseline.git
  mkdir -p "$TMP/selfrepo/.github/workflows"
  printf 'permissions:\n  contents: read\njobs:\n  a:\n    steps:\n      - uses: example-org/baseline/.github/actions/foo@v1\n' \
    > "$TMP/selfrepo/.github/workflows/x.yml"
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP/selfrepo" "$BASELINE"
  [ "$status" -eq 0 ]
}

# --- workflow.permissions ---

@test "permissions: missing top-level permissions -> drift" {
  mkdir -p "$TMP/.github/workflows"
  printf 'jobs:\n  a:\n    steps:\n      - uses: foo/bar@1111111111111111111111111111111111111111 # v1\n' \
    > "$TMP/.github/workflows/x.yml"
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"workflow.permissions"* ]]
}

# --- manifest.image-digest ---

@test "image-digest: workload with a floating tag -> drift" {
  printf 'kind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - image: foo:1.2\n' \
    > "$TMP/dep.yaml"
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"manifest.image-digest"* ]]
}

@test "image-digest: digest-pinned workload + non-workload image are clean" {
  printf 'kind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - image: foo@sha256:deadbeef\n' \
    > "$TMP/dep.yaml"
  printf 'kind: ConfigMap\ndata:\n  image: not-a-workload:latest\n' > "$TMP/cm.yaml"
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 0 ]
}

# --- manifest.pvc-backup-annotation ---

@test "pvc-backup: PVC-bearing manifest without the annotation -> drift" {
  printf 'kind: StatefulSet\nspec:\n  volumeClaimTemplates:\n    - metadata: { name: data }\n' \
    > "$TMP/sts.yaml"
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"manifest.pvc-backup-annotation"* ]]
}

@test "pvc-backup: PVC with the velero annotation is clean" {
  cat > "$TMP/sts.yaml" <<'EOF'
kind: StatefulSet
spec:
  template:
    metadata:
      annotations:
        backup.velero.io/backup-volumes: data
  volumeClaimTemplates:
    - metadata: { name: data }
EOF
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 0 ]
}

@test "new rules: an accepted deviation ADR (field = rule id) suppresses the finding" {
  printf 'kind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - image: foo:1.2\n' \
    > "$TMP/dep.yaml"
  cat > "$TMP/docs/adr/0100-img.md" <<'EOF'
---
status: accepted
field: manifest.image-digest
---
EOF
  run "$BATS_TEST_DIRNAME/check.sh" "$TMP" "$BASELINE"
  [ "$status" -eq 0 ]
}
