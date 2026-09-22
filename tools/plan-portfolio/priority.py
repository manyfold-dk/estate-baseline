"""Heuristic priority ranking. A human-set `priority` field always wins."""
from __future__ import annotations
from datetime import date, datetime

import model

_SEC_KEYWORDS = ("security", "secret", "credential", "rotation", "backup",
                 "restore", "supply-chain", "supply chain", "hardening",
                 "compliance", "gdpr", "isolation", "vault", "break-glass")


def _age_days(item, today: date) -> int:
    for s in (item.updated, item.created):
        if s:
            try:
                d = datetime.strptime(s.strip(), "%Y-%m-%d").date()
                return (today - d).days
            except ValueError:
                pass
    return 0


def compute(item, today: date) -> str:
    """Return a computed label like 'P1-computed'; '' for non-active items."""
    if item.status not in model.ACTIVE_STATUSES:
        return ""
    score = 0
    haystack = f"{item.path} {item.title}".lower()
    if any(k in haystack for k in _SEC_KEYWORDS):
        score += 2
    age = _age_days(item, today)
    if age > 30:
        score += 1
    if age > 90:
        score += 1
    if item.status in ("in-progress", "blocked"):
        score += 1
    if score >= 3:
        level = 0
    elif score == 2:
        level = 1
    elif score == 1:
        level = 2
    else:
        level = 3
    return f"P{level}-computed"
