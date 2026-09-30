# Conformance checks

## baseline.json

The version manifest a set of repositories agrees to. `fields` holds the values;
`enforcement` says how each one is held to.

Its shape is [`baseline.schema.json`](baseline.schema.json) (JSON Schema 2020-12), with an
invented [`baseline.example.json`](baseline.example.json). `manifest.bats` holds the example to
the schema's structure and checks what the schema cannot say: every bucket entry names a key of
`fields`, and each field sits in exactly one bucket. The schema is not validated by a JSON
Schema engine in CI; this repository installs none.

| Bucket | Meaning | Fields |
|---|---|---|
| `policed` | A file in the consumer must match; the parent POM cannot carry it | `maven.wrapper.version` |
| `inherited` | Carried by the parent POM; the checker greps the consumer's POMs for a contradicting value | `maven.compiler.release`, `quarkus.platform.version`, `surefire.plugin.version` |
| `informational` | Published for humans and CI images; not checked | `build.jdk.image`, `runtime.jre.image`, `node.version`, `pnpm.version` |
| `rules` | Structural checks that need no value | the four `workflow.*` and `manifest.*` rules below |

`check.sh` today checks `maven.compiler.release`, `maven.wrapper.version` and the rules.

## Conformance rules

`check.sh <consumer-dir> baseline.json` runs the checks below. Each rule id doubles as the
deviation `field:` that suppresses it. Exit codes: 0 clean / 3 drift / other = script error.

| Rule (deviation `field:`) | Checks | How |
|---|---|---|
| `maven.compiler.release` | app POMs match the baseline JDK | POM grep |
| `maven.wrapper.version` | the Maven wrapper matches (not POM-inheritable) | properties grep |
| `workflow.action-pinning` | every remote `uses:` ref is a 40-hex commit SHA | workflow grep |
| `workflow.permissions` | every workflow declares a top-level `permissions:` block | workflow grep |
| `manifest.image-digest` | workload `image:` lines are `@sha256:`-pinned | manifest grep |
| `manifest.pvc-backup-annotation` | PVC-bearing manifests carry `backup.velero.io/backup-volumes` | manifest grep |

**Heuristics (grep, not a YAML parser -- documented limitations):**

- `workflow.action-pinning` exempts local `./` refs, `docker://` refs, commented-out lines, and
  **same-repo self-references** (a repo referencing its own actions/workflows cannot take a
  dynamic same-repo SHA and is not a third-party supply-chain risk -- like a `./` ref). A ref to
  a *different* repo is always checked.
- `workflow.permissions` keys on a `permissions:` line at column 0; a valid job-level-only layout
  reads as drift -- record a deviation ADR if you use one.
- `manifest.image-digest` keys on a file-level workload `kind:` and skips `$`-templated images.
- `manifest.pvc-backup-annotation` implements the platform's opt-in fs-backup model (its ADR-0020);
  a legitimately unbacked volume (regeneratable data) is a recorded deviation, not silent drift.

## Deviation ADR contract

A consuming repo records a justified divergence as a MADR ADR under its `docs/adr/` with
this frontmatter. The conformance job parses it to suppress *expected* drift:

```yaml
---
status: accepted
deviation-from: baseline v1.0
field: maven.compiler.release   # the baseline.json key being diverged
tenant-value: "26"
baseline-value: "25"
reason: needs an early JDK 26 fix not yet in the baseline
reconverge: when baseline moves to Java 26
---
```

Only `status: accepted` ADRs whose `field` matches the drifting key suppress a finding.

### Scope

Without `paths:`, a deviation suppresses its field in every file of the repo. A new
finding of the same rule is then silent as well. `paths:` limits the deviation to the files
it names, so the rule still reports every other file:

```yaml
---
status: accepted
deviation-from: baseline v1.1
field: manifest.image-digest
tenant-value: "<image>:main-<commit>, written by the deploy job"
baseline-value: "<image>@sha256:<digest>"
reason: the deploy job writes a per-commit tag, not a digest
reconverge: when the deploy job writes <tag>@<digest>
paths:
  - services/front/base/deployment.yaml
  - deploy/local/*
---
```

- Each entry is a shell glob, matched against the finding's path from the repository root.
  `*` also crosses `/`, so `deploy/local/*` covers every file below `deploy/local/`.
- The checker reads `paths:` from the frontmatter only, as a block list with one glob per
  `- ` line. Comments and blank lines inside the list are allowed.
- A `paths:` with an inline value (`paths: [a, b]`) or with no entry is a tooling error
  (exit 2), not an unscoped deviation.
- Prefer `paths:` for any deviation that covers some files and not the rule as a whole.

