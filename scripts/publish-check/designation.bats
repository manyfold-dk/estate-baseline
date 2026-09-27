#!/usr/bin/env bats
# designation.sh against an invented list. Every name here is invented; the estate's own list
# is private and never enters this repository.

setup() {
  tmp="$(cd "$(mktemp -d)" && pwd -P)"
  d="$BATS_TEST_DIRNAME/designation.sh"
  list="$tmp/public-repos.txt"
  printf '# invented\n\nexample-org/public-thing\nhttps://git.example.invalid/team/tool.git\n' > "$list"
}

teardown() { [ -z "${tmp:-}" ] || rm -rf "$tmp"; }

classify() { run "$d" --list "$list" --url "$1"; }
# stdout only: the refusals print their reason on stderr, and stdout must stay empty
quiet() { run bash -c '"$@" 2>/dev/null' _ "$@"; }

@test "every URL form of a listed GitHub repository is public" {
  for u in https://github.com/example-org/public-thing \
           http://github.com/example-org/public-thing \
           https://github.com/example-org/public-thing.git \
           https://github.com/example-org/public-thing/ \
           https://www.github.com/example-org/public-thing \
           https://token@github.com/example-org/public-thing.git \
           ssh://git@github.com/example-org/public-thing.git \
           git@github.com:example-org/public-thing.git \
           git@github.com:example-org/public-thing; do
    classify "$u"
    [ "$status" -eq 0 ]
    [ "$output" = public ] || { echo "not public: $u"; false; }
  done
}

@test "letter case does not matter on GitHub, in the URL or in the row" {
  classify https://GitHub.com/Example-Org/Public-Thing.git
  [ "$output" = public ]
  printf 'Example-Org/Mixed\n' >> "$list"
  classify git@github.com:example-org/mixed.git
  [ "$output" = public ]
}

@test "an unlisted repository is private, and so is a longer name with the listed one as prefix" {
  classify https://github.com/example-org/private-thing
  [ "$status" -eq 0 ]
  [ "$output" = private ]
  classify https://github.com/example-org/public-thing-other
  [ "$output" = private ]
  classify https://github.com/other-org/public-thing
  [ "$output" = private ]
}

@test "a lookalike host is not GitHub" {
  for u in https://notgithub.com/example-org/public-thing \
           https://github.com.example.invalid/example-org/public-thing \
           git@notgithub.com:example-org/public-thing.git; do
    classify "$u"
    [ "$status" -eq 0 ]
    [ "$output" = private ] || { echo "not private: $u"; false; }
  done
}

@test "a full-URL row matches that URL exactly, less .git and a trailing slash" {
  classify https://git.example.invalid/team/tool
  [ "$output" = public ]
  classify https://git.example.invalid/team/tool.git/
  [ "$output" = public ]
  classify https://git.example.invalid/team/tool-two
  [ "$output" = private ]
  printf '%s\n' "$tmp/remote.git" >> "$list"
  classify "$tmp/remote.git"
  [ "$output" = public ]
  classify "file://$tmp/remote.git"
  [ "$output" = private ]
}

@test "CRLF and whitespace around a row are trimmed" {
  printf 'example-org/crlf-thing\r\n   example-org/spaced-thing  \t\n' >> "$list"
  classify https://github.com/example-org/crlf-thing
  [ "$output" = public ]
  classify https://github.com/example-org/spaced-thing
  [ "$output" = public ]
}

@test "a malformed row is exit 2 with nothing on stdout, never a skip" {
  for row in 'just-a-name' 'example-org/a b' 'example-org/' 'a/b/c'; do
    printf 'example-org/public-thing\n%s\n' "$row" > "$list"
    quiet "$d" --list "$list" --url https://github.com/example-org/public-thing
    [ "$status" -eq 2 ] || { echo "row accepted: $row"; false; }
    [ -z "$output" ]
  done
}

@test "an unreadable list and a usage error are exit 2 with nothing on stdout" {
  quiet "$d" --list "$tmp/missing.txt" --url https://github.com/example-org/public-thing
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  quiet "$d" --list "$list"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  quiet "$d" --list "$list" --url x --dir "$tmp"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "--dir: any remote's push URL decides, not only origin's fetch URL" {
  repo="$tmp/repo"; git init -q "$repo"
  git -C "$repo" remote add origin https://github.com/example-org/private-thing.git
  run "$d" --list "$list" --dir "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = private ]
  git -C "$repo" remote add mirror git@github.com:example-org/public-thing.git
  run "$d" --list "$list" --dir "$repo"
  [ "$output" = public ]
  git -C "$repo" remote remove mirror
  # a push URL that differs from the fetch URL is where content goes
  git -C "$repo" remote set-url --push origin https://github.com/example-org/public-thing
  run "$d" --list "$list" --dir "$repo"
  [ "$output" = public ]
  # and a second push URL on the same remote counts too
  git -C "$repo" remote set-url --push origin https://github.com/example-org/private-thing
  git -C "$repo" remote set-url --push --add origin https://github.com/example-org/public-thing
  run "$d" --list "$list" --dir "$repo"
  [ "$output" = public ]
}

@test "--dir: a checkout with no remote, or no checkout, is exit 2" {
  repo="$tmp/repo"; git init -q "$repo"
  quiet "$d" --list "$list" --dir "$repo"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  mkdir "$tmp/plain"
  quiet "$d" --list "$list" --dir "$tmp/plain"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "--dir ignores a GIT_DIR a hook exports" {
  repo="$tmp/repo"; git init -q "$repo"
  git -C "$repo" remote add origin https://github.com/example-org/public-thing
  other="$tmp/other"; git init -q "$other"
  git -C "$other" remote add origin https://github.com/example-org/private-thing
  GIT_DIR="$other/.git" run "$d" --list "$list" --dir "$repo"
  [ "$output" = public ]
}
