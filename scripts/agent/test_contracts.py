import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from contracts import validate
from check_global_skills import check

REPO = Path(__file__).resolve().parents[2]
PAYLOAD = REPO / 'baseline-agent'
VENDOR = REPO / 'scripts/agent/vendor.sh'
INSTALL = REPO / 'scripts/agent/global-install.sh'


class Contracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.consumer = self.root / 'consumer'
        self.consumer.mkdir()

    def vendor(self, profile='app', discovery='legacy'):
        return subprocess.run([str(VENDOR), '--profile', profile, '--codex-discovery', discovery],
                              cwd=self.consumer, capture_output=True, text=True)

    def test_common_policy_and_protected_clauses(self):
        self.assertEqual([], validate(PAYLOAD))
        policy = (PAYLOAD / 'POLICY.md').read_text()
        for clause in ['AUTH-01', 'BRANCH-01', 'OWN-01', 'PUBLISH-01', 'VERIFY-01', 'REPO-01', 'SECRET-01', 'COMPLETE-01']:
            self.assertIn(clause, policy)
        clone = self.root / 'payload'
        shutil.copytree(PAYLOAD, clone)
        path = clone / 'AGENTS.baseline.md'
        path.write_text(path.read_text().replace('AUTH-01', 'BROKEN-01'))
        self.assertTrue(validate(clone))

    def test_both_profiles_roundtrip_references_and_preserve_overlays(self):
        for profile in ['app', 'docs']:
            (self.consumer / 'AGENTS.md').write_text('# Local Codex instructions\n')
            overlay = self.consumer / '.claude/skills/dev-workflow/environment.md'
            overlay.parent.mkdir(parents=True, exist_ok=True)
            overlay.write_text((REPO / 'scripts/agent/fixtures/domain-environment.md').read_text())
            self.assertEqual(0, self.vendor(profile).returncode)
            self.assertEqual([], validate(PAYLOAD, self.consumer, profile))
            self.assertIn('Local Codex instructions', (self.consumer / 'AGENTS.md').read_text())
            self.assertIn('verify-domain.sh --dry-run', overlay.read_text())
            before = {str(p): p.read_bytes() for p in self.consumer.rglob('*') if p.is_file() and p.name != '.baseline-agent-version'}
            self.assertEqual(0, self.vendor(profile).returncode)
            self.assertEqual(before, {str(p): p.read_bytes() for p in self.consumer.rglob('*') if p.is_file() and p.name != '.baseline-agent-version'})
            helper = self.consumer / '.claude/helpers/review_scope.py'
            self.assertEqual(0, subprocess.run(['python3', str(helper), '--help'], capture_output=True).returncode)
            # A domain overlay stays runnable without contacting any infrastructure.
            script = self.consumer / 'verify-domain.sh'
            script.write_text((REPO / 'scripts/agent/fixtures/verify-domain.sh').read_text())
            result = subprocess.run(['sh', str(script), '--dry-run'], capture_output=True, text=True)
            self.assertEqual('domain fixture passed\n', result.stdout)

    def test_missing_reference_and_duplicate_discovery_fail(self):
        self.assertEqual(0, self.vendor('docs', 'repo').returncode)
        reference = self.consumer / '.claude/references/documentation/lifecycle.md'
        reference.unlink()
        self.assertTrue(any('lifecycle' in e for e in validate(PAYLOAD, self.consumer, 'docs', 'repo')))
        self.vendor('docs', 'repo')
        alias = self.consumer / '.agents/skills/duplicate'
        alias.symlink_to('../../.claude/skills/plan-writing')
        self.assertTrue(any('duplicate' in e for e in validate(PAYLOAD, self.consumer, 'docs', 'repo')))

    def test_candidate_links_are_local_and_customize_conflict_preserved(self):
        link = self.consumer / '.agents/skills/plan-design'
        link.mkdir(parents=True)
        (link / 'SKILL.md').write_text('custom skill\n')
        self.assertNotEqual(0, self.vendor('docs', 'repo').returncode)
        self.assertEqual('custom skill\n', (link / 'SKILL.md').read_text())
        self.assertFalse((self.consumer / '.claude/.baseline-agent-version').exists())
        shutil.rmtree(link)
        self.assertEqual(0, self.vendor('docs', 'repo').returncode)
        self.assertEqual(Path('../../.claude/skills/plan-design'), link.readlink())
        moved = self.root / 'relocated'
        self.consumer.rename(moved)
        self.consumer = moved
        self.assertEqual([], validate(PAYLOAD, moved, 'docs', 'repo'))

    def test_refusal_preserves_payload_marker_index_and_stamp_bytes(self):
        self.assertEqual(0, self.vendor('docs', 'repo').returncode)
        subprocess.run(['git', 'init', '-q', str(self.consumer)], check=True)
        (self.consumer / 'AGENTS.md').write_text('Owned staged instructions\n')
        subprocess.run(['git', '-C', str(self.consumer), 'add', 'AGENTS.md'], check=True)
        (self.consumer / '.claude/rules/documentation.md').write_text('Owned pending rule edit\n')
        link = self.consumer / '.agents/skills/plan-design'
        link.unlink(); link.mkdir()
        (link / 'SKILL.md').write_text('custom discovery entry\n')
        def snapshot():
            files = {}
            for path in self.consumer.rglob('*'):
                rel = path.relative_to(self.consumer)
                if '.git' in rel.parts:
                    continue
                if path.is_symlink():
                    files[str(rel)] = str(path.readlink())
                elif path.is_file():
                    files[str(rel)] = path.read_bytes()
            return files, (self.consumer / '.git/index').read_bytes()
        before = snapshot()
        self.assertNotEqual(0, self.vendor('docs', 'repo').returncode)
        self.assertEqual(before, snapshot())
        shutil.rmtree(link)
        link.symlink_to('../../.claude/skills/plan-design')
        external = self.root / 'external'
        external.mkdir(); (external / 'SKILL.md').write_text('---\nname: external\n---\n')
        (self.consumer / '.agents/skills/external').symlink_to(external)
        before = snapshot()
        self.assertNotEqual(0, self.vendor('docs', 'repo').returncode)
        self.assertEqual(before, snapshot())

    def test_inline_code_examples_are_not_relative_links(self):
        self.assertEqual(0, self.vendor('docs').returncode)
        path = self.consumer / '.claude/skills/plan-writing/SKILL.md'
        path.write_text(path.read_text() + '\nExample: `[Link](missing.md)` and ``[Other](absent.md)``.\n')
        self.assertEqual([], validate(PAYLOAD, self.consumer, 'docs'))
        path.write_text(path.read_text() + '\n[Actual broken reference](missing.md)\n')
        self.assertTrue(any('missing.md' in error for error in validate(PAYLOAD, self.consumer, 'docs')))

    def test_consumer_owned_discovery_links_preserved_and_validated(self):
        owned = self.consumer / '.claude/skills/domain-status'
        owned.mkdir(parents=True)
        (owned / 'SKILL.md').write_text('---\nname: domain-status\ndescription: Fixture domain check.\n---\n')
        active = self.consumer / '.agents/skills'
        active.mkdir(parents=True)
        link = active / 'domain-status'
        link.symlink_to('../../.claude/skills/domain-status')
        self.assertEqual(0, self.vendor('docs', 'repo').returncode)
        self.assertEqual([], validate(PAYLOAD, self.consumer, 'docs', 'repo'))
        self.assertEqual(Path('../../.claude/skills/domain-status'), link.readlink())
        outside = self.root / 'outside'
        shutil.copytree(owned, outside)
        link.unlink(); link.symlink_to(outside)
        self.assertTrue(any('local owner' in e for e in validate(PAYLOAD, self.consumer, 'docs', 'repo')))
        link.unlink(); link.symlink_to('../../.claude/skills/missing')
        self.assertTrue(any('local owner' in e for e in validate(PAYLOAD, self.consumer, 'docs', 'repo')))

    def test_unsupported_dependencies_removed_and_lifecycle_retained(self):
        for path in [*PAYLOAD.glob('skills/*/SKILL.md'), *PAYLOAD.glob('agents/*.md')]:
            text = path.read_text()
            for forbidden in ['superpowers:', 'REQUIRED SUB-SKILL', 'HEAD~1', 'main...HEAD', 'TaskCreate', 'AskUserQuestionTool']:
                self.assertNotIn(forbidden, text, str(path))
        self.assertIn('Read-only review leaves status unchanged', (PAYLOAD / 'skills/dev-workflow/SKILL.md').read_text())
        self.assertIn('read-only review remains', (PAYLOAD / 'agents/spec-reviewer.md').read_text())
        for runtime in ['CLAUDE', 'AGENTS']:
            text = (PAYLOAD / f'{runtime}.baseline.md').read_text()
            self.assertIn('locally when equipped', text)
            self.assertIn('bypass permissions', text)
        self.assertNotIn('allowed-tools:', (PAYLOAD / 'skills/interview/SKILL.md').read_text())

    def install(self, *args):
        return subprocess.run([str(INSTALL), '--bootstrap-source', str(self.root / 'bootstrap'), *args],
                              env={**os.environ, 'HOME': str(self.root / 'home')}, capture_output=True, text=True)

    def bootstrap_link(self):
        target = self.root / 'bootstrap/codex/AGENTS.md'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('Load ~/.config/manyfold/agent-policy.md only without a baseline block.\n')
        link = self.root / 'home/.codex/AGENTS.md'
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink():
            link.unlink()
        link.symlink_to(target)
        return link

    def test_clean_home_installer_handoff_both_orders_idempotent(self):
        for bootstrap_first in [False, True]:
            shutil.rmtree(self.root / 'home', ignore_errors=True)
            if bootstrap_first:
                self.bootstrap_link()
            self.assertEqual(0, self.install().returncode)
            link = self.bootstrap_link()
            before = link.readlink()
            self.assertEqual(0, self.install().returncode)
            self.assertEqual(0, self.install('--check').returncode)
            self.assertEqual(before, link.readlink())
            policy = self.root / 'home/.config/manyfold'
            self.assertEqual(0o700, policy.stat().st_mode & 0o777)
            self.assertEqual(PAYLOAD / 'POLICY.md', (policy / 'agent-policy.md').readlink())

    def test_exact_legacy_link_tolerated_unknown_rejected(self):
        self.assertEqual(0, self.install().returncode)
        link = self.root / 'home/.codex/AGENTS.md'
        link.symlink_to(PAYLOAD / 'AGENTS.baseline.md')
        result = self.install('--check')
        self.assertEqual(0, result.returncode)
        self.assertIn('LEGACY (bootstrap replaces)', result.stdout)
        self.assertEqual(PAYLOAD / 'AGENTS.baseline.md', link.readlink())
        link.unlink(); link.symlink_to(PAYLOAD / 'CLAUDE.baseline.md')
        self.assertNotEqual(0, self.install('--check').returncode)
        self.install()
        self.assertEqual(PAYLOAD / 'CLAUDE.baseline.md', link.readlink())

    def test_old_installer_reassertion_is_detected_by_bootstrap_ownership(self):
        # Exact historical ownership mutation; bootstrap final-state invariant rejects it.
        self.install(); link = self.bootstrap_link()
        expected = link.readlink()
        subprocess.run(['ln', '-snf', str(PAYLOAD / 'AGENTS.baseline.md'), str(link)], check=True)
        self.assertNotEqual(expected, link.readlink())
        self.assertIn('LEGACY', self.install('--check').stdout)
        self.bootstrap_link()
        self.install()
        self.assertEqual(expected, link.readlink())

    def test_customizations_existing_policy_mode_and_retired_preserved(self):
        home = self.root / 'home'
        custom = home / '.codex/skills/local/interview/SKILL.md'
        custom.parent.mkdir(parents=True)
        custom.write_text('---\nname: interview\n---\ncustom\n')
        policy = home / '.config/manyfold'
        policy.mkdir(parents=True); policy.chmod(0o755)
        self.assertNotEqual(0, self.install().returncode)
        self.assertIn('custom', custom.read_text())
        self.assertEqual(0o755, policy.stat().st_mode & 0o777)
        retired = home / '.codex/skills/_retired/sync-with-claude/SKILL.md'
        retired.parent.mkdir(parents=True); retired.write_text('---\nname: sync-with-claude\n---\ncustom retired\n')
        self.assertTrue(any('RETIRED' in e for e in check(home)))
        self.assertIn('custom retired', retired.read_text())
        duplicate = home / '.agents/skills/interview/SKILL.md'
        duplicate.parent.mkdir(parents=True); duplicate.write_text(custom.read_text())
        self.assertTrue(any('DUPLICATE' in e for e in check(home)))

    def test_one_skill_reachable_from_both_user_roots_is_not_a_duplicate(self):
        # Platform provisioning (Omarchy) links its own skills into both discovered roots
        # from one source directory; reachability from two roots is not shadowing.
        home = self.root / 'home'
        source = self.root / 'share/agents/skills/omarchy'
        source.mkdir(parents=True)
        (source / 'SKILL.md').write_text('---\nname: omarchy\n---\nprovisioned\n')
        for root in ['.codex/skills', '.agents/skills']:
            link = home / root / 'omarchy'
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(source)
        self.assertEqual([], check(home))
        # A second, different skill claiming that name still shadows it.
        rival = home / '.codex/skills/rival/SKILL.md'
        rival.parent.mkdir(parents=True)
        rival.write_text('---\nname: omarchy\n---\nlocal\n')
        self.assertTrue(any('DUPLICATE' in e for e in check(home)))


if __name__ == '__main__':
    unittest.main()
