"""Command-line interface for agent-mailbox."""

from __future__ import annotations

import argparse
import os
import sys
import time
from datetime import datetime, timezone

from . import messages, store
from .guards import check_body, slug

RECOMMENDED_KINDS = ["initial-instruction", "instruction", "ack", "status",
                     "handoff", "blocked", "done", "verify"]
STATES = ["idle", "working", "blocked", "done"]
DEFAULT_WAIT_SECS = 300
WAIT_POLL_SECS = 2.0
DEFAULT_STALE_SECS = int(os.environ.get("AGENT_MAILBOX_STALE_SECS", "600"))


# --- helpers ----------------------------------------------------------------

def expand_ids(values) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for value in values or []:
        for part in str(value).split(","):
            part = part.strip()
            if not part:
                continue
            tag = slug(part)
            if tag not in seen:
                seen.add(tag)
                out.append(tag)
    return out


def read_body(args, required: bool) -> str:
    if getattr(args, "body_file", None):
        return open(args.body_file, encoding="utf-8").read()
    if getattr(args, "instruction_file", None):
        return open(args.instruction_file, encoding="utf-8").read()
    body = getattr(args, "body", None) or getattr(args, "instruction", None)
    if body:
        return body
    if required:
        raise SystemExit("message body required; pass --body/--body-file")
    return ""


def _detect_cli() -> str:
    """Best-effort guess of the host CLI; falls back to 'both'."""
    if os.environ.get("CLAUDECODE"):
        return "claude"
    if any(k.startswith("CODEX") for k in os.environ):
        return "codex"
    return "both"


def kickoff_lines(task: str, peer: str, main: str, cli: str = "both") -> list[str]:
    """The paste-as-first-message kickoff one-liner(s) for a peer session.

    Carries only ids -- the brief lives in the mailbox. The peer agent maps this
    to `join --task <task> --agent <peer> --peer <main> --read --ack`.
    """
    body = f"agent-mailbox join task {slug(task)} as {slug(peer)} peer {slug(main)}"
    variants = {"claude": f"/{body}", "codex": f"${body}"}
    if cli == "auto":
        cli = _detect_cli()
    if cli in variants:
        return [variants[cli]]
    return [variants["claude"], variants["codex"]]


def kickoff_block(task: str, peer: str, main: str) -> str:
    """Labelled both-CLI kickoff block for `init` output."""
    claude, codex = kickoff_lines(task, peer, main, cli="both")
    return "\n".join([
        f"# Kickoff for {slug(peer)} -- send ONE line as the peer session's first message:",
        "#   Claude Code:",
        claude,
        "#   Codex:",
        codex,
    ])


def bootstrap_block(root, task: str, main_agent: str, peer: str) -> str:
    """Raw-shell dispatch block (the `--format shell` form)."""
    root_disp = root or str(store.DEFAULT_ROOT)
    lines = [f"# Dispatch to {slug(peer)} (run in its repo):"]
    if root_disp != str(store.DEFAULT_ROOT):
        lines.append(f"export AGENT_MAILBOX_ROOT={root_disp}")
    lines.append(
        f"agent-mailbox join --task {slug(task)} --agent {slug(peer)} "
        f"--peer {slug(main_agent)} --read --ack")
    return "\n".join(lines)


def _parse_iso(value: str):
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _age(now, value: str) -> str:
    dt = _parse_iso(value)
    if not dt:
        return "never"
    secs = int((now - dt).total_seconds())
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def _is_stale(now, value: str, threshold: int) -> bool:
    dt = _parse_iso(value)
    if not dt:
        return True
    return (now - dt).total_seconds() > threshold


def _unread_count(base, agent: str, cursor: str) -> int:
    inbox = base / "inbox" / slug(agent)
    if not inbox.exists():
        return 0
    return sum(1 for m in inbox.glob("*.md") if m.name.split("-", 1)[0] > cursor)


# --- commands ---------------------------------------------------------------

