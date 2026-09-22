#!/usr/bin/env python3
"""Generate per-repo plan INDEX.md and the umbrella PORTFOLIO.md.

Usage:
  generate.py           write docs/portfolio/ (the umbrella is the only output location)
  generate.py --check   render as of the committed portfolio's generation date, diff against
                        docs/portfolio/, write nothing; exit 1 on drift
"""
from __future__ import annotations
import difflib
import os
import re
import sys
from datetime import date

import scan
import render

HERE = os.path.dirname(os.path.abspath(__file__))
UMBRELLA = os.path.dirname(os.path.dirname(HERE))   # tools/plan-portfolio -> umbrella
PRIVATE = os.path.dirname(UMBRELLA)                 # siblings live next to umbrella
# The repos to scan, one per line. Private to each installation; repos.example.txt shows the shape.
REPOS_FILE = os.path.join(HERE, "repos.txt")


def _load_repos() -> list:
    repos = []
    with open(REPOS_FILE, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                repos.append(line)
    return repos


_STAMP = re.compile(r"generated (\d{4}-\d{2}-\d{2}) -->")


def _committed_date(portfolio_dir: str, today: date) -> date:
    """Date the committed PORTFOLIO.md was generated on; today when unstamped/missing."""
    try:
        with open(os.path.join(portfolio_dir, "PORTFOLIO.md"), encoding="utf-8") as fh:
            m = _STAMP.search(fh.read())
    except OSError:
        return today
    return date.fromisoformat(m.group(1)) if m else today


def build(as_of: date) -> dict:
    """Render every output page in memory: {relative filename: content}."""
    pages: dict = {}
    items_by_repo: dict = {}
    for repo in _load_repos():
        repo_root = os.path.join(PRIVATE, repo)
        if not os.path.isdir(repo_root):
            print(f"WARN: repo not found: {repo_root}", file=sys.stderr)
            continue
        items = scan.scan_repo(repo_root, repo, as_of)
        items_by_repo[repo] = items
        pages[f"{repo}.md"] = render.render_repo_page(repo, items, as_of)
    pages["PORTFOLIO.md"] = render.render_portfolio(items_by_repo, as_of)
    return pages


def main(argv: list | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    check = "--check" in argv
    today = date.today()
    # All output lives in the umbrella; sibling repos get no generated artifacts.
    portfolio_dir = os.path.join(UMBRELLA, "docs", "portfolio")
    if check:
        as_of = _committed_date(portfolio_dir, today)
        pages = build(as_of)
        drift = 0
        for name, content in pages.items():
            path = os.path.join(portfolio_dir, name)
            try:
                with open(path, encoding="utf-8") as fh:
                    current = fh.read()
            except OSError:
                current = ""
            if current != content:
                drift += 1
                sys.stdout.writelines(difflib.unified_diff(
                    current.splitlines(True), content.splitlines(True),
                    fromfile=f"committed/{name}", tofile=f"rendered/{name}"))
        if drift:
            print(f"DRIFT: {drift} page(s) differ from docs/portfolio/ (as of {as_of}); run generate.py to refresh")
            return 1
        print(f"OK: docs/portfolio/ is current (as of {as_of})")
        return 0
    os.makedirs(portfolio_dir, exist_ok=True)
    for name, content in build(today).items():
        path = os.path.join(portfolio_dir, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
