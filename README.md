# estate-baseline

Drift checks and handoffs for a set of repositories run to one standard, by people and by
coding agents.

Several repositories drift in predictable ways. A Maven wrapper falls behind the version
everyone agreed on. The ADR index stops matching the ADR files. A plan lives in one repo and
nobody sees it from the others. Two coding agents work on the same task and have no way to
hand it over. Each tool here catches one of those, and each one fails CI rather than warn.

| Tool | Catches | Run |
|---|---|---|
| [`baseline-agent`](baseline-agent/POLICY.md) | Coding agents that follow different rules in different repositories. One policy with stable clause ids, adapters for each runtime, rules, skills and agent definitions, in two vendor profiles. Where the policy needs a value that belongs to one estate, it carries a placeholder the estate's private overlay fills. | vendored, see below |
| [`scripts/agent`](scripts/agent/README.md) | A consumer whose vendored rules drifted from the payload, or fell behind its version. `vendor.sh` copies a profile in and fills the placeholders from `--overlay`; `check.sh` reports drift; a recorded deviation ADR suppresses a finding. | `vendor.sh --profile app [--overlay dir]`, `check.sh [--overlay dir] <repo>` |
| [`scripts/conformance`](scripts/conformance/README.md) | A repository that drifts from the version manifest: compiler release, wrapper version, unpinned actions, workflows without `permissions:`, images without a digest, volumes without a backup annotation. A recorded deviation ADR suppresses a finding; silent drift does not. | `check.sh <repo> baseline.json` |
| [`scripts/docs`](scripts/docs/generate-adr-index.sh) | An ADR index that was typed by hand. The table in `docs/adr/README.md` is generated from the ADR files; `--check` fails when it differs. | `generate-adr-index.sh <repo> [--check]` |
| [`tools/plan-portfolio`](tools/plan-portfolio/generate.py) | Plans scattered across repositories. One portfolio page and one page per repository, rendered from the plans' front matter; `--check` fails on drift and writes nothing. | `generate.py [--check]` |
| [`scripts/publish-check`](scripts/publish-check/publish-check.sh) | A value on its way into a public repository: a name from your private list, an address, an internal host, an exact version, a path into a private repository, or anything two secret scanners flag. Exit 1 with file and line; scanner values are never printed. `--names none` runs the shapes only. | `publish-check.sh <dir> --names FILE\|none [--allow FILE]` |
| [`baseline-agent/skills/agent-mailbox`](baseline-agent/skills/agent-mailbox/SKILL.md) | Two coding agents that cannot message each other. `ambx` is a file-based mailbox with an audit trail; the skill file tells an agent when to use it and what it may not do with it. [Design](docs/design/agent-mailbox.md): locking, atomic delivery, a repairable outbox, and why identities are not authenticated. | `ambx <command>` |

## Principles

- **Generated, then checked.** Every index and page is rendered from source files, and CI
  runs the same generator in `--check` mode. Hand edits do not survive.
- **Drift is a failure, a deviation is a record.** A repository may differ from the baseline
  on purpose, by writing an ADR that says so. Anything else is red.
- **Exit codes mean something.** `0` clean, `3` drift, anything else a broken run. A
  scheduled job can tell "the consumer drifted" from "the checker crashed".
- **No dependencies to install.** Bash and the Python standard library. The tests need
  `bats` and `jq`.

## Getting started

```bash
git clone https://github.com/manyfold-dk/estate-baseline
cd estate-baseline

# Is this repository aligned with the manifest?
scripts/conformance/check.sh /path/to/repo /path/to/baseline.json

# Is its ADR index current?
scripts/docs/generate-adr-index.sh /path/to/repo --check

# What plans are open across my repositories?
python3 tools/plan-portfolio/generate.py \
  --repos /path/to/your-umbrella/docs/portfolio/repos.txt \
  --root /path/to/your/repositories --out /path/to/your-umbrella/docs/portfolio
```

The generator takes every location as an argument and derives nothing from where it is
installed: the repository list and the pages it renders name your repositories, so they
belong in a repository of yours, never in this checkout. `tools/plan-portfolio/repos.example.txt`
shows the list's shape. `baseline.json` is the version manifest your repositories agree
to; [`scripts/conformance/README.md`](scripts/conformance/README.md) documents its fields,
the rules and the deviation contract.

## Vendoring the policy

Run from inside the consumer repository. The house rules land between marker lines in
`CLAUDE.md` and `AGENTS.md`; the profile's rules, skills and references land under
`.claude/`; a stamp records what was vendored.

```bash
/path/to/estate-baseline/scripts/agent/vendor.sh --profile app --overlay /path/to/your-estate/overlay
/path/to/estate-baseline/scripts/agent/check.sh --overlay /path/to/your-estate/overlay .
```

The overlay directory holds one file per placeholder in the policy (`<name>.md` for
`<!-- name-overlay -->`). Today there is one: `working-across-repositories.md`, the table of
repositories in your estate. Without `--overlay` the placeholder stays, which is right for a
repository outside any estate.

## Tests

```bash
bats scripts/agent scripts/conformance scripts/docs scripts/publish-check
( cd scripts/agent && python3 -m unittest )
( cd baseline-agent/skills/agent-mailbox/scripts && python3 -m unittest )
( cd tools/plan-portfolio && python3 -m unittest )
```

CI runs exactly these on every push and pull request.

## Decisions

[`docs/adr/`](docs/adr/README.md) records the decisions behind this repository, starting with
the rule that decides what is published here and what is not.

## Best practices

[`docs/best-practices.md`](docs/best-practices.md): the lessons behind several of these checks,
from digest pinning and checksum verification to Argo CD drift and metric cardinality.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE).
