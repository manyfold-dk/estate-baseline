#!/usr/bin/env python3
"""Generate per-repo plan pages and the PORTFOLIO.md that spans them.

Usage:
  generate.py --repos FILE --root DIR --out DIR           write the pages into --out
  generate.py --repos FILE --root DIR --out DIR --check   render as of the committed
                        portfolio's generation date, diff against --out, write nothing;
                        exit 1 on drift

Every location is an argument. The generator derives nothing from where it is installed:
the repositories it reads and the pages it writes carry the names of those repositories,
and the checkout that holds this script may be a public one. --repos lists the repositories
to scan, one name per line (repos.example.txt shows the shape); each is a directory under
--root; --out is the directory the pages are written to, normally inside the repository
that owns the portfolio.
"""
from __future__ import annotations
import argparse
import difflib
import os
import re
import sys
from datetime import date

import scan
import render


def _load_repos(repos_file: str) -> list:
    repos = []
    with open(repos_file, encoding="utf-8") as fh:
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


def build(as_of: date, root: str, repos_file: str) -> dict:
    """Render every output page in memory: {relative filename: content}."""
    pages: dict = {}
    items_by_repo: dict = {}
    for repo in _load_repos(repos_file):
        repo_root = os.path.join(root, repo)
        if not os.path.isdir(repo_root):
            print(f"WARN: repo not found: {repo_root}", file=sys.stderr)
            continue
        items = scan.scan_repo(repo_root, repo, as_of)
        items_by_repo[repo] = items
        pages[f"{repo}.md"] = render.render_repo_page(repo, items, as_of)
    pages["PORTFOLIO.md"] = render.render_portfolio(items_by_repo, as_of)
    return pages


def parse_args(argv: list) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate the plan portfolio.")
    parser.add_argument("--repos", required=True, help="file listing the repositories to scan, one per line")
    parser.add_argument("--root", required=True, help="directory the listed repositories live under")
    parser.add_argument("--out", required=True, help="directory the pages are written to")
    parser.add_argument("--check", action="store_true", help="diff against --out, write nothing")
    return parser.parse_args(argv)


def main(argv: list | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    check = args.check
    today = date.today()
    root, repos_file = os.path.abspath(args.root), os.path.abspath(args.repos)
    # Output goes where the caller said and nowhere else; the scanned repos get nothing.
    portfolio_dir = os.path.abspath(args.out)
    if check:
        as_of = _committed_date(portfolio_dir, today)
        pages = build(as_of, root, repos_file)
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
            print(f"DRIFT: {drift} page(s) differ from {portfolio_dir} (as of {as_of}); run generate.py to refresh")
            return 1
        print(f"OK: {portfolio_dir} is current (as of {as_of})")
        return 0
    os.makedirs(portfolio_dir, exist_ok=True)
    for name, content in build(today, root, repos_file).items():
        path = os.path.join(portfolio_dir, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
