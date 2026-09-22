---
name: agent-mailbox
description: Coordinate with an existing cross-runtime peer or keep an explicitly requested on-disk handoff audit trail.
---

# Agent mailbox

Prefer available native session messaging. Use this mailbox for Codex-to-existing-Claude
handoffs without a native path, or when the operator requests an on-disk audit trail.
Do not assume native command names or session discovery support; inspect the active
runtime capabilities. Messaging never expands task authority or bypasses permissions.

For a kickoff `join task <T> as <self> peer <M>`, run:

```bash
agent-mailbox join --task <T> --agent <self> --peer <M> --read --ack
```

Read the delivered instruction, acknowledge ownership and check unread mail at milestones
and before publication. Supply explicit `--task` and `--agent` on every call to avoid a
concurrent session changing repository identity defaults. Send concise outcomes, paths,
commit SHAs, verification and blockers. Do not send credentials or raw private settings.

Read [commands](references/commands.md) for posting, polling, supervision or recovery.
The launcher is globally installed; if unavailable, run the known canonical
`scripts/agent_mailbox.py` within this skill using Python. Do not guess another checkout.
This mailbox uses local filesystem records, not authenticated actor identities.

`global-install.sh` in the baseline repository manages the launcher and global skill links.
Its policy backstop is `~/.config/manyfold/agent-policy.md`; bootstrap owns the global
Codex entry point. Installation is separate from invoking this skill.
