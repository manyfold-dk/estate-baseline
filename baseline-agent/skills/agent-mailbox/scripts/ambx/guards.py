"""Input sanitization and body safety guards."""

from __future__ import annotations

import re

SUBJECT_SLUG_MAX = 50
BODY_MAX_BYTES = 64 * 1024

_SLUG_RE = re.compile(r"[^a-zA-Z0-9._-]+")

# High-signal secret markers. Intentionally conservative -- meant to catch
# obvious pastes, not to be a full scanner.
SECRET_PATTERNS = [
    ("a PEM/private-key block", re.compile(r"-----BEGIN")),
    ("an AWS access key id", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("a Slack token", re.compile(r"xox[baprs]-")),
    ("a GitHub token", re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}")),
    ("a JWT", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.")),
    ("an inline password", re.compile(r"password\s*[:=]", re.IGNORECASE)),
]


def slug(value: str) -> str:
    cleaned = _SLUG_RE.sub("-", value.strip()).strip("-")
    return cleaned.lower() or "message"


def subject_slug(value: str, limit: int = SUBJECT_SLUG_MAX) -> str:
    return slug(value)[:limit].strip("-") or "message"


def scan_secrets(body: str) -> list[str]:
    return [name for name, rx in SECRET_PATTERNS if rx.search(body)]


def check_body(body: str, allow_unsafe: bool) -> None:
    """Refuse bodies that look like secrets or are oversized, unless overridden."""
    if allow_unsafe:
        return
    hits = scan_secrets(body)
    if hits:
        raise SystemExit(
            "refusing to post: body appears to contain " + ", ".join(hits)
            + ". Reference a path/commit/command instead, or pass --allow-unsafe."
        )
    size = len(body.encode("utf-8"))
    if size > BODY_MAX_BYTES:
        raise SystemExit(
            f"refusing to post: body is {size} bytes (limit {BODY_MAX_BYTES}). "
            "Link to a file/commit instead, or pass --allow-unsafe."
        )