def cmd_init(args) -> None:
    args.agent = args.agent or store.DEFAULT_AGENT or "main-agent"
    store.resolve_identity(args)
    base = store.mailbox_path(args.root, args.task)
    peers = expand_ids(args.peer)
    store.ensure_layout(base, [slug(args.agent), *peers])
    store.write_readme(base, args.task)
    store.save_identity(args.root, args.repo, args.task, args.agent, args.role)
    store.update_manifest(base, args.task, args.agent, args.role, args.repo, peers)

    body = read_body(args, required=False)
    delivered = None
    if body:
        check_body(body, args.allow_unsafe)
        recipients = expand_ids(args.to) if args.to else peers
        if not recipients:
            print("warning: no peers/recipients; initial instruction not delivered",
                  file=sys.stderr)
        else:
            delivered = messages.post_message(
                base, args.task, args.agent, recipients,
                "initial-instruction", args.subject, body)

    print(f"mailbox={base}")
    print(f"agent={slug(args.agent)}")
    if delivered:
        print(f"message_id={delivered['id']}")
        for path in delivered["delivered"]:
            print(f"delivered: {path}")
    if peers:
        fmt = getattr(args, "format", "prompt")
        for peer in peers:
            print()
            if fmt in ("prompt", "both"):
                print(kickoff_block(slug(args.task), peer, slug(args.agent)))
            if fmt in ("shell", "both"):
                if fmt == "both":
                    print()
                print(bootstrap_block(args.root, slug(args.task), slug(args.agent), peer))


def cmd_join(args) -> None:
    args.agent = args.agent or store.DEFAULT_AGENT or "dependent-agent"
    store.resolve_identity(args)
    base = store.mailbox_path(args.root, args.task)
    peers = expand_ids(args.peer)
    store.ensure_layout(base, [slug(args.agent), *peers])
    store.write_readme(base, args.task)
    store.save_identity(args.root, args.repo, args.task, args.agent, args.role)
    store.update_manifest(base, args.task, args.agent, args.role, args.repo, peers)

    # Optional ack to peers. Triggered by --ack (flag or message) or a --body.
    body = read_body(args, required=False)
    if args.ack is not None or body:
        if not peers:
            print("warning: --ack given but no --peer to notify", file=sys.stderr)
        else:
            ack_body = (args.ack or None) or body or "joined; reading the brief now"
            check_body(ack_body, args.allow_unsafe)
            subject = args.subject or "ack -- joined"
            res = messages.post_message(base, args.task, args.agent, peers,
                                        "ack", subject, ack_body)
            for path in res["delivered"]:
                print(f"delivered: {path}")
    print(f"mailbox={base}")
    if args.read:
        _print_unread(base, slug(args.agent), args.limit)
    else:
        print(f"inbox={base / 'inbox' / slug(args.agent)}")


def cmd_post(args) -> None:
    store.resolve_identity(args)
    base = store.mailbox_path(args.root, args.task)
    manifest = store.load_manifest(base)
    if not manifest:
        raise SystemExit(f"mailbox not found: {base} (run init/join first)")
    known = set(manifest.get("agents", {}))
    recipients = expand_ids(args.to)
    if not recipients:
        raise SystemExit("no recipients: pass --to (comma-separated or repeated)")
    unknown = [r for r in recipients if r not in known]
    if unknown and not args.force:
        raise SystemExit(
            f"unknown recipient(s): {', '.join(unknown)}; known agents: "
            f"{', '.join(sorted(known)) or '(none)'}; use --force to send anyway")
    if slug(args.agent) not in known:
        print(f"warning: sender '{slug(args.agent)}' is not registered", file=sys.stderr)

    body = read_body(args, required=True)
    check_body(body, args.allow_unsafe)
    res = messages.post_message(base, args.task, args.agent, recipients, args.kind,
                                args.subject, body, reply_to=args.reply_to)
    store.touch_presence(base, args.agent)
    if res["warn"] == "missing":
        print(f"note: reply-to parent {args.reply_to} not found locally; "
              f"thread set to {res['thread']}", file=sys.stderr)
    elif res["warn"] == "ambiguous":
        print(f"warning: reply-to id {args.reply_to} matched multiple messages; "
              "used earliest", file=sys.stderr)
    print(f"message_id={res['id']}")
    print(f"thread={res['thread']}")
    for path in res["delivered"]:
        print(f"delivered: {path}")


