"""Message construction, threading, reading, and archiving."""

from __future__ import annotations

import os
import secrets
from pathlib import Path
from typing import Any

from . import store
from .guards import slug, subject_slug

MAX_FILENAME_BYTES = 255


def new_id() -> str:
    return secrets.token_hex(4)


def _stamp_of(path: Path) -> str:
    return path.name.split("-", 1)[0]


def newest_stamp(messages: list[Path]) -> str:
    return max((_stamp_of(m) for m in messages), default="")


def build_filename(stamp_value: str, msg_id: str, sender: str, recipient: str,
                   kind: str, subject: str) -> str:
    prefix = f"{stamp_value}-{msg_id}-{slug(sender)}-to-{slug(recipient)}-{slug(kind)}-"
    subj = subject_slug(subject)
    name = f"{prefix}{subj}.md"
    if len(name.encode("utf-8")) > MAX_FILENAME_BYTES:
        room = MAX_FILENAME_BYTES - len(f"{prefix}.md".encode("utf-8"))
        subj = subj.encode("utf-8")[: max(room, 1)].decode("utf-8", "ignore").strip("-") or "m"
        name = f"{prefix}{subj}.md"
    return name


def find_by_id(base: Path, msg_id: str) -> list[tuple[Path, dict[str, str]]]:
    matches: list[tuple[Path, dict[str, str]]] = []
    for box in ("inbox", "outbox", "archive"):
        d = base / box
        if not d.exists():
            continue
        for f in d.rglob("*.md"):
            fm = store.parse_frontmatter(f)
            if fm.get("id") == msg_id:
                matches.append((f, fm))
    matches.sort(key=lambda pair: pair[0].name)  # earliest stamp first
    return matches


def resolve_thread(base: Path, reply_to: str | None) -> tuple[str | None, str | None]:
    """Return (thread, warning). thread is None when there is no reply_to."""
    if not reply_to:
        return None, None
    matches = find_by_id(base, reply_to)
    if not matches:
        return reply_to, "missing"          # parent not local: treat ref as root
    warn = "ambiguous" if len(matches) > 1 else None
    thread = matches[0][1].get("thread") or reply_to
    return thread, warn


def post_message(base: Path, task: str, sender: str, recipients: list[str], kind: str,
                 subject: str, body: str, reply_to: str | None = None) -> dict[str, Any]:
    sender = slug(sender)
    created = store.iso_now()
    msg_id = new_id()
    inherited, warn = resolve_thread(base, reply_to)
    thread = inherited if inherited is not None else msg_id
    stamp_value = store.stamp()
    delivered: list[Path] = []
    for recipient_raw in recipients:
        recipient = slug(recipient_raw)
        store.ensure_layout(base, [sender, recipient])
        name = build_filename(stamp_value, msg_id, sender, recipient, kind, subject)
        lines = ["---", f"task: {slug(task)}", f"id: {msg_id}", f"thread: {thread}"]
        if reply_to:
            lines.append(f"reply_to: {reply_to}")
        lines += [
            f"from: {sender}", f"to: {recipient}", f"kind: {slug(kind)}",
            f"subject: {subject}", f"created_at: {created}", "---", "",
            f"# {subject}", "", body.rstrip(), "",
        ]
        content = "\n".join(lines)
        inbox_path = base / "inbox" / recipient / name
        outbox_path = base / "outbox" / sender / name
        store.atomic_write_text(inbox_path, content)    # delivery is authoritative
        store.atomic_write_text(outbox_path, content)   # best-effort mirror
        delivered.append(inbox_path)
    return {"id": msg_id, "thread": thread, "warn": warn, "delivered": delivered}


def list_inbox(base: Path, agent: str, unread: bool = False, thread: str | None = None,
               all_msgs: bool = False, limit: int = 20, cursor: str = "") -> list[Path]:
    inbox = base / "inbox" / slug(agent)
    if not inbox.exists():
        return []
    messages = sorted(inbox.glob("*.md"))
    if unread:
        messages = [m for m in messages if _stamp_of(m) > cursor]
    if thread:
        messages = [m for m in messages if store.parse_frontmatter(m).get("thread") == thread]
    if not unread and not thread and not all_msgs:
        messages = messages[-limit:]
    return messages


def archive_read(base: Path, agent: str, cursor: str) -> int:
    if not cursor:
        return 0
    inbox = base / "inbox" / slug(agent)
    if not inbox.exists():
        return 0
    dest = base / "archive" / slug(agent)
    dest.mkdir(parents=True, exist_ok=True)
    moved = 0
    for m in sorted(inbox.glob("*.md")):
        if _stamp_of(m) <= cursor:
            os.replace(m, dest / m.name)
            moved += 1
    return moved
