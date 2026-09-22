# Contributing

This repository is the public half of one estate's baseline, maintained by one person. What
changes here follows what that estate needs. Issues are welcome. Pull requests are read, and
merged when they fit; there is no promise of either.

## Before you open a pull request

- Run the tests in the [README](README.md#tests). CI runs the same commands and nothing else.
- Keep one logical change per pull request, with [Conventional Commits](https://www.conventionalcommits.org/)
  messages (`fix:`, `feat:`, `docs:`, `test:`, `ci:`).
- A generated file changes through its generator. A hand edit fails the `--check` run.

## What CI does with your pull request

- **Workflows from outside contributors wait for approval.** The owner starts them after
  reading the change.
- **A pull request from a fork gets no secrets.** No workflow here runs on
  `pull_request_target`, and the reusable workflows receive their secrets only from the
  repository that calls them.
- **The publication gate runs on every pull request.** A hit fails the run: an address, an
  internal host, an exact version, a path into a private repository, or anything a secret
  scanner flags. A test that needs such a value assembles it at run time, as the existing
  fixtures do. Do not add it to `.publish-allow.tsv` to get past the gate; say why in the
  pull request instead.

Changes to `scripts/publish-check/`, `.github/workflows/`, `.github/actions/` and
`baseline-agent/POLICY.md` get a closer review than the rest, because consumers run them with
their own credentials or treat them as rules.

## Licence

By contributing you agree that your contribution is licensed under Apache-2.0, the licence of
this repository (section 5 of [`LICENSE`](LICENSE)). There is no contributor licence agreement.

## Security

Do not report a vulnerability in an issue. See [`SECURITY.md`](SECURITY.md).
