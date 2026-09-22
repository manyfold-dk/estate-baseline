"""Scan a repo for plan/spec items under docs/ and apps/*/docs/."""
from __future__ import annotations
import os
import re
from datetime import date

import frontmatter
import model
import priority

_DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")
_HEADING_RE = re.compile(r"^#\s+(.+?)\s*$", re.MULTILINE)
_SKIP = {"INDEX.MD", "README.MD"}


def _infer_status(bucket: str) -> str:
    return "draft" if bucket == "active" else bucket


def _title(body: str, fallback: str) -> str:
    m = _HEADING_RE.search(body)
    return m.group(1).strip() if m else fallback


def _created(filename: str) -> str | None:
    m = _DATE_RE.search(filename)
    return m.group(1) if m else None


def _build_item(full, rel, repo_name, today) -> model.PlanItem:
    with open(full, encoding="utf-8") as fh:
        text = fh.read()
    fm, body = frontmatter.parse(text)
    bucket = model.folder_bucket(rel)
    segs = rel.replace("\\", "/").split("/")
    doc_type = fm.get("type") or ("spec" if "specs" in segs else "plan")
    status = fm.get("status") or _infer_status(bucket)
    item = model.PlanItem(
        repo=repo_name, path=rel, doc_type=doc_type,
        title=fm.get("title") or _title(body, os.path.basename(rel)),
        status=status, priority=fm.get("priority"), computed_priority=None,
        owner=fm.get("owner"), source=fm.get("source"),
        created=fm.get("created") or _created(os.path.basename(rel)),
        updated=fm.get("updated"), has_frontmatter=bool(fm))
    item.computed_priority = priority.compute(item, today)
    item.flags = model.detect_flags(item, bucket, today)
    return item


def scan_repo(repo_root: str, repo_name: str, today: date) -> list:
    items: list = []
    bases = ["docs/plans", "docs/specs"]
    roots: list[str] = [os.path.join(repo_root, b) for b in bases]
    apps_dir = os.path.join(repo_root, "apps")
    if os.path.isdir(apps_dir):
        for app in sorted(os.listdir(apps_dir)):
            for b in bases:
                roots.append(os.path.join(repo_root, "apps", app, b))
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirs, files in os.walk(root):
            for fn in sorted(files):
                if not fn.endswith(".md") or fn.upper() in _SKIP:
                    continue
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, repo_root)
                items.append(_build_item(full, rel, repo_name, today))
    return items
