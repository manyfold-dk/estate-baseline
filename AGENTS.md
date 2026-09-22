# estate-baseline -- Codex

Read [CLAUDE.md](CLAUDE.md); the same rules apply to every runtime. In short: this
repository is designated public, so run `scripts/publish-check/publish-check.sh` before
every push and treat a hit as a stop; it is the upstream source of `baseline-agent/`, not
a consumer of it; every value a public file needs is an overlay placeholder; and the
checks in `CLAUDE.md` run before a push. Use only the tools the active runtime exposes.
