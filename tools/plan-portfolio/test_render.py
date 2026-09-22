import unittest
from datetime import date
import model
import render


def _item(**kw):
    base = dict(repo="r", path="docs/plans/x.md", doc_type="plan", title="T",
        status="in-progress", priority=None, computed_priority="P2-computed",
        owner=None, source=None, created="2026-06-01", updated="2026-06-10",
        has_frontmatter=True, flags=[])
    base.update(kw)
    return model.PlanItem(**base)


class TestRender(unittest.TestCase):
    today = date(2026, 6, 14)

    def test_index_has_toc_and_row(self):
        out = render.render_repo_page("r", [_item()], self.today)
        self.assertIn("## Table of Contents", out)
        self.assertIn("| T |", out)

    def test_set_priority_overrides_computed(self):
        out = render.render_repo_page("r", [_item(priority="P0")], self.today)
        self.assertIn("P0", out)
        self.assertNotIn("P2-computed", out)

    def test_portfolio_has_drift_section(self):
        drift = _item(status="implemented", flags=["implemented-not-archived"])
        out = render.render_portfolio({"r": [drift]}, self.today)
        self.assertIn("## Implemented but not archived", out)
        self.assertIn("| r |", out)


if __name__ == "__main__":
    unittest.main()
