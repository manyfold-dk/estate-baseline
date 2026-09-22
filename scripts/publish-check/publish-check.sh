#!/usr/bin/env bash
# publish-check.sh -- the gate a directory passes before it becomes public.
#
# Usage: publish-check.sh <dir> --names FILE|none [--allow FILE]
#
# Three checks over every file under <dir>, all of them always run:
#   1. deny-list   identifiers a secret scanner cannot know: the names in --names FILE
#                  (tenants, clients, private repositories; one per line, private to the
#                  estate that owns them, never stored beside this script) and the shapes in
#                  patterns.tsv beside this script (addresses, internal hosts, exact
#                  versions, repository paths). --names none runs the shapes only, which is
#                  the most a public repository's own CI can do; say it explicitly.
#   2. gitleaks    `gitleaks dir`, values redacted
#   3. trufflehog  `trufflehog filesystem --no-verification`: every candidate counts, and
#                  no suspected credential is sent to a provider to find out if it is live
#
# Exit 0: no hit. Exit 1: at least one hit, each printed as file:line. Exit 2: usage error
# or a missing tool -- a gate that cannot run has not passed. Scanner findings never print
# the value. Deny-list hits print the matched text: it is an identifier, and the reader
# needs it to scrub the file.
#
# --allow FILE exempts exact values from the shape checks: one row per value, the pattern's
# label, a tab, the matched text (`repository path<TAB>docs/adr/`). A third column scopes
# the row to one file, relative to <dir>; with it the value may be `*`, meaning that file
# is allowed to carry that shape (`exact version<TAB>*<TAB>baseline-agent/VERSION`: the
# repository's own release number is not a version in use). A tool that builds an ADR index
# has to say docs/adr/; nothing has to say a tenant's name. So a `name` row, or a label
# patterns.tsv does not know, or `*` without a file, is a usage error, and scanner findings
# cannot be allowed here at all. An allow file with shape rows only may live in the public
# repository it relaxes; the tool refuses a name row, so it cannot leak one.
#
# <dir> is scanned as files, not as git history. Publish from a clean export with fresh
# history; this script says nothing about what an existing history holds.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patterns="$here/patterns.tsv"

usage() { echo "usage: publish-check.sh <dir> --names FILE|none [--allow FILE]" >&2; exit 2; }
[ $# -ge 1 ] && [ -d "$1" ] || usage
dir="$(cd "$1" && pwd)"; shift
names="" allow=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --names) names="$2" ;;
    --allow) allow="$2"; [ -f "$allow" ] || usage ;;
    *) usage ;;
  esac
  shift 2
done
case "$names" in
  none) names="" ;;
  "") usage ;;
  *) [ -f "$names" ] || usage ;;
esac
for t in python3 jq gitleaks trufflehog; do
  command -v "$t" >/dev/null 2>&1 || { echo "publish-check: $t not installed; nothing was checked" >&2; exit 2; }
done

hits=0

echo "== deny-list"
rc=0
[ -n "$names" ] || echo "deny-list: no name list (--names none): shapes only"
python3 - "$dir" "$names" "$patterns" "$allow" <<'PY' || rc=$?
import os, re, sys
root, names_file, patterns_file, allow_file = sys.argv[1:5]

def rows(path):
    with open(path, encoding="utf-8") as f:
        return [l.rstrip("\n") for l in f if l.strip() and not l.startswith("#")]

checks = [("name", re.compile(r"(?<![A-Za-z0-9])" + re.escape(n.strip()) + r"(?![A-Za-z0-9])", re.I))
          for n in (rows(names_file) if names_file else [])]
for row in rows(patterns_file):
    label, pattern = row.split("\t", 1)
    checks.append((label, re.compile(pattern, re.I)))

allowed = set()
if allow_file:
    labels = {label for label, _ in checks} - {"name"}
    for row in rows(allow_file):
        parts = row.split("\t")
        label, value, path = (parts + ["", ""])[:3]
        if label not in labels or not value or (value == "*" and not path):
            print(f"allow file: '{label}' is not a shape label with a value (and '*' needs a file); names are never allowed", file=sys.stderr)
            sys.exit(2)
        allowed.add((label, value, path))

found = passed = 0
for base, dirs, files in os.walk(root):
    dirs[:] = sorted(d for d in dirs if d != ".git")
    for name in sorted(files):
        path = os.path.join(base, name)
        rel = os.path.relpath(path, root)
        # A file name leaks as surely as a line does.
        lines = [(0, rel)]
        if os.path.islink(path):
            # A link's target is text that gets published too, and a link that points out of
            # the tree publishes whatever it points at. Neither is followed.
            target = os.readlink(path)
            resolved = os.path.realpath(os.path.join(base, target))
            if os.path.isabs(target) or os.path.commonpath([resolved, os.path.realpath(root)]) != os.path.realpath(root):
                print(f"{rel} (symlink): escapes the tree: {target}")
                found += 1
            lines.append((0, f"{rel} -> {target}"))
        else:
            with open(path, "rb") as f:
                data = f.read()
            # Binary or not, the bytes are published: scan them as text with NULs removed.
            # A NUL must never switch the check off.
            lines += list(enumerate(data.replace(b"\0", b"").decode("utf-8", "replace").splitlines(), 1))
        for number, text in lines:
            for label, pattern in checks:
                for match in pattern.finditer(text):
                    if (label, match.group(0), "") in allowed or (label, match.group(0), rel) in allowed \
                            or (label, "*", rel) in allowed:
                        passed += 1
                        continue
                    where = f"{rel}:{number}" if number else f"{rel} (file name)"
                    print(f"{where}: {label}: {match.group(0)}")
                    found += 1
print(f"deny-list: {found} hit(s), {passed} allowed")
sys.exit(1 if found else 0)
PY
[ "$rc" -le 1 ] || exit 2
[ "$rc" -eq 0 ] || hits=1

echo "== gitleaks"
gitleaks dir "$dir" --redact --no-banner --no-color --verbose --log-level warn || hits=1

echo "== trufflehog"
# --json keeps the raw value out of the terminal: only detector, file and line are printed.
# A scanner that could not read something has not scanned it: --fail-on-scan-errors, and
# its stderr is kept (it carries no values) so the failure can be read.
th_raw="$(mktemp)"; th_err="$(mktemp)"
th_rc=0
trufflehog filesystem "$dir" --json --no-verification --no-update --fail-on-scan-errors > "$th_raw" 2> "$th_err" || th_rc=$?
if [ "$th_rc" -ne 0 ] && [ "$th_rc" -ne 183 ]; then
  echo "trufflehog failed (rc=$th_rc); nothing was checked by it:" >&2; sed -n 1,20p "$th_err" >&2
  rm -f "$th_raw" "$th_err"; exit 2
fi
th="$(jq -r 'select(.DetectorName != null)
             | "\(.SourceMetadata.Data.Filesystem.file):\(.SourceMetadata.Data.Filesystem.line // 0): \(.DetectorName) (value redacted)"' "$th_raw")" \
  || { echo "trufflehog output could not be parsed" >&2; rm -f "$th_raw" "$th_err"; exit 2; }
rm -f "$th_raw" "$th_err"
if [ -n "$th" ]; then printf '%s\n' "$th"; hits=1; fi
echo "trufflehog: $(printf '%s' "$th" | grep -c . || true) hit(s)"

if [ "$hits" -ne 0 ]; then echo "publish-check: FAIL $dir"; exit 1; fi
echo "publish-check: OK $dir"
