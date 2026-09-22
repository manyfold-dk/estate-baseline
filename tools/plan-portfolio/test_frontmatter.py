import unittest
import frontmatter


class TestFrontmatter(unittest.TestCase):
    def test_no_frontmatter_returns_empty(self):
        data, body = frontmatter.parse("# Title\n\ntext")
        self.assertEqual(data, {})
        self.assertEqual(body, "# Title\n\ntext")

    def test_parses_flat_pairs(self):
        text = "---\nstatus: draft\ntype: plan\n---\n# Title\n"
        data, body = frontmatter.parse(text)
        self.assertEqual(data["status"], "draft")
        self.assertEqual(data["type"], "plan")
        self.assertEqual(body, "# Title\n")

    def test_unclosed_block_is_not_frontmatter(self):
        data, body = frontmatter.parse("---\nstatus: draft\n# no close")
        self.assertEqual(data, {})


if __name__ == "__main__":
    unittest.main()
