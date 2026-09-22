#!/usr/bin/env bats
# publish-check.sh against scratch directories. Every seeded value is built at run time: a
# token-shaped string in this file would be refused by a pre-commit hook, and the name list
# is private to an estate, so the tests carry an invented one.

setup() {
  for t in gitleaks trufflehog jq python3; do
    command -v "$t" >/dev/null 2>&1 || skip "$t not installed"
  done
  tmp="$(cd "$(mktemp -d)" && pwd -P)"
  check="$BATS_TEST_DIRNAME/publish-check.sh"
  names="$tmp/names.txt"
  printf '# invented\nzorbulon\nQuux Industries\n' > "$names"
  export="$tmp/export"
  # Shapes the gate detects are assembled at run time so this file carries none of them.
  brand="manyf"; brand="${brand}old"; tail="ts"; tail="$tail.net"; rp="platform/comp"; rp="${rp}onents/"
  mkdir -p "$export/docs"
  printf '# Decision\n\nWe chose the smaller provider because it was cheaper.\n' > "$export/docs/record.md"
}

teardown() { [ -z "${tmp:-}" ] || rm -rf "$tmp"; }

@test "a clean directory passes" {
  run "$check" "$export" --names "$names"
  [ "$status" -eq 0 ]
  [[ "$output" == *"publish-check: OK"* ]]
}

@test "a listed name fails with file and line, in any letter case, as a whole word" {
  printf 'intro\nhosted for ZORBULON since spring\nquux industries too\nzorbulons is another word\n' > "$export/docs/tenants.md"
  run "$check" "$export" --names "$names"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/tenants.md:2: name: ZORBULON"* ]]
  [[ "$output" == *"docs/tenants.md:3: name: quux industries"* ]]
  [[ "$output" != *"tenants.md:4"* ]]
}

@test "a listed name in a file name fails" {
  echo "nothing here" > "$export/zorbulon-notes.md"
  run "$check" "$export" --names "$names"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(file name): name: zorbulon"* ]]
}

@test "each generic shape fails: address, version, internal host, tailnet, repository path" {
  octet=$((RANDOM % 200 + 10))
  {
    echo "node at 10.$octet.0.$octet"
    echo "runs v1.$octet.2"
    echo "see something.$brand.dk and host.example.$tail"
    echo "values in ${rp}thing.yaml"
  } > "$export/docs/runtime.md"
  run "$check" "$export" --names "$names"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/runtime.md:1: IPv4 address: 10.$octet.0.$octet"* ]]
  [[ "$output" == *"docs/runtime.md:2: exact version: v1.$octet.2"* ]]
  [[ "$output" == *"docs/runtime.md:3: manyfold.dk subdomain: something.$brand.dk"* ]]
  [[ "$output" == *"docs/runtime.md:3: tailnet host: $tail"* ]]
  [[ "$output" == *"docs/runtime.md:4: repository path: $rp"* ]]
}

@test "the public site's own host name passes" {
  echo "Published at https://www.manyfold.dk/decisions and https://manyfold.dk/stack" > "$export/docs/links.md"
  run "$check" "$export" --names "$names"
  [ "$status" -eq 0 ]
}

@test "--names none checks shapes only and says so" {
  octet=$((RANDOM % 200 + 10))
  echo "hosted for zorbulon at 10.$octet.1.$octet" > "$export/docs/tenants.md"
  run "$check" "$export" --names none
  [ "$status" -eq 1 ]
  [[ "$output" == *"shapes only"* ]]
  [[ "$output" != *"name: zorbulon"* ]]
  [[ "$output" == *"IPv4 address: 10.$octet.1.$octet"* ]]
}

@test "a token-shaped string fails in both scanners, and its value is never printed" {
  body="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
  printf 'first line\ntoken = "ghp_%s"\n' "$body" > "$export/settings.txt"
  run "$check" "$export" --names "$names"
  [ "$status" -eq 1 ]
  [[ "$output" != *"$body"* ]]
  [[ "$output" == *"RuleID:"*"github-pat"* ]]
  [[ "$output" == *"settings.txt:2: Github (value redacted)"* ]]
}

@test "all three checks run even after the first one fails" {
  echo "hosted for zorbulon" > "$export/docs/tenants.md"
  run "$check" "$export" --names "$names"
  [ "$status" -eq 1 ]
  [[ "$output" == *"== gitleaks"* ]]
  [[ "$output" == *"== trufflehog"* ]]
}

