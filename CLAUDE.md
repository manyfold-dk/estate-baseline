# estate-baseline

The public half of a baseline: the policy coding agents vendor, the tooling that keeps a
set of repositories to one standard, and reusable CI. The private half of an estate pins
this repository by commit and adds its values. The rule for what lives where, and the
checks that hold it, is [ADR 0001](docs/adr/0001-public-standard-private-values.md).

## Working here

- **This repository is designated public.** Nothing here names a tenant, a client, a private
  repository, a host, an address, an exact version in use or a credential (clause
  `PUBLISH-02` in [`baseline-agent/POLICY.md`](baseline-agent/POLICY.md)). Before every
  push run the gate: `scripts/publish-check/publish-check.sh . --names <private list>
  --allow .publish-allow.tsv`; without a private list, `--names none` checks the shapes.
  A hit is a stop. Test fixtures assemble any value shape at run time (see
  `scripts/publish-check/publish-check.bats`) so the file itself carries none.
- **This is the source of the agent payload.** `baseline-agent/` is edited here; consumers
  vendor it with `scripts/agent/vendor.sh` and are checked with `scripts/agent/check.sh`
  ([`scripts/agent/README.md`](scripts/agent/README.md)). Bump `baseline-agent/VERSION` in
  every commit that changes profile-vendored payload. This repository does not vendor
  itself; it is the upstream.
- **A value a public file needs is a placeholder** (`<!-- name-overlay -->`), filled by the
  consumer's overlay at vendor time. Never scrub a copy.
- **Reusable workflows pin this repository's own actions by commit** (`uses:
  <org>/estate-baseline/.github/actions/<name>@<sha>`), so a change to an action lands in
  two commits: the action, then the pins.
- **Checks:** `bats scripts/agent scripts/conformance scripts/docs scripts/publish-check
  .github/actions/*`, `python3 -m unittest` in `scripts/agent`,
  `baseline-agent/skills/agent-mailbox/scripts` and `tools/plan-portfolio`, `shellcheck`
  on every script, `actionlint` on the workflows. CI runs the same on every push.
- Work on the current branch; never create a branch unless asked. Conventional Commits.
  Markdown with `--`, not an em dash; MADR ADRs in `docs/adr/` with the generated index.
