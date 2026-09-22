"""Plan lifecycle model: statuses, folder mapping, drift detection."""
from __future__ import annotations
from dataclasses import dataclass, field
from datetime import date, datetime

ACTIVE_STATUSES = {"draft", "ready-for-implementation", "in-progress", "blocked"}
DONE_STATUSES = {"implemented", "postponed", "superseded", "abandoned"}
ALL_STATUSES = ACTIVE_STATUSES | DONE_STATUSES

_FOLDER_TO_STATUS = {
    "implemented": "implemented",
    "archived": "implemented",
    "postponed": "postponed",
    "superseded": "superseded",
    "abandoned": "abandoned",
}

STALE_DAYS = 60


@dataclass
class PlanItem:
    repo: str
    path: str
    doc_type: str
    title: str
    status: str
    priority: str | None
    computed_priority: str | None
    owner: str | None
    source: str | None
    created: str | None
    updated: str | None
    has_frontmatter: bool
    flags: list = field(default_factory=list)


def folder_bucket(rel_path: str) -> str:
    """Status bucket implied by a file's folder under docs/plans|specs."""
    parts = rel_path.replace("\\", "/").split("/")
    for anchor in ("plans", "specs"):
        if anchor in parts:
            idx = parts.index(anchor)
            if idx + 2 < len(parts):  # anchor/<sub>/.../file.md
                sub = parts[idx + 1]
                if sub in _FOLDER_TO_STATUS:
                    return _FOLDER_TO_STATUS[sub]
            return "active"
    return "active"


def _parse_date(s: str | None) -> date | None:
    if not s:
        return None
    try:
        return datetime.strptime(s.strip(), "%Y-%m-%d").date()
    except ValueError:
        return None


def detect_flags(item: PlanItem, bucket: str, today: date) -> list:
    flags: list = []
    # Only active-bucket files are actionable: archived/done files are adequately
    # described by their folder, so absent frontmatter there is not flagged.
    if not item.has_frontmatter and bucket == "active":
        flags.append("needs-frontmatter")
    if item.status not in ALL_STATUSES:
        flags.append(f"unknown-status:{item.status}")
    status_active = item.status in ACTIVE_STATUSES
    if status_active and bucket != "active":
        flags.append("active-status-in-done-folder")
    if not status_active and bucket == "active":
        if item.status == "implemented":
            flags.append("implemented-not-archived")
        else:
            flags.append(f"{item.status}-not-moved")
    if status_active:
        ref = _parse_date(item.updated) or _parse_date(item.created)
        if ref is not None and (today - ref).days > STALE_DAYS:
            flags.append("stale")
    return flags
