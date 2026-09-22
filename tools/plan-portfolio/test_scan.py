import os
import tempfile
import unittest
from datetime import date
import scan


class TestScanRepo(unittest.TestCase):
    today = date(2026, 6, 14)

    def _write(self, root, rel, text):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def test_scan_finds_plans_and_specs(self):
        with tempfile.TemporaryDirectory() as root:
            self._write(root, "docs/plans/2026-06-01-active.md",
                        "---\ntype: plan\nstatus: in-progress\n---\n# Active\n")
            self._write(root, "docs/plans/implemented/2026-05-01-done.md", "# Done legacy\n")
            self._write(root, "docs/specs/2026-06-02-spec.md",
                        "---\ntype: spec\nstatus: draft\n---\n# Spec\n")
            items = {i.title: i for i in scan.scan_repo(root, "demo", self.today)}
            self.assertIn("Active", items)
            self.assertIn("Spec", items)
            done = items["Done legacy"]
            self.assertEqual(done.status, "implemented")  # inferred from folder
            self.assertFalse(done.has_frontmatter)
            # archived files are described by their folder -- not flagged for action
            self.assertNotIn("needs-frontmatter", done.flags)

    def test_created_inferred_from_filename(self):
        with tempfile.TemporaryDirectory() as root:
            self._write(root, "docs/plans/2026-03-09-x.md", "# X\n")
            items = scan.scan_repo(root, "demo", self.today)
            self.assertEqual(items[0].created, "2026-03-09")

    def test_index_and_readme_skipped(self):
        with tempfile.TemporaryDirectory() as root:
            self._write(root, "docs/plans/INDEX.md", "# Index\n")
            self._write(root, "docs/plans/README.md", "# Readme\n")
            self.assertEqual([], scan.scan_repo(root, "demo", self.today))


if __name__ == "__main__":
    unittest.main()
