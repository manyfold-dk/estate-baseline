import unittest
from datetime import date
import model


class TestFolderBucket(unittest.TestCase):
    def test_top_level_is_active(self):
        self.assertEqual(model.folder_bucket("docs/plans/2026-01-01-x.md"), "active")

    def test_implemented_folder(self):
        self.assertEqual(model.folder_bucket("docs/plans/implemented/x.md"), "implemented")

    def test_archived_maps_to_implemented(self):
        self.assertEqual(model.folder_bucket("docs/plans/archived/x.md"), "implemented")

    def test_nested_app_path(self):
        self.assertEqual(
            model.folder_bucket("apps/example-app/docs/plans/implemented/x.md"),
            "implemented")

    def test_specs_subfolder_is_active(self):
        self.assertEqual(model.folder_bucket("docs/plans/specs/x.md"), "active")


def _item(status, has_fm=True, updated="2026-06-14", created="2026-06-14"):
    return model.PlanItem(
        repo="r", path="docs/plans/x.md", doc_type="plan", title="t",
        status=status, priority=None, computed_priority=None, owner=None,
        source=None, created=created, updated=updated, has_frontmatter=has_fm)


class TestDetectFlags(unittest.TestCase):
    today = date(2026, 6, 14)

    def test_implemented_in_active_folder_flagged(self):
        self.assertIn("implemented-not-archived",
                      model.detect_flags(_item("implemented"), "active", self.today))

    def test_active_in_done_folder_flagged(self):
        self.assertIn("active-status-in-done-folder",
                      model.detect_flags(_item("in-progress"), "implemented", self.today))

    def test_missing_frontmatter_flagged(self):
        self.assertIn("needs-frontmatter",
                      model.detect_flags(_item("draft", has_fm=False), "active", self.today))

    def test_missing_frontmatter_not_flagged_in_done_folder(self):
        # legacy archived files are described by their folder; no action needed
        self.assertNotIn("needs-frontmatter",
                         model.detect_flags(_item("implemented", has_fm=False),
                                            "implemented", self.today))

    def test_stale_active_flagged(self):
        old = _item("in-progress", updated="2026-01-01", created="2026-01-01")
        self.assertIn("stale", model.detect_flags(old, "active", self.today))

    def test_clean_item_no_flags(self):
        self.assertEqual([], model.detect_flags(_item("in-progress"), "active", self.today))


if __name__ == "__main__":
    unittest.main()
