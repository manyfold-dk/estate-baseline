# Agent asset distribution

## Table of Contents

- [Ownership](#ownership)
- [Vendor and check](#vendor-and-check)
- [Profiles](#profiles)
- [Global ownership transition](#global-ownership-transition)
- [Verification and publication](#verification-and-publication)

## Ownership

`baseline-agent/` is the secret-free, tenant-consumable canonical payload.
[POLICY.md](../../baseline-agent/POLICY.md) equals the inner `BEGIN policy` / `END policy`
blocks in both runtime sources. Authors edit these source blocks together; `vendor.sh`
only writes consumers and never changes the source blocks. Runtime adapters differ outside
the policy blocks. [ADR 0001](../../docs/adr/0001-public-standard-private-values.md)
records which half of the baseline holds what; the record of the runtime-adapter design
lives with the estate that made it.

Consumers own content outside outer `baseline-agent` markers and every skill `environment.md`
overlay. Profile assets are generated; edit the source and re-vendor. References and helpers
ship explicitly in profiles. Never add platform-only or tenant operations to this payload.

## Vendor and check

Run from the intended consumer, after the baseline release is published:

```bash
/path/to/baseline/scripts/agent/vendor.sh --profile app
/path/to/baseline/scripts/agent/check.sh .
```

The vendor copies profile assets into `.claude`, replaces the two outer marker blocks and
writes `.claude/.baseline-agent-version`. It leaves environment overlays intact. The stamp
records version, profile, source checkout HEAD, timestamp and discovery mode. A self-vendor
prepared in the same commit records the pre-commit HEAD; content checks establish payload
agreement rather than treating that field as authorship or immutable build provenance.

An estate fills the policy's placeholders with its own values through an overlay, and
classifies each consumer first:

```bash
/path/to/baseline/scripts/agent/vendor.sh --profile app \
  --overlay /path/to/estate/overlay --public-repos /path/to/estate/public-repos.txt
/path/to/baseline/scripts/agent/check.sh --overlay /path/to/estate/overlay .
```

`--overlay` requires `--public-repos`, the estate's list of repositories designated public.
Before anything is written, `scripts/publish-check/designation.sh --dir` classifies every
push URL of every remote of the consumer against that list. Only a `private` consumer
receives the overlay. A repository designated public is vendored without an overlay, and the
placeholders stay: `vendor.sh` refuses `--overlay` for it, first vendor included, and for a
consumer that cannot be classified (no remote, a malformed list row). The overlay must sit in
a Git work tree. The stamp records `overlay_applied=true|false`; `check.sh` reports a check
run in the other mode as `agent-baseline-overlay` drift, first, and no deviation ADR
suppresses it. `check.sh` does not read the list: the caller classifies and picks the mode.

When the consumer keeps a `.publish-allow.tsv` (the publication gate's allow file), the vendor
writes the rows its vendored files need, from
[`baseline-agent/publish-allow.tsv`](../../baseline-agent/publish-allow.tsv), between
`# BEGIN baseline-agent allow` and `# END baseline-agent allow`. Rows outside the block are
the consumer's. The vendor never creates the file; its presence is the consumer's opt-in.
`check.sh` reports a block that differs as `publish-allow` drift.

Codex repo discovery is explicit: `--codex-discovery repo` creates relative links from
`.agents/skills/<name>` to `../../.claude/skills/<name>`. Use it only after runtime gate
approval. The default preserves the stamped mode, or `legacy` for unstamped consumers.
`legacy` creates no new discovery entries and does not delete existing ones. Customized
entries are preserved and reported for reconciliation. No link points into another checkout.

`check.sh <consumer>` reports version lag, content/marker drift, source policy mismatch,
unresolved shipped references, missing expected repo links, broken links and duplicate
repo skill names. It checks the current baseline payload, not a historical release fetched
from the consumer stamp. Expected content or version drift can use an accepted deviation ADR:

```yaml
---
status: accepted
field: rules/git-workflow.md
---
```

Use `agent-baseline-version` for a pin deviation. Missing references and invalid discovery
contracts remain failures; a text deviation must not hide unusable equipment.

## Profiles

| Profile | Assets |
|---|---|
| `docs` | Both policy/adapters, three rules, archive-plan/interview/plan-design/plan-writing, shared references, helper and optional model guides |
| `app` | `docs` assets plus dev-workflow/verification-loop and implementer/spec-reviewer definitions |

Claude uses `.claude` assets. Codex uses its actual skill catalog and explicit repo equipment;
Claude agent definitions and frontmatter do not grant Codex capabilities. Runtime tools are
conditional, with equipped local execution or a routed handoff as fallback. Model guides are
on-demand references, never all loaded by default. Release notes stay with the estate that
publishes a release and record installed-runtime evidence and limits.

## Global ownership transition

```bash
scripts/agent/global-install.sh --check
scripts/agent/global-install.sh --bootstrap-source /path/to/bootstrap --check
```

Installation without `--check` is a separate machine rollout action. It preserves unknown
files/links and never creates, deletes or replaces `~/.codex/AGENTS.md`.

| Owner | Paths |
|---|---|
| Baseline | `~/.config/manyfold/agent-policy.md` -> path-derived `baseline-agent/POLICY.md`; mailbox launcher and Claude/Codex mailbox links; interim global shared workflow links under `~/.codex/skills/local` |
| Bootstrap | `~/.codex/AGENTS.md` -> its `codex/AGENTS.md`; machine Claude instructions and conditional backstop pointers |
| Repository | Local `.claude` skill assets, environment overlays and enabled `.agents/skills` links |
| Provider | Bundled skills/plugins; this migration does not edit them |

Create `~/.config/manyfold` with mode `0700` only if absent. Never recursively alter existing
contents or load the directory as policy. Bootstrap creates credential files separately.

`--check` accepts only the exact former `<baseline>/baseline-agent/AGENTS.baseline.md`
symlink as `LEGACY (bootstrap replaces)`, or the exact existing bootstrap-owned target.
Unknown/wrong/missing links fail. Final combined bootstrap conformance rejects the legacy
link; using an old global installer afterwards reintroduces drift. Test both installer orders.

Keep user discovery at `~/.codex/skills`. Global checks inspect skill metadata only and reject
retired `sync-with-claude` even under `_retired`, plus a Codex name that two different skills
claim across existing user roots. Platform provisioning links one skill into several discovered
roots; entries resolving to the same file are one skill, never a duplicate.
Preserve/classify local customization outside discovered roots before retirement.
Remove active global capabilities only after every replacement real-consumer skill has passed
catalog/activation checks. A directory called `_retired` inside a discovered root is still active.

## Verification and publication

```bash
bats scripts/agent/check.bats scripts/publish-check/designation.bats
python3 -m unittest discover -s scripts/agent -p 'test_*.py'
python3 -m unittest discover -s baseline-agent/skills/agent-mailbox/scripts/tests
shellcheck -S warning scripts/agent/vendor.sh scripts/agent/check.sh scripts/agent/global-install.sh scripts/publish-check/designation.sh
```

`check.bats` also vendors a scratch consumer per profile without an overlay and with an
empty allow file, and runs the publication gate over it in shape-only mode: a payload change
that brings a new shape fails there until `publish-allow.tsv` carries its row.

Tests use scratch app/docs consumers and homes, disposable Git repositories and mocked domain
commands. No live infrastructure, credentials, global install or model batch is required.

Every commit changing profile-vendored payload also bumps `baseline-agent/VERSION` and
self-vendors the docs profile. Test the working candidate in scratch consumers, obtain the
required canary/release gate, stage explicit owned paths, commit, pull with rebase, reverify
and push without force. The cockpit then re-vendors every stamped consumer, including both
bootstrap root and nested workspace. Publication precedes consumer vendoring. Report expected
version lag during convergence; do not suppress content errors or claim estate conformance.
