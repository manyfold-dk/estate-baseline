# Design: agent mailbox -- robustness and autonomy

Status: Implemented (2026-06-14) -- built and verified the same day it was approved. The skill
was relocated into `baseline-agent/skills/agent-mailbox/` and rebuilt as the concurrency-safe
`ambx/` package, with `scripts/agent/global-install.sh` wiring the machine-global install
(Claude + Codex discovery symlinks and the PATH launcher); `python3 -m unittest` passed 24/24.
The code is [`baseline-agent/skills/agent-mailbox/`](../../baseline-agent/skills/agent-mailbox/SKILL.md).

## Table of Contents

- [Purpose](#purpose)
- [Goals and Non-Goals](#goals-and-non-goals)
- [Decisions Locked In](#decisions-locked-in)
- [Approach](#approach)
- [Skill Home and Distribution](#skill-home-and-distribution)
- [Data Root and Layout](#data-root-and-layout)
- [State Schemas](#state-schemas)
- [Message and Threading Model](#message-and-threading-model)
- [Concurrency and Integrity](#concurrency-and-integrity)
- [Presence and the Board](#presence-and-the-board)
- [Autonomy Loop](#autonomy-loop)
- [Discovery and Safety](#discovery-and-safety)
- [Command Surface](#command-surface)
- [Module Structure and Tests](#module-structure-and-tests)
- [Migration](#migration)
- [Open Questions](#open-questions)

## Purpose

Upgrade the `agent-mailbox` skill from a two-agent handoff channel into a robust coordination
substrate for a group of agents working in different repositories on work the user delegates. The
agents run as separate Claude Code / Codex CLI sessions, one per repo, on a single Mac against a
local filesystem.

## Goals and Non-Goals

Goals:

- Correctness under agents acting concurrently from different repos.
- Observability: the user (and the main agent) can see who is working, blocked, idle, or stale.
- Autonomy: dependent agents can bootstrap, poll efficiently, and follow a delegated task thread
  with minimal user relaying.
- No new runtime dependencies; data stays human-readable and greppable.

Non-Goals:

- **No authentication.** Any local process can post as any agent id. Acceptable for single-user,
  single-machine, local-filesystem use. Explicitly out of scope.
- **No cross-machine sync.** The coordination folder is local and not synced; the design relies on
  `flock`, which is not safe over network/synced filesystems.
- No first-class "assignment/ticket" object -- threads plus the board cover delegated work (YAGNI).

## Decisions Locked In

From the brainstorming session (2026-06-14):

- **Skill home**: promote the skill to the baseline's `baseline-agent/skills/agent-mailbox` as
  the git-tracked canonical source (alongside `archive-plan`, `dev-workflow`, `interview`,
  `verification-loop`). See [Skill Home and Distribution](#skill-home-and-distribution).
- **Root**: data root `~/Developer/Agent-Coordination` (outside every repository), fresh start.
  Existing data in the previous root is left in place, not migrated.
- **Topology**: one Mac, local filesystem. `flock` is sufficient.
- **Launch model**: separate CLI sessions per repo. Favours a blocking wait loop and copy-paste
  bootstrap commands.
- **Priorities**: all four -- concurrency-safe core, status board + heartbeats, threading +
  bootstrap dispatch, wait loop + safety guards.
- **Spec/plan location**: this spec in `docs/specs/`; the implementation plan in `docs/plans/`.

## Approach

Evolve the existing flat-file store in place:

- Keep Markdown messages (YAML frontmatter) and JSON state files -- human-readable and greppable.
- Add an internal locking/store layer (`flock`) and corruption-tolerant JSON loads.
- Split the single script into a small `mailbox/` package with focused modules.
- Add a stdlib `unittest` suite (no `pytest` dependency).
- Blocking `wait` is an in-process poll-with-timeout (no `watchdog` dependency).

Rejected: a SQLite index (two sources of truth, opaque blob, overkill at this scale); a
minimal bolt-on with no restructure or tests (contradicts the robustness goal).

## Skill Home and Distribution

The canonical source moves into the repo:

```
baseline-agent/skills/agent-mailbox/   # git-tracked canonical
  SKILL.md
  scripts/...
  agents/openai.yaml
~/.codex/skills/local/agent-mailbox      -> symlink to the canonical dir (Codex discovery)
~/.claude/skills/agent-mailbox           -> symlink to the canonical dir (Claude Code discovery)
~/.local/bin/agent-mailbox               -> launcher exec'ing the canonical scripts/agent_mailbox.py
```

**Distribution differs from the other baseline-agent skills.** `archive-plan`, `dev-workflow`,
etc. are vendored *per-repo* into each consumer's `.claude/skills/` by `scripts/agent/vendor.sh`.
`agent-mailbox` is instead installed **globally once** (two symlinks + the PATH launcher) because
coordination is inherently cross-repo: every session, in any repo, must reach the same mailbox.
The implementation must therefore ensure the per-repo vendor path does **not** also copy
`agent-mailbox` into consumers (confirm against `scripts/agent/profiles.yaml`); it is excluded
from the vendored profiles and carried by a global install step instead.

## Data Root and Layout

```
~/Developer/Agent-Coordination/           # default root (AGENT_MAILBOX_ROOT overrides)
  identities.json                          # per-repo task/agent identity (root-scoped)
  .identities.lock                         # flock target for identities.json
  <task-slug>/                             # one mailbox per collaboration
    manifest.json                          # task metadata + registered agents
    .lock                                  # flock target for manifest/status mutations
    README.md
    agents/<agent_id>.json                 # registration record
    status/<agent_id>.json                 # presence + read cursor (see schema)
    inbox/<agent_id>/*.md                  # messages to read
    outbox/<agent_id>/*.md                 # messages sent (mirror)
    archive/<agent_id>/*.md                # archived (read) messages
    shared/                                # optional sanitized artifacts
```

## State Schemas

`status/<agent_id>.json`:

```json
{
  "agent_id": "repo-b-worker",
  "role": "dependent",
  "state": "working",            // idle | working | blocked | done
  "note": "validating kustomize",
  "last_seen_at": "2026-06-14T09:39:26Z",
  "last_read_stamp": "20260614T093913516212Z",
  "updated_at": "2026-06-14T09:39:26Z"
}
```

`manifest.json` keeps `task`, `created_at`, `updated_at`, `mailbox_version` (bump to `2`), and
`agents` (id -> {role, repo, last_seen_at}). New fields are additive; readers tolerate their
absence.

## Message and Threading Model

- Each message gets an `id`: 8 hex chars from `secrets.token_hex(4)`, generated at post time. The
  id is written into frontmatter **and** the filename, which also removes the
  same-microsecond filename-collision risk.
- Filename: `{stamp}-{id}-{sender}-to-{recipient}-{kind}-{subject_slug}.md`. The `subject_slug` is
  capped at 50 chars; the full subject lives only in frontmatter and the `# {subject}` heading, so a
  long subject (even one within the 64 KB body guard) cannot exceed the 255-byte filename-component
  limit. A total-filename backstop truncates `subject_slug` further if the assembled name would
  still exceed the limit. The unread cursor keys on the leading `stamp`
  (`name.split('-', 1)[0]`), so cursor logic is unchanged.
- Frontmatter gains `id`, optional `reply_to` (the id being answered), and `thread` (the root id).
- **Thread resolution.** When `--reply-to <id>` is given, the parent is located by a mailbox-wide
  frontmatter scan for that `id` across `inbox/*`, `outbox/*`, and `archive/*`. On a unique match
  the reply inherits the parent's `thread`. If no local message carries that id (parent pruned,
  archived elsewhere, or never local), the reply still posts with `thread = reply_to`, treating the
  referenced id as the thread root -- it never fails. In the degenerate case of multiple matches
  (id collision), the earliest-stamped match wins and the tool warns. With no `--reply-to`,
  `thread = id`.
- **Read cursor and filtered reads.** The single global `last_read_stamp` cursor is advanced
  **only by an unfiltered `inbox --unread`**. Any filtered read -- `--thread`, and the `--all` /
  `--limit` views -- is implicitly peek and never advances the cursor. This stops a thread-scoped
  read from moving the high-water mark past unread messages in *other* threads (which would skip
  them forever). `inbox --thread <id>` thus shows a conversation without consuming unread state.

## Concurrency and Integrity

- One `flock(LOCK_EX)` per mailbox via `<task>/.lock` guards every read-modify-write of
  `manifest.json` and `status/<agent>.json`. A root-level `<root>/.identities.lock` guards
  `identities.json`. Locks are held only around the mutation, then released.
- **Atomic message writes.** Each message is written to a same-directory temp file and
  `os.replace`d into place, so a polling `inbox --wait` reader never observes a torn/partial `.md`.
  Message writes stay lock-free: filenames are unique, and each recipient's inbox copy is delivered
  independently and atomically (no half-written message, no cross-recipient invariant).
- **Outbox is a repairable mirror.** Delivery writes the recipient `inbox` copy first (delivery is
  the authoritative event), then mirrors into the sender `outbox`. A crash between the two leaves
  the inbox copy authoritative; `repair` reconstructs missing outbox entries by scanning all
  inboxes for messages whose `from` equals the sender. The outbox is best-effort and derivable,
  never a source of truth.
- **Corruption recovery is per-file.** A `JSONDecodeError` raises a clear error naming the file and
  its specific recovery (not a blanket pointer at `repair --task`):

  | Corrupt file | Recovery |
  |--------------|----------|
  | `manifest.json` | `repair --task <task>` rebuilds `agents` from `agents/*.json` (falling back to inbox/outbox `from`/`to` frontmatter if those are also gone). |
  | `agents/<id>.json` | `repair --task` drops and rebuilds the bad record from `manifest` + that agent's `status`. |
  | `status/<id>.json` | `repair --task` resets it to a fresh record; `last_read_stamp` is preserved if salvageable, else reset to empty (unread may re-show) with a warning. |
  | `identities.json` | `repair --identities` (root-scoped) resets the cache to `{}`; agents re-save identity on the next `init`/`join`. It is only a convenience cache. |

## Presence and the Board

- Every command run by an agent bumps that agent's `last_seen_at` (under the lock).
- `status set --state working --note "..."` (alias `heartbeat`) updates state/note for long silent
  stretches.
- `board` is the supervision cockpit. For each registered agent it prints: role, `state`, age since
  `last_seen_at` (flagged `STALE` past `--stale-after`, default 600s, also `AGENT_MAILBOX_STALE_SECS`),
  count of messages past that agent's read cursor (who is behind), and the last message
  kind/subject/time. Read-only; no cursor side effects.

## Autonomy Loop

- `inbox --wait [SECS]` blocks, polling the inbox every ~2s until new unread mail arrives or the
  timeout elapses (default 300s). On new mail it prints and advances the cursor (unless `--peek`).
  Exit code is `0` when mail arrived, non-zero on timeout, so a shell `while` loop can react.
- `init` prints a ready-to-paste bootstrap block per peer:

  ```bash
  # Dispatch to repo-b-worker (run in its repo):
  export AGENT_MAILBOX_ROOT=~/Developer/Agent-Coordination
  agent-mailbox join --task <task> --agent repo-b-worker --peer <main>
  agent-mailbox inbox --unread
  ```

  The same block is available on demand via `bootstrap --agent <peer>`.

## Discovery and Safety

- `list` enumerates mailboxes under the root, one line each: task, agent count, last activity.
- `whoami` prints the resolved task/agent/role for the current repo (identity resolution result).
- Body guards run on `post`/`init`/`join`: refuse (unless `--allow-unsafe`) when a body matches a
  high-signal secret marker -- `-----BEGIN`, `AKIA[0-9A-Z]{16}`, `xox[baprs]-`,
  `gh[pousr]_[A-Za-z0-9]{20,}`, JWT-like `eyJ...`, `password\s*[:=]` -- or exceeds ~64 KB.
  `--allow-unsafe` is distinct from `post --force` (which only overrides the unregistered-recipient
  guard); the two never share a flag.
- `archive` moves already-read (at/below the cursor) messages from `inbox/<agent>/` to
  `archive/<agent>/`, keeping inboxes small for long collaborations.

## Command Surface

| Command | Purpose | Notable flags |
|---------|---------|---------------|
| `init` | Create mailbox, deliver initial instruction, print bootstrap blocks | `--peer`, `--to`, `--body/--body-file`, `--allow-unsafe` |
| `join` | Register an agent, save per-repo identity, optional ack | `--peer`, `--body`, `--allow-unsafe` |
| `post` | Send a message | `--to`, `--kind`, `--subject`, `--reply-to`, `--body`, `--force` (recipient), `--allow-unsafe` (guards) |
| `inbox` | Read messages | `--unread`, `--peek`, `--all`, `--limit`, `--thread`, `--wait [SECS]`, `--list-only` |
| `board` | Supervision dashboard | `--stale-after` |
| `status` / `heartbeat` | Set own state/note | `--state`, `--note` |
| `agents` | List registered agents | -- |
| `list` | List mailboxes under root | -- |
| `whoami` | Show resolved identity for this repo | -- |
| `bootstrap` | Print a peer's join/read block | `--agent` |
| `archive` | Move read messages to archive/ | `--agent` |
| `repair` | Per-file recovery (manifest/agents/status; outbox mirror) | `--task`, `--identities` |
| `form` / `wizard` | Intake form / interactive prompts | `--mode` |

Identity resolution (flag -> `AGENT_MAILBOX_TASK`/`AGENT_MAILBOX_AGENT` env -> per-repo
`identities.json`) applies to every command that needs a task/agent.

## Module Structure and Tests

Under the canonical `baseline-agent/skills/agent-mailbox/`:

```
scripts/
  agent_mailbox.py          # thin entry: add scripts/ to sys.path, call ambx.cli.main()
  ambx/                     # package named ambx, NOT mailbox, to avoid shadowing the stdlib module
    __init__.py
    store.py                # paths, flock, json io, manifest/identity/status, presence, repair
    messages.py            # ids, filenames, post/read, threading, archive
    guards.py              # slug, secret/size checks
    cli.py                 # argparse + command handlers (incl. board, list, whoami, wait, bootstrap)
  tests/
    test_mailbox.py        # python3 -m unittest; covers locking, cursor, threading,
                           # guards, board staleness, wait timeout, repair
```

The launcher (`~/.local/bin/agent-mailbox`) points at the canonical
`scripts/agent_mailbox.py`.

## Migration

The skill's move into the baseline and the switch of the machine-global install to the
canonical directory happened before the feature work. Data migration:

- Default root changes to `~/Developer/Agent-Coordination`; the old root is untouched (fresh
  start).
- `AGENT_MAILBOX_ROOT` continues to override.
- New schema fields are additive; `mailbox_version` bumps to `2`. Pointed at an old-root mailbox,
  the tooling adds missing fields lazily on next write and still reads `version 1` manifests.
- A pre-manifest ad-hoc mailbox layout remains unsupported by `agents`/`board` (it has no
  manifest); this is unchanged.

## Open Questions

None blocking. `inbox --wait` defaults to non-zero exit on timeout (so shell loops can branch);
revisit if a quiet always-zero exit proves friendlier in practice.

---

Published version of a design written 2026-06-14 (last updated 2026-06-20). Commit ids, the
relocation steps on one machine and the name of one existing mailbox are removed; the reasoning,
the dates and the non-goals are unchanged. At the time the skill lived in a private baseline
repository; it has lived in this one since 2026-09-22.
