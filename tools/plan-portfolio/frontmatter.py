"""Minimal flat-YAML frontmatter parser -- stdlib only, no pip deps."""
from __future__ import annotations


def parse(text: str) -> tuple[dict, str]:
    """Split markdown into (frontmatter_dict, body).

    Recognizes a leading block delimited by '---' lines and parses flat
    'key: value' pairs. Returns ({}, text) when no closing block is found.
    """
    if not text.startswith("---"):
        return {}, text
    lines = text.splitlines(keepends=True)
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return {}, text
    data: dict = {}
    for line in lines[1:end]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or ":" not in line:
            continue
        key, _, value = line.partition(":")
        data[key.strip()] = value.strip()
    body = "".join(lines[end + 1:])
    return data, body
