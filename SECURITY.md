# Security

Report a vulnerability privately through GitHub: the **Security** tab of this repository,
then **Report a vulnerability**. Do not open a public issue or pull request for it.

In scope:

- The publication gate passes a value it is documented to catch, or prints a scanner finding's
  value.
- A reusable workflow or composite action lets untrusted input reach a shell, exposes a
  secret, or publishes from a pull request.
- `vendor.sh`, `check.sh` or `ambx` reads or writes outside the directory it was given.

One person maintains this repository. Expect an acknowledgement within a week and a fix or a
decision after that; there is no service level. Fixes land on `main`; consumers pin a commit,
so a fix reaches them when they move their pin.