def _show_messages(msgs, show: bool) -> None:
    for path in msgs:
        print(path)
        if show:
            print(path.read_text(encoding="utf-8"))


def _print_unread(base, agent: str, limit: int = 20, show: bool = True) -> list:
    """Print unread inbox for `agent` and advance the read cursor."""
    agent = slug(agent)
    cursor = store.get_cursor(base, agent)
    msgs = messages.list_inbox(base, agent, unread=True, limit=limit, cursor=cursor)
    print(f"inbox={base / 'inbox' / agent}")
    print(f"unread={len(msgs)}")
    if not msgs:
        print("no new messages")
    else:
        _show_messages(msgs, show)
        store.set_cursor(base, agent, messages.newest_stamp(msgs))
    return msgs


def cmd_inbox(args) -> None:
    store.resolve_identity(args)
    base = store.mailbox_path(args.root, args.task)
    agent = slug(args.agent)
    store.touch_presence(base, agent)
    filtered = args.thread is not None
    show = not args.list_only

    if args.wait is not None:
        deadline = time.monotonic() + (args.wait or DEFAULT_WAIT_SECS)
        print(f"inbox={base / 'inbox' / agent}")
        while True:
            cursor = store.get_cursor(base, agent)
            msgs = messages.list_inbox(base, agent, unread=True, thread=args.thread,
                                       limit=args.limit, cursor=cursor)
            if msgs:
                print(f"unread={len(msgs)}")
                _show_messages(msgs, show)
                if not args.peek and not filtered:
                    store.set_cursor(base, agent, messages.newest_stamp(msgs))
                return
            if time.monotonic() >= deadline:
                print("no new messages (timed out)")
                sys.exit(1)
            time.sleep(WAIT_POLL_SECS)

    if not (base / "inbox" / agent).exists():
        raise SystemExit(f"inbox does not exist: {base / 'inbox' / agent}")
    cursor = store.get_cursor(base, agent)
    msgs = messages.list_inbox(base, agent, unread=args.unread, thread=args.thread,
                               all_msgs=args.all, limit=args.limit, cursor=cursor)
    print(f"inbox={base / 'inbox' / agent}")
    if args.unread:
        print(f"unread={len(msgs)}")
    if not msgs:
        print("no new messages" if args.unread else "no messages")
    else:
        _show_messages(msgs, show)
    # cursor advances only on an unfiltered unread read
    if args.unread and not args.peek and not filtered and msgs:
        store.set_cursor(base, agent, messages.newest_stamp(msgs))


def cmd_board(args) -> None:
    store.resolve_identity(args, need_agent=False)
    base = store.mailbox_path(args.root, args.task)
    manifest = store.load_manifest(base)
    if not manifest:
        raise SystemExit(f"mailbox not found: {base}")
    print(f"task={manifest.get('task', '')}  mailbox={base}")
    agents = manifest.get("agents", {})
    if not agents:
        print("no agents registered")
        return
    now = store.utc_now()
    for aid in sorted(agents):
        st = store.safe_load(store.status_path(base, aid), {})
        last_seen = st.get("last_seen_at") or agents[aid].get("last_seen_at", "")
        stale = " STALE" if _is_stale(now, last_seen, args.stale_after) else ""
        unread = _unread_count(base, aid, st.get("last_read_stamp", ""))
        note = st.get("note", "")
        print(f"- {aid}\trole={agents[aid].get('role', '')}"
              f"\tstate={st.get('state', '?')}{stale}"
              f"\tseen={_age(now, last_seen)}\tunread={unread}"
              + (f"\tnote={note}" if note else ""))


