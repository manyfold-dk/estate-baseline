"""Filesystem store: paths, locking, atomic IO, manifest/identity/status, repair.

All cross-process mutations of JSON state go through an advisory ``flock`` and an
atomic temp-file + ``os.replace``. This module is the only one that touches lock
files and the only one that knows the on-disk layout.
"""

from __future__ import annotations

import fcntl
import json
import os
import secrets
import subprocess
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from .guards import slug

DEFAULT_ROOT = Path(
    os.environ.get("AGENT_MAILBOX_ROOT", "~/Developer/Agent-Coordination")
).expanduser()
DEFAULT_TASK = os.environ.get("AGENT_MAILBOX_TASK") or None
DEFAULT_AGENT = os.environ.get("AGENT_MAILBOX_AGENT") or None
MAILBOX_VERSION = 2


# --- time -------------------------------------------------------------------

def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_now() -> str:
    return utc_now().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def stamp() -> str:
    return utc_now().strftime("%Y%m%dT%H%M%S%fZ")


# --- paths ------------------------------------------------------------------

def root_path(root: Any) -> Path:
    return Path(root).expanduser() if root else DEFAULT_ROOT


def mailbox_path(root: Any, task: str) -> Path:
    return root_path(root) / slug(task)


def identities_path(root: Any) -> Path:
    return root_path(root) / "identities.json"


def status_path(base: Path, agent: str) -> Path:
    return base / "status" / f"{slug(agent)}.json"


# --- locking ----------------------------------------------------------------

@contextmanager
def file_lock(lock_path: Path) -> Iterator[None]:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def mailbox_lock(base: Path):
    return file_lock(base / ".lock")


def identities_lock(root: Any):
    return file_lock(root_path(root) / ".identities.lock")


# --- JSON / atomic IO -------------------------------------------------------

def _recovery_hint(path: Path) -> str:
    name = path.name
    if name == "manifest.json":
        return "run `agent-mailbox repair --task <task>`"
    if name == "identities.json":
        return "run `agent-mailbox repair --identities`"
    if path.parent.name == "status":
        return "run `agent-mailbox repair --task <task>` to reset this status file"
    if path.parent.name == "agents":
        return "run `agent-mailbox repair --task <task>` to rebuild this agent record"
    return "fix or remove the file"


def load_json(path: Path, default: Any) -> Any:
    """Load JSON, raising a recovery-pointing error on corruption."""
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"corrupt JSON {path}: {exc}. Recovery: {_recovery_hint(path)}")


