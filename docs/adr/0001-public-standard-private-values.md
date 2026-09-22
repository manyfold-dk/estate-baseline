# ADR 0001: The standard is public, the values are private

## Status

Accepted -- 2026-09-22.

Amended the same day after a publication readiness review: the three audiences, one
authored source, generated output, the GitHub surfaces a publication covers, and what a
check cannot decide.

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
carries a value. The line is drawn through a file's contents, not its kind: a design record
is public when its values are out, and a workflow is private when a value is in.

| Public half (this repository) | Private half |
|---|---|
| Policy, rules, skills, agent definitions, references, model guidance | The estate map: which repositories exist and what each is for |
| Tooling that operates on a consumer repository: vendor, drift check, conformance check, index generators, the publication gate | The version manifest and the build parent |
| Reusable workflows and composite actions that take every value as an input | The consumer matrix, token contracts, registry paths |
| Generic patterns of the publication gate: the shapes of addresses, hosts, versions, repository paths; an allow file of shape values for this repository | The name deny-list |
| Test fixtures with invented values | Operational notes, incident records, recovery weaknesses |
| The reasoning behind public code: a design record or decision with its values and its migration details taken out, its date and its limits kept | The same record as it was written, with the values in, until a public version of it is authored |

**Three audiences, not two.** "Private" is a location, not an audience. The private half
serves two audiences that must not be confused: **consumer-shareable** content that every
repository pulling the baseline may read (the build parent, the version manifest, the
scaffold), and **operator-only** content that no consumer needs (the name deny-list, the
consumer matrix, token contracts, the estate map's operational notes). A file in the private
half says which of the two it is when the distinction matters, and a tenant is never granted
the repository as a whole on the strength of "it contains nothing sensitive".

**Direction of flow.** The public half is upstream. The private half pins it by commit id
in a lock file and composes its values in at vendor time through an overlay. Reusable
workflows are called from private to public, never the reverse.

**One authored source.** Every file has exactly one place where it is edited. A copy of a
public file exists in a private repository only as a generated artefact that records the
public commit it came from and has a check that reports when the two differ: the vendored
policy payload with its stamp, a workflow pin at the lock. An editable duplicate is a
defect, whatever it is called.

**Placeholders, not scrubbing.** Where a public file needs a value, it carries a marked
placeholder that the private overlay fills. The public file is never edited for
publication, so there is one version of it.

**Generated output inherits the sensitivity of its inputs.** A portfolio rendered from
private plans, a conformance report, a rendered document, a CI log, build metadata: each is
as private as the most private thing that went into it, and a tool in the public half that
renders such output takes the output location as an argument and never derives it from
where the tool is installed.

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

**What a check cannot decide.** The gate recognises shapes. Whether a version string is an
example or the version deployed, whether a host name is a fixture or the live one, is
context the gate does not have. So the allow file is a list of reviewed exceptions with a
reason each, the fixtures assemble their values at run time so that no literal needs
allowing, and the owner's prohibition on publishing a deployed value stands above any
allow row. The check narrows what a reviewer has to look at; it does not replace the
reviewer.

**Publication covers the whole repository object.** Making a repository public publishes
every branch and tag name, every tag message, every reachable blob in every commit,
Actions logs and artifacts, and every commit that is still retrievable by id although no
ref reaches it. "Fresh history" is a property of a repository object, not of a branch: it
is obtained by creating a new repository and pushing only the approved commits, never by
rewriting a branch in place.

## Rationale

The line is a test a person or an agent can apply to one file with little context: does
this file carry a value? Categories that depend on judgement ("is this sensitive?") drift
with the reviewer; a shape and a name list drift less, and where judgement remains (a
version that is an example) the allow file records it once, with its reason, instead of
leaving it to each reader. Composition at the point of use means a consumer receives
exactly what it received from one repository, so the split costs consumers nothing.
Public-as-upstream is the only direction in which a fix lands once.

## Consequences

**Checks that hold the line.** Each runs without anyone remembering to run it. The first
four prevent; the last three detect after the fact, and the ADR says which is which.

| Check | When | What it refuses |
|---|---|---|
| A `gitleaks` pre-commit hook, scoped to every repository under the estate directory | every commit, human or agent | a credential entering history |
| A pre-push hook running the publication gate with the private name list, from the gate pinned at the estate's lock | every push from a clone of a repository designated public | in every commit new to the remote: a name, an address, a host, a version, a repository path or a scanner finding in its tree, its message or its paths; a name in the branch or tag being pushed or in a tag message; before anything leaves the machine |
| The publication gate in shape-only mode, in this repository's CI | every push to any branch here, and every pull request | an address, host, version or repository path in the public half |
| Policy clause `PUBLISH-02` in the house rules every consumer vendors | every agent session | an agent pushing to a public-designated repository without the gate, or copying the name list anywhere public |
| The `secret-scan` reusable workflow | every pull request and push, every repository | the same as the pre-commit hook, where `--no-verify` cannot skip it |
| A weekly publication check in the private half | schedule and dispatch | a name on any branch of this repository, in any commit message, in any historical path, blob, branch name, tag name or tag message; a credential anywhere in its history; a lock that is not a full commit id on `main` here |
| GitHub push protection, a protected `main` with the checks above required | from the day the repository is public | a credential pushed by anyone; a change to the gate or a workflow that did not pass the gate |

**Routines.** A new public repository is created private and an owner flips it after
review; the flip is preceded by the gate over every branch and the whole history, and by
the decision whether the repository object itself is fresh. A term leaves the name list
only by the owner's hand, and only when the thing it names is public. A publication step
without a clean gate result is not done. A file moves from private to public by being
edited in place until the gate passes, then moved; never by scrubbing a copy that stays.

**What no check catches.** A push from a machine without the hooks reaches a branch here
before the weekly check sees it. On a public repository that is a disclosure for up to a
week, and deleting the branch does not undo it. The hooks are installed on every machine
the estate is worked from, and the weekly check is detection, not prevention; the ADR says
so rather than pretending otherwise.

**Costs.** Two repositories to keep in step, held by the lock and its check. A placeholder
in the public policy that reads as a gap to a reader outside any estate. A weekly job in
the private half that needs read access to this repository while it is still private. A
public version of a design record is a second document to keep true, which is why the
private original says when a public version exists.