def cmd_status(args) -> None:
    store.resolve_identity(args)
    base = store.mailbox_path(args.root, args.task)
    if not store.load_manifest(base):
        raise SystemExit(f"mailbox not found: {base}")
    st = store.touch_presence(base, args.agent, state=args.state, note=args.note)
    print(f"agent={slug(args.agent)}  state={st.get('state')}  note={st.get('note', '')}")


def cmd_agents(args) -> None:
    store.resolve_identity(args, need_agent=False)
    base = store.mailbox_path(args.root, args.task)
    manifest = store.load_manifest(base)
    if not manifest:
        raise SystemExit(f"mailbox not found: {base}")
    print(f"task={manifest.get('task', '')}  mailbox={base}")
    agents = manifest.get("agents", {})
    if not agents:
        print("no agents registered")
        return
    for aid in sorted(agents):
        info = agents[aid]
        print(f"- {aid}\trole={info.get('role', '')}"
              f"\trepo={info.get('repo', '')}\tlast_seen={info.get('last_seen_at', '')}")


def cmd_list(args) -> None:
    root = store.root_path(args.root)
    print(f"root={root}")
    if not root.exists():
        print("(no mailboxes)")
        return
    found = False
    for d in sorted(root.iterdir()):
        if not d.is_dir() or not (d / "manifest.json").exists():
            continue
        found = True
        manifest = store.safe_load(d / "manifest.json", {})
        agents = manifest.get("agents", {})
        print(f"- {d.name}\tagents={len(agents)}\tupdated={manifest.get('updated_at', '')}")
    if not found:
        print("(no mailboxes)")


def cmd_whoami(args) -> None:
    ident = store.lookup_identity(args.root, getattr(args, "repo", None))
    task = args.task or store.DEFAULT_TASK or ident.get("task")
    agent = args.agent or store.DEFAULT_AGENT or ident.get("agent")
    print(f"repo={store.repo_key(getattr(args, 'repo', None))}")
    print(f"task={task or '(unset)'}")
    print(f"agent={agent or '(unset)'}")
    print(f"role={ident.get('role', '(unknown)')}")


def cmd_bootstrap(args) -> None:
    ident = store.lookup_identity(args.root, getattr(args, "repo", None))
    task = args.task or store.DEFAULT_TASK or ident.get("task")
    main = store.DEFAULT_AGENT or ident.get("agent") or "main-agent"
    if not task:
        raise SystemExit("no task: pass --task or run init/join from this repo first")
    if not args.agent:
        raise SystemExit("pass --agent <peer> to print its kickoff")
    fmt = getattr(args, "format", "both")
    cli = getattr(args, "cli", "auto")
    if fmt in ("prompt", "both"):
        for line in kickoff_lines(slug(task), slug(args.agent), slug(main), cli):
            print(line)
    if fmt in ("shell", "both"):
        if fmt == "both":
            print()
        print(bootstrap_block(args.root, slug(task), slug(main), slug(args.agent)))


def cmd_archive(args) -> None:
    store.resolve_identity(args)
    base = store.mailbox_path(args.root, args.task)
    moved = messages.archive_read(base, args.agent, store.get_cursor(base, args.agent))
    print(f"archived {moved} read message(s) for {slug(args.agent)}")


def cmd_repair(args) -> None:
    for action in store.repair(args.root, args.task, args.identities):
        print(action)


def cmd_form(args) -> None:
    root = str(store.DEFAULT_ROOT)
    repo = os.getcwd()
    forms = {
        "init": f"""operation: init
task slug:
main agent id: main-agent
main repo path: {repo}
dependent agent ids: platform-dependent
mailbox root: {root}
initial instruction:
  <paste the full instruction for the dependent agent here>""",
        "join": f"""operation: join
task slug:
dependent agent id: dependent-agent
dependent repo path: {repo}
peer agent ids to acknowledge: main-agent
mailbox root: {root}""",
        "post": """operation: post
task slug:
sender agent id:
recipient agent ids:
message kind: status
subject:
message body:
  <message body>""",
        "inbox": """operation: inbox
task slug:
agent id:
unread only: yes""",
    }
    print(forms[args.mode])


