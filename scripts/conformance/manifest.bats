#!/usr/bin/env bats
# The example manifest against the schema's structure, the one invariant JSON Schema cannot
# express, and the checker. Invented values throughout; none is a version in use.

setup() {
  EXAMPLE="$BATS_TEST_DIRNAME/baseline.example.json"
  SCHEMA="$BATS_TEST_DIRNAME/baseline.schema.json"
}

@test "the example carries exactly the schema's required top-level keys" {
  run jq -e --slurpfile s "$SCHEMA" '(keys | sort) == ($s[0].required | sort)' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "every enforcement bucket the schema requires is present" {
  run jq -e --slurpfile s "$SCHEMA" \
    '(.enforcement | keys | sort) == ($s[0].properties.enforcement.required | sort)' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "every value in fields is a non-empty string" {
  run jq -e '[.fields[] | type == "string" and length > 0] | all' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "every bucket entry names a key of fields" {
  run jq -e '(.fields | keys) as $k
    | [.enforcement.policed[], .enforcement.inherited[], .enforcement.informational[]]
    | all(. as $f | $k | index($f))' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "each field sits in exactly one bucket" {
  run jq -e '[.enforcement.policed[], .enforcement.inherited[], .enforcement.informational[]] as $b
    | ($b | length) == ($b | unique | length) and ($b | sort) == (.fields | keys | sort)' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "every rule is one the schema knows" {
  run jq -e --slurpfile s "$SCHEMA" \
    '($s[0].properties.enforcement.properties.rules.items.enum) as $e | .enforcement.rules | all(. as $r | $e | index($r))' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "the checker passes a consumer aligned with the example" {
  c="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$c/apps/app/.mvn/wrapper"
  printf '<project><properties><maven.compiler.release>99</maven.compiler.release></properties></project>' > "$c/apps/app/pom.xml"
  printf 'distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/9.9.1/apache-maven-9.9.1-bin.zip\n' \
    > "$c/apps/app/.mvn/wrapper/maven-wrapper.properties"
  run "$BATS_TEST_DIRNAME/check.sh" "$c" "$EXAMPLE"
  [ "$status" -eq 0 ]
}
