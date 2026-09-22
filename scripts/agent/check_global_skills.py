#!/usr/bin/env python3
"""Inspect only skill entry metadata. Never read settings or credential files."""
import os
from pathlib import Path
import re
import sys


def entries(root):
    # followlinks is needed for skill roots; prune cycles without hiding sibling duplicates.
    for directory, dirs, files in os.walk(root, followlinks=True):
        path = Path(directory)
        ancestors = {p.resolve() for p in path.parents if p != root.parent}
        dirs[:] = [d for d in dirs if (path / d).resolve() not in ancestors]
        if 'SKILL.md' in files:
            yield path / 'SKILL.md'


def check(home):
    errors = []
    for roots in [('.codex/skills', '.agents/skills'), ('.claude/skills',)]:
        seen = {}
        for root in roots:
            for path in entries(home / root):
                match = re.search(r'^name:\s*(.+)$', path.read_text(), re.M)
                if not match:
                    continue
                name = match[1].strip().strip('"\'')
                if name == 'sync-with-claude':
                    errors.append('RETIRED active skill: sync-with-claude; preserve outside discovered roots')
                # Shadowing is two different skills claiming one name. Platform provisioning
                # links a single skill into several discovered roots; compare the real file
                # so that reachability is not reported as a duplicate.
                real = path.resolve()
                claimed = seen.setdefault(name, set())
                if claimed and real not in claimed:
                    errors.append(f'DUPLICATE skill: {name} in {roots}')
                claimed.add(real)
    return errors


if __name__ == '__main__':
    errors = check(Path(sys.argv[1]))
    for error in errors:
        print(error)
    sys.exit(bool(errors))
