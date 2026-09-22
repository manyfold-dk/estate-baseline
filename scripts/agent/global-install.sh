#!/usr/bin/env bash
# Own global shared links and the non-autoload policy. Bootstrap owns Codex AGENTS.md.
# Install is conservative: preserve unknown files/links for their owner to reconcile.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
payload="$repo/baseline-agent"
skills="$payload/skills"
entry="$skills/agent-mailbox/scripts/agent_mailbox.py"
# The machine bootstrap repository, which owns the global Codex entry point. Its location is
# a property of the machine, so the caller names it.
bootstrap=""
mode=install
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check; shift;;
    --bootstrap-source) bootstrap="${2:?--bootstrap-source needs a path}"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
# Accept a supplied relocated checkout without assuming that it already exists.
[ -n "$bootstrap" ] || { echo "global-install.sh: --bootstrap-source <dir> is required" >&2; exit 2; }
bootstrap="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$bootstrap")"
fail=0
link() {
  local target="$1" link_path="$2"
  if [ ! -e "$target" ]; then
    echo "MISSING TARGET $target"; fail=1; return
  fi
  if [ -L "$link_path" ] && [ "$(readlink "$link_path")" = "$target" ]; then
    echo "ok       $link_path"
  elif [ -e "$link_path" ] || [ -L "$link_path" ]; then
    echo "CUSTOM   $link_path (preserved; reconcile with owner)"; fail=1
  elif [ "$mode" = check ]; then
    echo "MISSING  $link_path"; fail=1
  else
    mkdir -p "$(dirname "$link_path")"
    ln -s "$target" "$link_path"
    echo "linked   $link_path"
  fi
}
[ -f "$entry" ] || { echo "missing mailbox entry" >&2; exit 2; }
launcher="$HOME/.local/bin/agent-mailbox"
want="$(printf '#!/usr/bin/env bash\n# Launcher for the agent-mailbox skill (managed by scripts/agent/global-install.sh).\nexec python3 "%s" "$@"\n' "$entry")"
if [ -f "$launcher" ] && [ ! -L "$launcher" ] && [ "$(cat "$launcher")" = "$want" ] && [ -x "$launcher" ]; then
  echo "ok       $launcher"
elif [ -e "$launcher" ] || [ -L "$launcher" ]; then
  echo "CUSTOM   $launcher (preserved)"; fail=1
elif [ "$mode" = check ]; then
  echo "MISSING  $launcher"; fail=1
else
  mkdir -p "$(dirname "$launcher")"
  printf '%s\n' "$want" > "$launcher"
  chmod +x "$launcher"
fi
link "$skills/agent-mailbox" "$HOME/.claude/skills/agent-mailbox"
# Interim shared-skill access. Domain/global retirement stays gated on runtime evidence.
for skill in agent-mailbox archive-plan dev-workflow interview verification-loop plan-design plan-writing; do
  link "$skills/$skill" "$HOME/.codex/skills/local/$skill"
done
policy_dir="$HOME/.config/manyfold"
if [ "$mode" = install ] && [ ! -e "$policy_dir" ]; then
  mkdir -p "$(dirname "$policy_dir")"
  mkdir -m 0700 "$policy_dir"
fi
link "$payload/POLICY.md" "$policy_dir/agent-policy.md"
# Never create, delete or replace this link: the bootstrap installer owns the handoff.
codex_root="$HOME/.codex/AGENTS.md"
if [ -L "$codex_root" ] && [ "$(readlink "$codex_root")" = "$payload/AGENTS.baseline.md" ] && [ -f "$codex_root" ]; then
  echo "LEGACY (bootstrap replaces) $codex_root"
elif [ -L "$codex_root" ] && [ "$(readlink "$codex_root")" = "$bootstrap/codex/AGENTS.md" ] && [ -f "$codex_root" ]; then
  echo "ok       $codex_root (bootstrap-owned)"
elif [ "$mode" = check ]; then
  echo "WRONG/MISSING $codex_root (bootstrap must reconcile)"; fail=1
else
  echo "PENDING  $codex_root (bootstrap owns; left unchanged)"
fi
python3 "$here/check_global_skills.py" "$HOME" || fail=1
if [ "$fail" -ne 0 ]; then
  echo "DRIFT: reconcile owned wiring; preserve customizations before migration" >&2
  exit 1
fi
