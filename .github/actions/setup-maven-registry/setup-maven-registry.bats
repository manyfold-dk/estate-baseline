#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/setup-maven-registry.sh"
  OUT="$BATS_TEST_TMPDIR/m2/settings.xml"
  export MAVEN_REGISTRY_TOKEN="test-token-value"
}

@test "writes server, profile and active profile with one id" {
  run "$SCRIPT" --url https://maven.example.test/owner/repo --username ci --out "$OUT"
  [ "$status" -eq 0 ]
  grep -q '<id>github</id>' "$OUT"
  grep -q '<password>test-token-value</password>' "$OUT"
  grep -q '<url>https://maven.example.test/owner/repo</url>' "$OUT"
  grep -q '<activeProfile>github-registry</activeProfile>' "$OUT"
  grep -q '<id>github-registry</id>' "$OUT"
}

@test "the token never appears in the output" {
  run "$SCRIPT" --url https://maven.example.test/r --username ci --out "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"test-token-value"* ]]
}

@test "file is readable by its owner only" {
  run "$SCRIPT" --url https://maven.example.test/r --username ci --out "$OUT"
  [ "$status" -eq 0 ]
  perms=$(ls -l "$OUT" | cut -c1-10)
  [ "$perms" = "-rw-------" ]
}

@test "a custom server id names the server, the repository and the profile" {
  run "$SCRIPT" --url https://maven.example.test/r --username ci --server-id internal --out "$OUT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '<id>internal</id>' "$OUT")" -eq 2 ]
  grep -q '<activeProfile>internal-registry</activeProfile>' "$OUT"
}

@test "values are XML-escaped" {
  MAVEN_REGISTRY_TOKEN='a&b<c>"d'"'" run "$SCRIPT" --url 'https://maven.example.test/r?x=1&y=2' --username 'c&i' --out "$OUT"
  [ "$status" -eq 0 ]
  grep -q '<password>a&amp;b&lt;c&gt;&quot;d&apos;</password>' "$OUT"
  grep -q '<url>https://maven.example.test/r?x=1&amp;y=2</url>' "$OUT"
  grep -q '<username>c&amp;i</username>' "$OUT"
}

@test "a plain http URL is refused" {
  run "$SCRIPT" --url http://maven.example.test/r --username ci --out "$OUT"
  [ "$status" -eq 2 ]
  [ ! -e "$OUT" ]
}

@test "an empty token is refused" {
  MAVEN_REGISTRY_TOKEN="" run "$SCRIPT" --url https://maven.example.test/r --username ci --out "$OUT"
  [ "$status" -eq 2 ]
  [ ! -e "$OUT" ]
}

@test "a server id with XML metacharacters is refused" {
  run "$SCRIPT" --url https://maven.example.test/r --username ci --server-id 'a<b' --out "$OUT"
  [ "$status" -eq 2 ]
}

@test "missing url or username is a usage error" {
  run "$SCRIPT" --username ci --out "$OUT"
  [ "$status" -eq 2 ]
  run "$SCRIPT" --url https://maven.example.test/r --out "$OUT"
  [ "$status" -eq 2 ]
}
