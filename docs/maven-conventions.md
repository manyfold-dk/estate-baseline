# Maven conventions

How the Quarkus applications of an estate share one build without copying it. The versions
live in the estate's private build parent and its version manifest; this page is the pattern.
The manifest's shape is [`scripts/conformance/baseline.schema.json`](../scripts/conformance/baseline.schema.json),
with an invented [example](../scripts/conformance/baseline.example.json).

## One parent POM, published to a private registry

Every application inherits one `pom`-packaged parent. It carries:

| In the parent | Why there |
|---|---|
| `maven.compiler.release`, `project.build.sourceEncoding` | One JDK and one encoding for every module |
| The Quarkus BOM, imported in `dependencyManagement` | Quarkus and everything it manages move together, in one line |
| Versions of shared test dependencies the BOM does not manage | Applications declare the dependency without a `<version>`, so the pins cannot drift apart |
| One `surefire-plugin.version` property for both Surefire and Failsafe | The two plugins release together; two properties drifted in practice |
| Surefire and Failsafe `systemPropertyVariables` (`java.util.logging.manager`, `maven.home`) | The Quarkus test defaults, set once |
| `quarkus-maven-plugin` with its goals, in `pluginManagement` | See below |

**The Quarkus plugin goes in `pluginManagement`, not `build/plugins`.** A `pom`-packaged parent
with the plugin under `build/plugins` tries to run Quarkus goals when the parent itself is
installed. In `pluginManagement` it only configures. Each application keeps a bare reference
-- group id, artifact id and `<extensions>true</extensions>` -- and inherits the version and
the goals. List every goal the applications use; an application that relied on a goal the
parent omits loses it without a warning.

App-specific test configuration, such as running `*IT` classes under Surefire, stays in the
application.

## Resolving the parent needs settings.xml, not only a server entry

Maven resolves the parent POM before it reads the project's own `<repositories>`. A repository
declared in the application's POM is therefore too late for the parent. The repository has to
come from an active profile in `settings.xml`, next to a `<server>` entry with the same id.

Two layouts, both supported by the reusable [Quarkus workflows](../.github/workflows/README.md#quarkus-caller-contract):

- **Committed settings.** `.mvn/settings.xml` in the module, activated by `-s .mvn/settings.xml`
  in `.mvn/maven.config`, with the password read from the environment
  (`${env.MAVEN_REGISTRY_TOKEN}`). Local builds and CI behave the same; a developer exports one
  variable. The [scaffold](../template/README.md) ships this layout.
- **Generated settings.** No settings in the module; CI writes `~/.m2/settings.xml` with the
  [`setup-maven-registry`](../.github/actions/setup-maven-registry/action.yml) action.

The server id must match everywhere it appears: the `<server>`, the profile's
`<repository>`, and the parent's `distributionManagement` when the parent is deployed.

## Held to the manifest, not to memory

The version manifest names each value and the bucket it belongs to. The buckets state intent;
the [checker](../scripts/conformance/check.sh) does not read them, and it compares two fields,
whichever bucket they sit in:

| Bucket | Meaning | What the checker compares |
|---|---|---|
| `inherited` | The parent carries the value | `maven.compiler.release` in every application POM that declares it. Other inherited values, such as the Quarkus platform or Surefire version, are held by inheritance alone: an application POM that overrides one is not flagged. |
| `policed` | The parent cannot carry it | `maven.wrapper.version` against `.mvn/wrapper/maven-wrapper.properties` |
| `informational` | Published for people and CI images | Nothing |

The checker also runs the structural rules the manifest lists (action pinning, workflow
permissions, image digests, volume backup annotations). An application that must differ
records a deviation ADR, and the checker accepts that one difference
([deviation contract](../scripts/conformance/README.md#deviation-adr-contract)). A new value
to hold needs a check in `check.sh`; listing it in a bucket is not enough.

## Why the parent is not public

The parent pins the versions in use. Publishing it would map the estate's patch level, so it
stays in a private package registry, and consumers read it with a token that has read access
to packages. For GitHub Packages that is a classic token with `read:packages`, or the calling
repository's own `GITHUB_TOKEN` when the package is linked to that repository.
