#!/bin/sh
# Write a Maven settings.xml that resolves artifacts, a parent POM included, from one
# authenticated repository.
#
# A <server> entry alone is not enough for a parent POM: Maven resolves the parent before
# it reads the project's own <repositories>, so the repository has to come from an active
# profile in settings.xml. This writes the server, that profile, and activates it.
#
# The token is written into the file, so nothing has to be exported for the Maven run that
# follows. The file is created mode 0600. Every value is XML-escaped.
set -eu

URL=""
SERVER_ID="github"
USERNAME=""
OUT="${HOME}/.m2/settings.xml"

usage() {
  cat <<'USAGE'
Usage:
  setup-maven-registry.sh --url URL --username NAME [--server-id ID] [--out FILE]

The token is read from $MAVEN_REGISTRY_TOKEN, never from the command line.
  --url         https:// URL of the Maven repository
  --username    user name for the repository (any value works for most token registries)
  --server-id   id shared by <server> and <repository> (default: github)
  --out         file to write (default: ~/.m2/settings.xml)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2-}"; shift 2 ;;
    --username) USERNAME="${2-}"; shift 2 ;;
    --server-id) SERVER_ID="${2-}"; shift 2 ;;
    --out) OUT="${2-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "setup-maven-registry: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

TOKEN="${MAVEN_REGISTRY_TOKEN-}"

[ -n "$URL" ] || { echo "setup-maven-registry: --url is required" >&2; exit 2; }
[ -n "$USERNAME" ] || { echo "setup-maven-registry: --username is required" >&2; exit 2; }
[ -n "$TOKEN" ] || { echo "setup-maven-registry: MAVEN_REGISTRY_TOKEN is empty" >&2; exit 2; }
case "$URL" in
  https://*) ;;
  *) echo "setup-maven-registry: --url must start with https://" >&2; exit 2 ;;
esac
case "$SERVER_ID" in
  *[!A-Za-z0-9._-]*|"") echo "setup-maven-registry: --server-id may hold only letters, digits, '.', '_' and '-'" >&2; exit 2 ;;
esac

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

u=$(xml_escape "$USERNAME")
t=$(xml_escape "$TOKEN")
r=$(xml_escape "$URL")

mkdir -p "$(dirname "$OUT")"
umask 077
cat > "$OUT" <<XML
<settings>
  <servers>
    <server>
      <id>${SERVER_ID}</id>
      <username>${u}</username>
      <password>${t}</password>
    </server>
  </servers>
  <profiles>
    <profile>
      <id>${SERVER_ID}-registry</id>
      <repositories>
        <repository>
          <id>${SERVER_ID}</id>
          <url>${r}</url>
        </repository>
      </repositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>${SERVER_ID}-registry</activeProfile>
  </activeProfiles>
</settings>
XML
chmod 600 "$OUT"
echo "setup-maven-registry: wrote $OUT for server '$SERVER_ID'"
