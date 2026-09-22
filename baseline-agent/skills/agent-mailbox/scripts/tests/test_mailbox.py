"""Unit + end-to-end tests for agent-mailbox. Run: python3 -m unittest -v"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
ENTRY = SCRIPTS / "agent_mailbox.py"
sys.path.insert(0, str(SCRIPTS))

from ambx import cli, guards, messages, store  # noqa: E402


def run(root, *args, check=True):
    """Invoke the CLI entry as a subprocess (end-to-end)."""
    proc = subprocess.run(
        [sys.executable, str(ENTRY), *args, "--root", str(root)],
        capture_output=True, text=True,
    )
    if check and proc.returncode != 0:
        raise AssertionError(f"command failed ({proc.returncode}): {args}\n{proc.stderr}")
    return proc


class GuardTests(unittest.TestCase):
    def test_subject_slug_capped(self):
        long = "x" * 200
        self.assertLessEqual(len(guards.subject_slug(long)), guards.SUBJECT_SLUG_MAX)

    def test_secret_detected(self):
        self.assertTrue(guards.scan_secrets("-----BEGIN RSA PRIVATE KEY-----"))
        self.assertTrue(guards.scan_secrets("token AKIAIOSFODNN7EXAMPLE here"))
        with self.assertRaises(SystemExit):
            guards.check_body("password = hunter2", allow_unsafe=False)
        guards.check_body("password = hunter2", allow_unsafe=True)  # override ok

    def test_oversize_body(self):
        with self.assertRaises(SystemExit):
            guards.check_body("a" * (guards.BODY_MAX_BYTES + 1), allow_unsafe=False)


class FilenameTests(unittest.TestCase):
    def test_filename_within_limit(self):
        name = messages.build_filename(
            store.stamp(), messages.new_id(), "sender", "recipient", "status", "S" * 500)
        self.assertLessEqual(len(name.encode("utf-8")), messages.MAX_FILENAME_BYTES)
        self.assertTrue(name.endswith(".md"))


class KickoffTests(unittest.TestCase):
    def test_kickoff_lines_cli_filter(self):
        both = cli.kickoff_lines("t", "dep", "main", cli="both")
        self.assertEqual(both, [
            "/agent-mailbox join task t as dep peer main",
            "$agent-mailbox join task t as dep peer main",
        ])
        self.assertEqual(cli.kickoff_lines("t", "dep", "main", cli="claude"),
                         ["/agent-mailbox join task t as dep peer main"])
        self.assertEqual(cli.kickoff_lines("t", "dep", "main", cli="codex"),
                         ["$agent-mailbox join task t as dep peer main"])

    def test_shell_block_omits_default_root_export(self):
        block = cli.bootstrap_block(str(store.DEFAULT_ROOT), "t", "main", "dep")
        self.assertNotIn("AGENT_MAILBOX_ROOT", block)
        self.assertIn("join --task t --agent dep --peer main --read --ack", block)

    def test_shell_block_includes_custom_root_export(self):
        block = cli.bootstrap_block("/tmp/custom-coord", "t", "main", "dep")
        self.assertIn("export AGENT_MAILBOX_ROOT=/tmp/custom-coord", block)


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = Path(self.tmp) / "coord"

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_init_unread_cursor_advances(self):
        run(self.root, "init", "--task", "t", "--agent", "main",
            "--peer", "dep", "--body", "do the thing")
        # first unread read sees the initial instruction
        out = run(self.root, "inbox", "--task", "t", "--agent", "dep", "--unread", "--list-only")
        self.assertIn("unread=1", out.stdout)
        # cursor advanced -> second read sees nothing
        out = run(self.root, "inbox", "--task", "t", "--agent", "dep", "--unread", "--list-only")
        self.assertIn("unread=0", out.stdout)

    def test_join_read_drains_inbox(self):
        run(self.root, "init", "--task", "t", "--agent", "main",
            "--peer", "dep", "--body", "do the thing")
        out = run(self.root, "join", "--task", "t", "--agent", "dep",
                  "--peer", "main", "--read")
        self.assertIn("unread=1", out.stdout)
        self.assertIn("do the thing", out.stdout)
        # the read advanced the cursor -> nothing unread next time
        out = run(self.root, "inbox", "--task", "t", "--agent", "dep",
                  "--unread", "--list-only")
        self.assertIn("unread=0", out.stdout)

    def test_join_ack_notifies_peer(self):
        run(self.root, "init", "--task", "t", "--agent", "main",
            "--peer", "dep", "--body", "x")
        run(self.root, "join", "--task", "t", "--agent", "dep",
            "--peer", "main", "--ack")
        out = run(self.root, "inbox", "--task", "t", "--agent", "main", "--all")
        self.assertIn("kind: ack", out.stdout)
        self.assertIn("from: dep", out.stdout)

    def test_join_ack_custom_message(self):
        run(self.root, "init", "--task", "t", "--agent", "main",
            "--peer", "dep", "--body", "x")
        run(self.root, "join", "--task", "t", "--agent", "dep",
            "--peer", "main", "--ack", "reading the brief now")
        out = run(self.root, "inbox", "--task", "t", "--agent", "main", "--all")
        self.assertIn("reading the brief now", out.stdout)

    def test_init_prints_kickoff_for_peers(self):
        out = run(self.root, "init", "--task", "t", "--agent", "main",
                  "--peer", "dep", "--body", "x")
        self.assertIn("/agent-mailbox join task t as dep peer main", out.stdout)
        self.assertIn("$agent-mailbox join task t as dep peer main", out.stdout)
        self.assertIn("first message", out.stdout)

    def test_init_format_shell(self):
        out = run(self.root, "init", "--task", "t", "--agent", "main",
                  "--peer", "dep", "--body", "x", "--format", "shell")
        self.assertIn(
            "agent-mailbox join --task t --agent dep --peer main --read --ack",
            out.stdout)
        self.assertNotIn("/agent-mailbox join task", out.stdout)

    def test_bootstrap_prompt_cli_filter(self):
        run(self.root, "init", "--task", "t", "--agent", "main",
            "--peer", "dep", "--body", "x")
        out = run(self.root, "bootstrap", "--task", "t", "--agent", "dep",
                  "--format", "prompt", "--cli", "claude")
        self.assertIn("/agent-mailbox join task t as dep peer main", out.stdout)
        self.assertNotIn("$agent-mailbox", out.stdout)
        out = run(self.root, "kickoff", "--task", "t", "--agent", "dep",
                  "--cli", "codex")
        self.assertIn("$agent-mailbox join task t as dep peer main", out.stdout)
        self.assertNotIn("/agent-mailbox", out.stdout)

    def test_no_self_deliver(self):
        run(self.root, "init", "--task", "t", "--agent", "main",
            "--peer", "dep", "--body", "x")
        out = run(self.root, "inbox", "--task", "t", "--agent", "main", "--all", "--list-only")
        self.assertIn("no messages", out.stdout)

    def test_thread_filter_does_not_advance_cursor(self):
        run(self.root, "init", "--task", "t", "--agent", "main", "--peer", "dep", "--body", "x")
        # post two more messages
        run(self.root, "post", "--task", "t", "--agent", "main", "--to", "dep",
            "--subject", "one", "--body", "first")
        run(self.root, "post", "--task", "t", "--agent", "main", "--to", "dep",
            "--subject", "two", "--body", "second")
        # find a thread id from dep's inbox
        base = store.mailbox_path(self.root, "t")
        msgs = messages.list_inbox(base, "dep", all_msgs=True)
        thread = store.parse_frontmatter(msgs[0]).get("thread")
        # a threaded read must NOT advance the cursor
        run(self.root, "inbox", "--task", "t", "--agent", "dep",
            "--unread", "--thread", thread, "--list-only")
        out = run(self.root, "inbox", "--task", "t", "--agent", "dep", "--unread", "--list-only")
        self.assertIn("unread=3", out.stdout)  # all three still unread

    def test_typo_guard(self):
        run(self.root, "init", "--task", "t", "--agent", "main", "--peer", "dep", "--body", "x")
        proc = run(self.root, "post", "--task", "t", "--agent", "main", "--to", "dpe",
                   "--subject", "s", "--body", "b", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("unknown recipient", proc.stderr)

    def test_secret_guard_blocks_post(self):
        run(self.root, "init", "--task", "t", "--agent", "main", "--peer", "dep", "--body", "x")
        proc = run(self.root, "post", "--task", "t", "--agent", "main", "--to", "dep",
                   "--subject", "s", "--body", "-----BEGIN PRIVATE KEY-----", check=False)
        self.assertNotEqual(proc.returncode, 0)
        proc = run(self.root, "post", "--task", "t", "--agent", "main", "--to", "dep",
                   "--subject", "s", "--body", "-----BEGIN PRIVATE KEY-----",
                   "--allow-unsafe", check=False)
        self.assertEqual(proc.returncode, 0)

    def test_reply_to_thread_inheritance(self):
        run(self.root, "init", "--task", "t", "--agent", "main", "--peer", "dep", "--body", "x")
        out = run(self.root, "post", "--task", "t", "--agent", "main", "--to", "dep",
                  "--subject", "parent", "--body", "p")
        parent_id = [l for l in out.stdout.splitlines() if l.startswith("message_id=")][0].split("=")[1]
        parent_thread = [l for l in out.stdout.splitlines() if l.startswith("thread=")][0].split("=")[1]
        # reply inherits the parent's thread
        out = run(self.root, "post", "--task", "t", "--agent", "dep", "--to", "main",
                  "--subject", "reply", "--body", "r", "--reply-to", parent_id)
        reply_thread = [l for l in out.stdout.splitlines() if l.startswith("thread=")][0].split("=")[1]
        self.assertEqual(reply_thread, parent_thread)

    def test_reply_to_missing_parent_falls_back(self):
        run(self.root, "init", "--task", "t", "--agent", "main", "--peer", "dep", "--body", "x")
        out = run(self.root, "post", "--task", "t", "--agent", "main", "--to", "dep",
                  "--subject", "s", "--body", "b", "--reply-to", "deadbeef")
        self.assertIn("thread=deadbeef", out.stdout)
        self.assertIn("not found locally", out.stderr)

    def test_atomic_write_is_complete(self):
        run(self.root, "init", "--task", "t", "--agent", "main", "--peer", "dep", "--body", "hello body")
        base = store.mailbox_path(self.root, "t")
        msg = messages.list_inbox(base, "dep", all_msgs=True)[0]
        text = msg.read_text()
        self.assertTrue(text.startswith("---"))
        self.assertIn("hello body", text)
        self.assertTrue(text.endswith("\n"))

    def test_board_and_status(self):
        run(self.root, "init", "--task", "t", "--agent", "main", "--peer", "dep", "--body", "x")
        run(self.root, "join", "--task", "t", "--agent", "dep", "--peer", "main")
        run(self.root, "status", "--task", "t", "--agent", "dep", "--state", "working",
            "--note", "on it")
        out = run(self.root, "board", "--task", "t")
        self.assertIn("dep", out.stdout)
        self.assertIn("state=working", out.stdout)
        self.assertIn("note=on it", out.stdout)

    def test_wait_times_out_nonzero(self):
        run(self.root, "init", "--task", "t", "--agent", "main", "--peer", "dep", "--body", "x")
        run(self.root, "join", "--task", "t", "--agent", "dep", "--peer", "main")
        run(self.root, "inbox", "--task", "t", "--agent", "dep", "--unread", "--list-only")  # drain
        proc = run(self.root, "inbox", "--task", "t", "--agent", "dep", "--wait", "1",
                   "--list-only", check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("timed out", proc.stdout)

    def test_repair_rebuilds_corrupt_manifest(self):
        run(self.root, "init", "--task", "t", "--agent", "main", "--peer", "dep", "--body", "x")
        base = store.mailbox_path(self.root, "t")
        (base / "manifest.json").write_text("{ this is not json")
        # a normal command now fails with a recovery pointer
        proc = run(self.root, "agents", "--task", "t", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("repair", proc.stderr.lower() + proc.stdout.lower())
        # repair rebuilds it
        run(self.root, "repair", "--task", "t")
        out = run(self.root, "agents", "--task", "t")
        self.assertIn("main", out.stdout)
        self.assertIn("dep", out.stdout)


if __name__ == "__main__":
    unittest.main()