@test "--allow exempts an exact shape value and nothing else" {
  printf 'The index lists docs/adr/ and docs/plans/ entries.\n' > "$export/docs/index.md"
  printf '# the generator has to name its input directory\nrepository path\tdocs/adr/\n' > "$tmp/allow.tsv"
  run "$check" "$export" --names "$names" --allow "$tmp/allow.tsv"
  [ "$status" -eq 1 ]
  [[ "$output" != *"repository path: docs/adr/"* ]]
  [[ "$output" == *"docs/index.md:1: repository path: docs/plans/"* ]]
  [[ "$output" == *"1 hit(s), 1 allowed"* ]]
}

@test "a file-scoped allow row exempts that file only, and '*' needs a file" {
  octet=$((RANDOM % 200 + 10))
  printf 'agent-1.2.%s\n' "$octet" > "$export/VERSION"
  printf 'runs 1.2.%s\n' "$octet" > "$export/docs/other.md"
  printf 'exact version\t*\tVERSION\n' > "$tmp/allow.tsv"
  run "$check" "$export" --names "$names" --allow "$tmp/allow.tsv"
  [ "$status" -eq 1 ]
  [[ "$output" != *"VERSION:1"* ]]
  [[ "$output" == *"docs/other.md:1: exact version: 1.2.$octet"* ]]
  printf 'exact version\t*\n' > "$tmp/allow.tsv"
  run "$check" "$export" --names "$names" --allow "$tmp/allow.tsv"
  [ "$status" -eq 2 ]
}

@test "a name can never be allowed, and neither can an unknown label" {
  octet=$((RANDOM % 200 + 10))
  printf 'name\tzorbulon\n' > "$tmp/allow.tsv"
  run "$check" "$export" --names "$names" --allow "$tmp/allow.tsv"
  [ "$status" -eq 2 ]
  [[ "$output" == *"names are never allowed"* ]]
  printf 'exact versoin\t1.2.%s\n' "$octet" > "$tmp/allow.tsv"
  run "$check" "$export" --names "$names" --allow "$tmp/allow.tsv"
  [ "$status" -eq 2 ]
}

@test "a missing scanner is a failure to check, not a pass" {
  mkdir -p "$tmp/bin"
  for t in bash env python3 jq gitleaks dirname; do ln -s "$(command -v "$t")" "$tmp/bin/$t"; done
  run env PATH="$tmp/bin" "$check" "$export" --names "$names"
  [ "$status" -eq 2 ]
  [[ "$output" == *"trufflehog not installed"* ]]
}

@test "a NUL byte does not switch the content check off" {
  printf 'x\0y\nhosted for zorbulon\n' > "$export/blob.bin"
  run "$check" "$export" --names "$names"
  [ "$status" -eq 1 ]
  [[ "$output" == *"blob.bin:2: name: zorbulon"* ]]
}

@test "a symlink's target text is checked and a link out of the tree is a hit" {
  ln -s "docs/record.md" "$export/alias.md"
  run "$check" "$export" --names "$names"
  [ "$status" -eq 0 ]
  ln -s "/etc/hosts" "$export/escape"
  ln -s "zorbulon.txt" "$export/named"
  run "$check" "$export" --names "$names"
  [ "$status" -eq 1 ]
  [[ "$output" == *"escape (symlink): escapes the tree"* ]]
  [[ "$output" == *"named -> zorbulon.txt"* ]] || [[ "$output" == *"name: zorbulon"* ]]
}

@test "no --names, a missing names file, a trailing option, no argument, or a file for <dir> is a usage error" {
  run "$check" "$export"
  [ "$status" -eq 2 ]
  run "$check" "$export" --names
  [ "$status" -eq 2 ]
  run "$check" "$export" --names "$tmp/nope.txt"
  [ "$status" -eq 2 ]
  run "$check"
  [ "$status" -eq 2 ]
  run "$check" "$export/docs/record.md" --names none
  [ "$status" -eq 2 ]
}

@test "this repository passes its own gate, shapes only" {
  run "$check" "$BATS_TEST_DIRNAME/../.." --names none --allow "$BATS_TEST_DIRNAME/../../.publish-allow.tsv"
  [ "$status" -eq 0 ]
}
