import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[2] / 'baseline-agent/helpers/review_scope.py'
spec = importlib.util.spec_from_file_location('review_scope', HELPER)
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class GitFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / 'repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.write('task', 'base\n')
        self.write('other', 'base\n')
        self.git('add', 'task', 'other')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD').strip()
        self.note = {'base': self.base, 'paths': ['task'], 'owned_commits': [],
                     'initial_state': {'staged': [], 'unstaged': [], 'untracked': []}}

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.PIPE, text=True)

    def write(self, name, value):
        (self.repo / name).write_text(value)

    def change(self, path, value, message='change'):
        self.write(path, value)
        self.git('add', '--', path)
        self.git('commit', '-qm', message)
        return self.git('rev-parse', 'HEAD').strip()

    def snapshot(self):
        return (self.git('rev-parse', 'HEAD'), self.git('ls-files', '--stage'),
                self.git('diff', '--binary'), self.git('diff', '--cached', '--binary'),
                {str(p.relative_to(self.repo)): p.read_bytes() for p in self.repo.rglob('*')
                 if p.is_file() and '.git' not in p.relative_to(self.repo).parts})

    def inspect(self):
        before = self.snapshot()
        result = scope.enumerate_scope(self.repo, self.note)
        self.assertEqual(before, self.snapshot())
        return result

    def test_two_commits_on_main_include_canceled_change(self):
        self.note['owned_commits'] = [self.change('task', 'one\n'), self.change('task', 'base\n')]
        result = self.inspect()
        self.assertEqual(2, len(result['committed']))
        self.assertEqual(['task'], result['candidate_paths'])
        self.assertFalse(result['ownership_proven'])

    def test_unrecorded_task_and_misleading_trailer_remain_unattributed(self):
        omitted = self.change('task', 'omitted task work\n')
        false = self.change('other', 'peer\n', 'peer\n\nTask-Id: same-task')
        self.note['owned_commits'] = [self.change('task', 'recorded\n')]
        result = self.inspect()
        self.assertEqual([omitted, false], result['unattributed_commits'])
        self.assertEqual(['task'], result['unattributed_overlaps'])

    def test_staged_unstaged_and_new_files_with_spaces(self):
        self.note['paths'] += ['new file']
        self.write('task', 'staged\n'); self.git('add', 'task')
        self.write('task', 'unstaged\n'); self.write('new file', 'new\n')
        self.write('unrelated new', 'preserve\n')
        result = self.inspect()
        self.assertEqual(['task'], result['current']['staged'])
        self.assertEqual(['task'], result['current']['unstaged'])
        self.assertEqual(['new file', 'task'], result['candidate_paths'])
        self.assertIn('unrelated new', result['current']['untracked'])

    def test_initial_overlap_and_missing_evidence(self):
        self.note['initial_state']['unstaged'] = ['task']
        self.write('task', 'peer and task\n')
        self.assertEqual(['task'], self.inspect()['initial_overlaps'])
        del self.note['initial_state']
        self.assertTrue(self.inspect()['initial_evidence_missing'])

    def test_recorded_commit_outside_scope_is_reported(self):
        self.note['owned_commits'] = [self.change('other', 'claimed\n')]
        self.assertEqual(['other'], self.inspect()['recorded_outside_scope'])

    def test_rename_retains_both_paths(self):
        self.git('mv', 'task', 'renamed')
        self.git('commit', '-qm', 'rename')
        self.note['owned_commits'] = [self.git('rev-parse', 'HEAD').strip()]
        self.assertEqual(['renamed', 'task'], self.inspect()['candidate_paths'])

    def test_detached_and_worktree_local_notes(self):
        worktree = Path(self.tmp.name) / 'worktree'
        main_note = self.git('rev-parse', '--git-path', 'agent-tasks/test.json').strip()
        self.git('worktree', 'add', '--detach', str(worktree), self.base)
        self.repo = worktree
        local_note = self.git('rev-parse', '--git-path', 'agent-tasks/test.json').strip()
        self.assertNotEqual(main_note, local_note)
        self.assertEqual(self.base, self.inspect()['head'])
        self.note['owned_commits'] = [self.change('task', 'detached\n')]
        self.assertEqual(['task'], self.inspect()['candidate_paths'])

    def test_invalid_ownership_and_paths_fail(self):
        for invalid in ['../sibling', '/absolute', ':(glob)*']:
            self.note['paths'] = [invalid]
            with self.assertRaises(ValueError):
                self.inspect()
        self.note['paths'] = ['task']
        self.note['owned_commits'] = [self.base]
        with self.assertRaises(ValueError):
            self.inspect()

    def test_nonancestor_base_fails(self):
        later = self.change('task', 'later\n')
        self.git('checkout', '--detach', self.base)
        self.note['base'] = later
        with self.assertRaises(ValueError):
            self.inspect()

    def test_cli_note_is_passive_and_reports_missing_initial(self):
        note = Path(self.tmp.name) / 'note.json'
        del self.note['initial_state']
        note.write_text(json.dumps(self.note))
        before = note.read_bytes()
        result = subprocess.check_output(['python3', str(HELPER), '--repo', str(self.repo), '--note', str(note)])
        self.assertTrue(json.loads(result)['initial_evidence_missing'])
        self.assertEqual(before, note.read_bytes())

    def test_detached_publication_preserves_original_concurrent_dirt(self):
        remote = Path(self.tmp.name) / 'remote.git'
        self.git('clone', '--bare', str(self.repo), str(remote))
        self.git('remote', 'add', 'origin', str(remote))
        peer = Path(self.tmp.name) / 'peer'
        self.git('clone', str(remote), str(peer))
        owned = self.change('task', 'owned implementation\n')
        self.write('other', 'peer staged\n'); self.git('add', 'other')
        self.write('other', 'peer unstaged\n'); self.write('new', 'peer new\n')
        before = self.snapshot()
        original = self.repo
        self.repo = peer
        self.git('config', 'user.name', 'Peer'); self.git('config', 'user.email', 'peer@example.invalid')
        peer_sha = self.change('remote-only', 'upstream\n')
        self.git('push', 'origin', 'main')
        self.repo = original
        with self.assertRaises(subprocess.CalledProcessError):
            self.git('pull', '--rebase', 'origin', 'main')
        publisher = Path(self.tmp.name) / 'publisher'
        self.git('worktree', 'add', '--detach', str(publisher), owned)
        self.repo = publisher
        self.git('pull', '--rebase', 'origin', 'main')
        # Verify the actual rebased tree before a normal, explicit target push.
        self.assertEqual('owned implementation\n', self.git('show', 'HEAD:task'))
        self.assertEqual('base\n', self.git('show', 'HEAD:other'))
        self.assertEqual(peer_sha, self.git('merge-base', peer_sha, 'HEAD').strip())
        self.assertFalse((publisher / 'new').exists())
        published = self.git('rev-parse', 'HEAD').strip()
        self.git('push', 'origin', 'HEAD:main')
        self.assertIn(published, self.git('ls-remote', 'origin', 'refs/heads/main'))
        self.repo = original
        self.assertEqual(before, self.snapshot())

    def test_archive_fetch_pin_ahead_behind_local_only_preserves_state(self):
        remote = Path(self.tmp.name) / 'remote.git'
        self.git('clone', '--bare', str(self.repo), str(remote))
        self.git('remote', 'add', 'origin', str(remote))
        self.change('task', 'local-only implementation\n')
        self.write('task', 'staged dirty\n'); self.git('add', 'task')
        self.write('task', 'unstaged dirty\n'); self.write('new', 'untracked\n')
        before = self.snapshot()
        # Execute the skill recipe; FETCH_HEAD is pinned immediately and reads use only the SHA.
        self.git('branch', '--show-current'); self.git('rev-parse', 'HEAD')
        self.git('status', '--porcelain=v1', '--untracked-files=all')
        self.git('fetch', 'origin', 'refs/heads/main')
        pin = self.git('rev-parse', '--verify', 'FETCH_HEAD^{commit}').strip()
        self.assertEqual('base\n', self.git('show', pin + ':task'))
        self.assertEqual(before, self.snapshot())
        # A remote implementation may be ahead of local: read the remote pin, not disk.
        peer = Path(self.tmp.name) / 'peer'
        self.git('clone', str(remote), str(peer))
        original = self.repo
        self.repo = peer
        self.git('config', 'user.name', 'Peer'); self.git('config', 'user.email', 'peer@example.invalid')
        remote_sha = self.change('task', 'remote implementation\n')
        self.git('push', 'origin', 'main')
        self.repo = original
        self.git('fetch', 'origin', 'refs/heads/main')
        pin = self.git('rev-parse', '--verify', 'FETCH_HEAD^{commit}').strip()
        self.assertEqual(remote_sha, pin)
        self.assertEqual('remote implementation\n', self.git('show', pin + ':task'))
        self.assertEqual(before, self.snapshot())
        # Detached behind checkout is also inspectable without advancing HEAD.
        behind = Path(self.tmp.name) / 'behind'
        self.git('worktree', 'add', '--detach', str(behind), self.base)
        self.repo = behind
        before = self.snapshot()
        self.git('fetch', 'origin', 'refs/heads/main')
        pin = self.git('rev-parse', '--verify', 'FETCH_HEAD^{commit}').strip()
        self.assertEqual('remote implementation\n', self.git('show', pin + ':task'))
        self.assertEqual(before, self.snapshot())


if __name__ == '__main__':
    unittest.main()
