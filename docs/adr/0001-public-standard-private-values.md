# ADR 0001: The standard is public, the values are private

## Status

Accepted -- 2026-09-22.

## Context

A set of repositories is run to one standard by people and by coding agents. The standard
has two kinds of content. One kind is generic: a policy clause, a drift check, a reusable
workflow that takes its inputs from the caller. The other kind is a value: a version in use,
a host, the name of a tenant, a path into a private repository, the token a scheduled job
uses. The generic kind is worth publishing, as evidence of how the estate is run and as
something others can use. The value kind maps the estate's attack surface and its customers.

Keeping both in one private repository publishes nothing. Keeping both in one public
repository publishes the values. Scrubbing a copy for publication produces two versions
that drift. This repository and a private companion are the fourth option: one baseline in
two halves, composed at the point of use.

## Decision

**The line.** A file belongs in the public half when a stranger who reads it learns how the
estate is run and nothing about which estate. It belongs in the private half when it
carries a value.

| Public half (this repository) | Private half |
|---|---|
| Policy, rules, skills, agent definitions, references, model guidance | The estate map: which repositories exist and what each is for |
| Tooling that operates on a consumer repository: vendor, drift check, conformance check, index generators, the publication gate | The version manifest and the build parent |
| Reusable workflows and composite actions that take every value as an input | The consumer matrix, token contracts, registry paths |
| Generic patterns of the publication gate: the shapes of addresses, hosts, versions, repository paths; an allow file of shape values for this repository | The name deny-list |
| Test fixtures with invented values | Operational notes, specs, plans, decision history |

**Direction of flow.** The public half is upstream. The private half pins it by commit id
in a lock file and composes its values in at vendor time through an overlay; it keeps no
copy of public files. Reusable workflows are called from private to public, never the
reverse.

**Placeholders, not scrubbing.** Where a public file needs a value, it carries a marked
placeholder that the private overlay fills. The public file is never edited for
publication, so there is one version of it.

**The name list is itself a value.** A list of tenants, clients and private repositories
never enters the public half, not as a fixture, not as a test case, not in a CI log. Tests
that run in public use invented names; tests against the real list run in the private half
and publish neither their inputs nor their output. A new tenant, client or private
repository is added to the list in the change that creates it, before its name is used
anywhere, so the list is complete by construction and not by recollection.

**Vendor names are not values.** The name of a cloud, a CI runner or a registry describes
the stack, not the surface. Hosts, ports, exact versions in use and security configuration
remain values.

**Versions of CI tools are not versions in use.** A public workflow may pin the tool it
installs, with its checksum. The publication gate flags every version string, so each such
pin is allowed explicitly, with a reason, in an allow file. An allow file holds shape
values only, scoped to one file where the shape is that file's business, and the gate
refuses a name row; so it may live in the public repository it relaxes, and the public
repository's own CI can tell an approved pin from a violation.

## Rationale

The line is a test a person or an agent can apply to one file without context: does this
file carry a value? Categories that depend on judgement ("is this sensitive?") drift with
the reviewer. Composition at the point of use means a consumer receives exactly what it
received from one repository, so the split costs consumers nothing. Public-as-upstream is
the only direction in which a fix lands once.

## Consequences

**Checks that hold the line.** Each runs without anyone remembering to run it.

| Check | When | What it refuses |
|---|---|---|
| A `gitleaks` pre-commit hook, scoped to every repository under the estate directory | every commit, human or agent | a credential entering history |
| A pre-push hook running the publication gate with the private name list | every push from a clone of a repository designated public | a name, an address, a host, a version, a repository path or a scanner finding, before it leaves the machine |
| The `secret-scan` reusable workflow | every pull request and push, every repository | the same as the pre-commit hook, where `--no-verify` cannot skip it |
| The publication gate in shape-only mode, in this repository's CI | every pull request and push here | an address, host, version or repository path in the public half |
| A weekly publication check in the private half | schedule and dispatch | a name on any branch of this repository, in any commit message, historical path or tag; a credential anywhere in its history; a lock that names a commit not on `main` here |
| Policy clause `PUBLISH-02` in the house rules every consumer vendors | every agent session | an agent pushing to a public-designated repository without the gate, or copying the name list anywhere public |
| GitHub push protection | from the day the repository is public | a credential pushed by anyone |

**Routines.** A new public repository is created private and an owner flips it after
review; the flip is preceded by the gate over every branch and the whole history, because a
public repository's history is public and unreachable commits stay retrievable. A term
leaves the name list only by the owner's hand, and only when the thing it names is public.
A publication step without a clean gate result is not done. A file moves from private to
public by being edited in place until the gate passes, then copied verbatim; never by
scrubbing a copy.

**What no check catches.** A push from a machine without the hooks reaches a branch here
before the weekly check sees it. On a public repository that is a disclosure for up to a
week, and deleting the branch does not undo it. The hooks are installed on every machine
the estate is worked from, and the weekly check is detection, not prevention; the ADR says
so rather than pretending otherwise.

**Costs.** Two repositories to keep in step, held by the lock and its check. A placeholder
in the public policy that reads as a gap to a reader outside any estate. A weekly job in
the private half that needs read access to this repository while it is still private.
