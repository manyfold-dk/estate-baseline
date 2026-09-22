# ADR 0002: Shared agent policy with independent runtime adapters

## Table of Contents

- [Status](#status)
- [Context](#context)
- [Decision](#decision)
- [Consequences](#consequences)

## Status

Accepted -- 2026-09-05, within an owner-approved modernization of the agent harness.

This decision amends the runtime loading and handoff details of an earlier, unpublished
decision on the agent instruction baseline. Its vendor/conformance model and write-set
altitude boundaries remain in force.

## Context

Shared workflows duplicated policy, assumed Claude-only tools and imposed planning and
review loops regardless of task intent. Main-branch review ranges missed task commits.
Global baseline imports duplicated consumer policy and competed with bootstrap ownership.
The original distribution design already provides profiles, outer marker blocks and
conformance checks.

## Decision

Maintain [`POLICY.md`](../../baseline-agent/POLICY.md) (in this repository since
2026-09-22, under `baseline-agent/`) as the common policy source with stable clause
identifiers. Both baseline runtime entry sources contain equal inner policy blocks.
Runtime-specific sections remain outside those blocks. Reuse vendor/check tooling; introduce
no renderer, state service, model dispatcher, or custom conversation-history implementation.

Both profiles ship the optional read-only task-scope helper and all retained references.
Task owners maintain passive worktree-local Git notes. Recorded commits and optional trailers
are attribution evidence, never proof. Archive inspection pins fresh remote main without
rebasing or changing the checkout/index.

Repository overlays own domain commands and boundaries. Neutral instructions are the default;
model guides are selected explicitly for a confirmed model. Runtime discovery activates only
after evidence for installed versions. Repo links target local `.claude/skills`, never another
checkout.

Bootstrap owns `~/.codex/AGENTS.md` and Claude machine instructions. Baseline global install
owns the non-autoload `~/.config/manyfold/agent-policy.md` link and shared skill/launcher wiring.
Bootstrap adapters consult that exact policy file only without a loaded baseline block.

## Consequences

Common output deliberately duplicates policy for independent loading. Tests enforce equality,
shipped references and local discovery wiring; model canaries establish behavior separately.
Conservative installation preserves customized files instead of replacing them silently.
Global capability retirement requires equivalent real-consumer access and archived local
customization.

Common workflow names can still appear at both repository and user scope because the global
installer retains compatibility links. This is an explicit migration limitation, not a
claim of universal duplicate-free discovery. A follow-up plan retains that work and the
remaining runtime/evaluation gates.

---

Published version: private links and the details of one installer migration removed;
reasoning unchanged.
