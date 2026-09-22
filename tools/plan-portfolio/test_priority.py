import unittest
from datetime import date
import model
import priority


def _item(status, path, updated="2026-06-14", created="2026-06-14"):
    return model.PlanItem(repo="r", path=path, doc_type="plan", title="t",
        status=status, priority=None, computed_priority=None, owner=None,
        source=None, created=created, updated=updated, has_frontmatter=True)


class TestPriority(unittest.TestCase):
    today = date(2026, 6, 14)

    def test_done_items_blank(self):
        self.assertEqual("", priority.compute(_item("implemented", "docs/plans/x.md"), self.today))

    def test_computed_suffix(self):
        p = priority.compute(_item("draft", "docs/plans/x-credential-rotation.md"), self.today)
        self.assertTrue(p.startswith("P") and p.endswith("-computed"))

    def test_security_outranks_plain(self):
        sec = priority.compute(_item("draft", "docs/plans/x-backup-hardening.md"), self.today)
        plain = priority.compute(_item("draft", "docs/plans/x-rename-thing.md"), self.today)
        self.assertLess(int(sec[1]), int(plain[1]))  # lower P number = higher priority


if __name__ == "__main__":
    unittest.main()