def safe_load(path: Path, default: Any) -> Any:
    """Load JSON, never raising -- used by repair and presence bumps."""
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{secrets.token_hex(4)}.tmp")
    try:
        tmp.write_text(content, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def write_json(path: Path, data: Any) -> None:
    atomic_write_text(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


# --- frontmatter ------------------------------------------------------------

def parse_frontmatter(path: Path) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    meta: dict[str, str] = {}
    for line in text[3:end].splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    return meta


# --- layout -----------------------------------------------------------------

def ensure_layout(base: Path, agents: list[str]) -> None:
    for rel in ("agents", "shared", "status"):
        (base / rel).mkdir(parents=True, exist_ok=True)
    for agent in agents:
        for rel in ("inbox", "outbox", "archive"):
            (base / rel / slug(agent)).mkdir(parents=True, exist_ok=True)


def write_readme(base: Path, task: str) -> None:
    readme = base / "README.md"
    if readme.exists():
        return
    readme.write_text("\n".join([
        f"# Agent Mailbox: {slug(task)}", "",
        "Shared filesystem mailbox for asynchronous agent coordination.", "",
        "- `manifest.json`: task metadata + registered agents.",
        "- `identities.json` (root): per-repo task/agent identity.",
        "- `inbox/<id>/`, `outbox/<id>/`, `archive/<id>/`: messages.",
        "- `status/<id>.json`: presence (state, last_seen) + read cursor.",
        "- `.lock` / `../.identities.lock`: flock targets.", "",
        "Do not store credentials, tokens, secrets, or large logs here.", "",
    ]), encoding="utf-8")


# --- manifest / agents / presence ------------------------------------------

def load_manifest(base: Path) -> dict[str, Any]:
    return load_json(base / "manifest.json", {})


def update_manifest(base: Path, task: str, agent: str, role: str,
                    repo: str | None, peers: list[str]) -> None:
    with mailbox_lock(base):
        path = base / "manifest.json"
        manifest = load_json(path, {
            "task": slug(task),
            "created_at": iso_now(),
            "mailbox_version": MAILBOX_VERSION,
            "agents": {},
        })
        manifest.setdefault("agents", {})
        manifest["mailbox_version"] = MAILBOX_VERSION
        manifest["updated_at"] = iso_now()
        manifest["agents"][slug(agent)] = {
            "role": role, "repo": repo or "", "last_seen_at": iso_now(),
        }
        for peer in peers:
            manifest["agents"].setdefault(slug(peer), {
                "role": "unknown", "repo": "", "last_seen_at": "",
            })
        write_json(path, manifest)
    write_json(base / "agents" / f"{slug(agent)}.json", {
        "agent_id": slug(agent), "role": role, "repo": repo or "",
        "updated_at": iso_now(),
    })
    touch_presence(base, agent, role=role)


def touch_presence(base: Path, agent: str, role: str | None = None,
                   state: str | None = None, note: str | None = None) -> dict[str, Any]:
    with mailbox_lock(base):
        st = safe_load(status_path(base, agent), {})
        st["agent_id"] = slug(agent)
        if role:
            st["role"] = role
        if state:
            st["state"] = state
        if note is not None:
            st["note"] = note
        st.setdefault("state", "idle")
        st.setdefault("last_read_stamp", "")
        st["last_seen_at"] = iso_now()
        st["updated_at"] = iso_now()
        write_json(status_path(base, agent), st)
        manifest_file = base / "manifest.json"
        manifest = safe_load(manifest_file, {})
        if manifest:
            manifest.setdefault("agents", {})
            entry = manifest["agents"].setdefault(slug(agent), {})
            entry["last_seen_at"] = iso_now()
            if role:
                entry["role"] = role
            write_json(manifest_file, manifest)
        return st


def get_cursor(base: Path, agent: str) -> str:
    return safe_load(status_path(base, agent), {}).get("last_read_stamp", "")


def set_cursor(base: Path, agent: str, value: str) -> None:
    with mailbox_lock(base):
        st = safe_load(status_path(base, agent), {})
        st["agent_id"] = slug(agent)
        st.setdefault("state", "idle")
        st["last_read_stamp"] = value
        st["updated_at"] = iso_now()
        write_json(status_path(base, agent), st)


# --- identities -------------------------------------------------------------

def repo_key(repo: str | None) -> str:
    base = os.path.realpath(os.path.expanduser(repo or os.getcwd()))
    try:
        out = subprocess.run(
            ["git", "-C", base, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        top = out.stdout.strip()
        if top:
            return os.path.realpath(top)
    except Exception:
        pass
    return base


def load_identities(root: Any) -> dict[str, Any]:
    return safe_load(identities_path(root), {})


def save_identity(root: Any, repo: str | None, task: str, agent: str, role: str) -> None:
    with identities_lock(root):
        data = safe_load(identities_path(root), {})
        data[repo_key(repo)] = {
            "task": slug(task), "agent": slug(agent), "role": role,
            "updated_at": iso_now(),
        }
        write_json(identities_path(root), data)


def lookup_identity(root: Any, repo: str | None) -> dict[str, Any]:
    return safe_load(identities_path(root), {}).get(repo_key(repo), {})


def resolve_identity(args, need_agent: bool = True) -> None:
    cache: dict[str, Any] = {}

    def fetched() -> dict[str, Any]:
        if "v" not in cache:
            cache["v"] = lookup_identity(args.root, getattr(args, "repo", None))
        return cache["v"]

    if not getattr(args, "task", None):
        args.task = DEFAULT_TASK or fetched().get("task")
    if need_agent and not getattr(args, "agent", None):
        args.agent = DEFAULT_AGENT or fetched().get("agent")

    if not getattr(args, "task", None):
        raise SystemExit(
            "no task: pass --task, set AGENT_MAILBOX_TASK, or run init/join from this repo first")
    if need_agent and not getattr(args, "agent", None):
        raise SystemExit(
            "no agent id: pass --agent, set AGENT_MAILBOX_AGENT, or run init/join from this repo first")


# --- repair -----------------------------------------------------------------

def _scan_agent_ids(base: Path) -> set[str]:
    ids: set[str] = set()
    for box in ("inbox", "outbox", "archive"):
        d = base / box
        if not d.exists():
            continue
        for f in d.rglob("*.md"):
            fm = parse_frontmatter(f)
            if fm.get("from"):
                ids.add(fm["from"])
            if fm.get("to"):
                ids.add(fm["to"])
    return ids


def _repair_outbox(base: Path) -> int:
    restored = 0
    inbox_dir = base / "inbox"
    if not inbox_dir.exists():
        return 0
    for f in inbox_dir.rglob("*.md"):
        sender = parse_frontmatter(f).get("from")
        if not sender:
            continue
        mirror = base / "outbox" / sender / f.name
        if not mirror.exists():
            atomic_write_text(mirror, f.read_text(encoding="utf-8"))
            restored += 1
    return restored


def repair(root: Any, task: str | None, identities: bool) -> list[str]:
    actions: list[str] = []
    if identities:
        with identities_lock(root):
            data = safe_load(identities_path(root), None)
            if not isinstance(data, dict):
                write_json(identities_path(root), {})
                actions.append("reset identities.json")
            else:
                actions.append("identities.json OK")
        return actions

    if not task:
        raise SystemExit("repair: pass --task <task> or --identities")
    base = mailbox_path(root, task)
    if not base.exists():
        raise SystemExit(f"mailbox not found: {base}")

    with mailbox_lock(base):
        agents: dict[str, Any] = {}
        agents_dir = base / "agents"
        if agents_dir.exists():
            for f in sorted(agents_dir.glob("*.json")):
                rec = safe_load(f, None)
                if isinstance(rec, dict) and rec.get("agent_id"):
                    agents[rec["agent_id"]] = {
                        "role": rec.get("role", "unknown"),
                        "repo": rec.get("repo", ""),
                        "last_seen_at": rec.get("updated_at", ""),
                    }
                else:
                    actions.append(f"dropped corrupt agents/{f.name}")
        # Union in ids known only from message frontmatter (e.g. declared peers
        # that never wrote an agents/*.json record of their own).
        added = [aid for aid in _scan_agent_ids(base) if aid not in agents]
        for aid in added:
            agents[aid] = {"role": "unknown", "repo": "", "last_seen_at": ""}
        if added:
            actions.append(f"recovered {len(added)} agent(s) from message frontmatter")
        existing = safe_load(base / "manifest.json", {})
        write_json(base / "manifest.json", {
            "task": existing.get("task", slug(task)),
            "created_at": existing.get("created_at", iso_now()),
            "updated_at": iso_now(),
            "mailbox_version": MAILBOX_VERSION,
            "agents": agents,
        })
        actions.append(f"rebuilt manifest ({len(agents)} agents)")
        status_dir = base / "status"
        if status_dir.exists():
            for f in sorted(status_dir.glob("*.json")):
                if safe_load(f, None) is None:
                    write_json(f, {
                        "agent_id": f.stem, "state": "idle",
                        "last_read_stamp": "", "updated_at": iso_now(),
                    })
                    actions.append(f"reset corrupt status/{f.name}")

    restored = _repair_outbox(base)
    if restored:
        actions.append(f"restored {restored} missing outbox mirror(s)")
    return actions