# --- argument parsing -------------------------------------------------------

def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", default=str(store.DEFAULT_ROOT), help="Mailbox root directory")
    parser.add_argument("--task", default=None,
                        help="Task slug (else AGENT_MAILBOX_TASK or saved per-repo identity)")
    parser.add_argument("--repo", default="", help="Repository path (for identity lookup)")


def add_peer(parser: argparse.ArgumentParser, help_text: str) -> None:
    parser.add_argument("--peer", "--peers", dest="peer", action="append", default=[],
                        help=f"{help_text} (comma-separated or repeated)")


def add_body(parser: argparse.ArgumentParser, label: str) -> None:
    parser.add_argument("--body", "--instruction", dest="body", help=f"{label} body")
    parser.add_argument("--body-file", "--instruction-file", dest="body_file",
                        help=f"File with the {label.lower()} body")
    parser.add_argument("--allow-unsafe", dest="allow_unsafe", action="store_true",
                        help="Bypass the secret/size body guards")


def add_kickoff_opts(parser: argparse.ArgumentParser, default_format: str) -> None:
    parser.add_argument("--format", choices=["prompt", "shell", "both"],
                        default=default_format,
                        help="Output form: prompt kickoff, raw shell, or both")
    parser.add_argument("--cli", choices=["claude", "codex", "auto"], default="auto",
                        help="Which CLI's kickoff to emit (auto-detects; else both)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="agent-mailbox: multi-agent coordination")
    sub = parser.add_subparsers(dest="cmd", required=True)

    init = sub.add_parser("init", help="Create a mailbox and deliver initial instructions")
    add_common(init)
    init.add_argument("--agent", default=None, help="Current agent id (default main-agent)")
    init.add_argument("--role", default="main", help="Current agent role")
    add_peer(init, "Peer agent id")
    init.add_argument("--to", "--recipients", dest="to", action="append", default=[],
                      help="Initial-instruction recipient; defaults to peers")
    init.add_argument("--subject", default="Initial instruction")
    add_body(init, "Initial instruction")
    init.add_argument("--format", choices=["prompt", "shell", "both"], default="prompt",
                      help="Peer dispatch form: prompt kickoff (default), raw shell, or both")
    init.set_defaults(func=cmd_init)

    join = sub.add_parser("join", help="Register an agent with an existing mailbox")
    add_common(join)
    join.add_argument("--agent", default=None, help="Current agent id (default dependent-agent)")
    join.add_argument("--role", default="dependent", help="Current agent role")
    add_peer(join, "Peer to notify with an optional ack")
    join.add_argument("--subject", default=None,
                      help="Ack subject (default 'ack -- joined')")
    add_body(join, "Acknowledgement")
    join.add_argument("--ack", nargs="?", const="", default=None, metavar="MESSAGE",
                      help="Post an ack to --peer on join (optional message body)")
    join.add_argument("--read", "--then-read", dest="read", action="store_true",
                      help="After joining, print unread inbox and advance the cursor")
    join.add_argument("--limit", type=int, default=20,
                      help="Newest unread messages to show with --read")
    join.set_defaults(func=cmd_join)

    post = sub.add_parser("post", help="Post a message to one or more recipients")
    add_common(post)
    post.add_argument("--agent", default=None, help="Sender agent id")
    post.add_argument("--to", "--recipients", dest="to", action="append", default=[],
                      help="Recipient agent id (comma-separated or repeated)")
    post.add_argument("--kind", default="status",
                      help="Message kind; recommended: " + ", ".join(RECOMMENDED_KINDS))
    post.add_argument("--subject", required=True, help="Message subject")
    post.add_argument("--reply-to", dest="reply_to", default=None,
                      help="Message id this replies to (sets the thread)")
    post.add_argument("--force", action="store_true",
                      help="Send even if a recipient is not registered")
    add_body(post, "Message")
    post.set_defaults(func=cmd_post)

    inbox = sub.add_parser("inbox", help="Read an agent inbox")
    add_common(inbox)
    inbox.add_argument("--agent", default=None, help="Agent id")
    inbox.add_argument("--limit", type=int, default=20, help="Newest messages in the default view")
    inbox.add_argument("--unread", action="store_true",
                       help="Only messages past the read cursor, then advance it")
    inbox.add_argument("--thread", default=None, help="Filter to one thread id (implies peek)")
    inbox.add_argument("--peek", action="store_true", help="Do not advance the read cursor")
    inbox.add_argument("--all", action="store_true", help="List every message")
    inbox.add_argument("--wait", nargs="?", type=int, const=DEFAULT_WAIT_SECS, default=None,
                       metavar="SECS", help="Block until new unread arrives or SECS elapses")
    inbox.add_argument("--list-only", dest="list_only", action="store_true",
                       help="List filenames without contents")
    inbox.set_defaults(func=cmd_inbox)

    board = sub.add_parser("board", help="Supervision dashboard for all agents")
    add_common(board)
    board.add_argument("--stale-after", dest="stale_after", type=int, default=DEFAULT_STALE_SECS,
                       help="Seconds before an agent is flagged STALE")
    board.set_defaults(func=cmd_board)

    for name in ("status", "heartbeat"):
        status = sub.add_parser(name, help="Set your own state/note (presence heartbeat)")
        add_common(status)
        status.add_argument("--agent", default=None, help="Current agent id")
        status.add_argument("--state", choices=STATES, default=None, help="New state")
        status.add_argument("--note", default=None, help="Short status note")
        status.set_defaults(func=cmd_status)

    agents = sub.add_parser("agents", help="List registered agents")
    add_common(agents)
    agents.set_defaults(func=cmd_agents)

    listp = sub.add_parser("list", help="List mailboxes under the root")
    listp.add_argument("--root", default=str(store.DEFAULT_ROOT), help="Mailbox root directory")
    listp.set_defaults(func=cmd_list)

    whoami = sub.add_parser("whoami", help="Show resolved identity for this repo")
    add_common(whoami)
    whoami.add_argument("--agent", default=None, help="Override agent id")
    whoami.set_defaults(func=cmd_whoami)

    boot = sub.add_parser("bootstrap", help="Print a peer's kickoff (prompt) and/or shell block")
    add_common(boot)
    boot.add_argument("--agent", default=None, help="Peer agent id to bootstrap")
    add_kickoff_opts(boot, "both")
    boot.set_defaults(func=cmd_bootstrap)

    kick = sub.add_parser("kickoff", help="Print a peer's prompt-form kickoff one-liner")
    add_common(kick)
    kick.add_argument("--agent", default=None, help="Peer agent id to kick off")
    add_kickoff_opts(kick, "prompt")
    kick.set_defaults(func=cmd_bootstrap)

    archive = sub.add_parser("archive", help="Move read messages to archive/")
    add_common(archive)
    archive.add_argument("--agent", default=None, help="Agent id")
    archive.set_defaults(func=cmd_archive)

    repair = sub.add_parser("repair", help="Recover corrupt state (per file)")
    repair.add_argument("--root", default=str(store.DEFAULT_ROOT), help="Mailbox root directory")
    repair.add_argument("--task", default=None, help="Task to repair (manifest/agents/status)")
    repair.add_argument("--repo", default="", help=argparse.SUPPRESS)
    repair.add_argument("--identities", action="store_true", help="Reset the root identities cache")
    repair.set_defaults(func=cmd_repair)

    form = sub.add_parser("form", help="Print a one-shot intake form")
    form.add_argument("--mode", choices=["init", "join", "post", "inbox"], default="init")
    form.set_defaults(func=cmd_form)

    return parser


def main(argv=None) -> None:
    args = build_parser().parse_args(argv)
    args.func(args)
