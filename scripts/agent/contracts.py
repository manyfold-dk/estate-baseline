#!/usr/bin/env python3
"""Validate existing policy blocks, shipped references and optional local discovery links."""
import argparse
from pathlib import Path
import re
import sys


def profile_assets(payload, profile):
    text = (payload / 'profiles.yaml').read_text()
    match = re.search(r'^  ' + re.escape(profile) + r':\n((?:    .*\n)*)', text, re.M)
    return re.findall(r'^    - ([^\s#]+)', match[1], re.M) if match else []


def validate(payload, consumer=None, profile=None, discovery='legacy'):
    errors = []
    policy = (payload / 'POLICY.md').read_text()
    for name in ('AGENTS', 'CLAUDE'):
        text = (payload / f'{name}.baseline.md').read_text()
        blocks = re.findall(r'<!-- BEGIN policy -->\n(.*?)<!-- END policy -->', text, re.S)
        if blocks != [policy]:
            errors.append(f'{name}: common policy differs from POLICY.md')
    for prof in ([profile] if profile else ['app', 'docs']):
        assets = profile_assets(payload, prof)
        if not assets:
            errors.append(f'unknown/empty profile: {prof}')
            continue
        root = consumer / '.claude' if consumer else payload
        for asset in assets:
            if asset.endswith('.baseline.md'):
                continue
            path = root / asset
            if not path.is_file():
                errors.append(f'missing asset: {asset}')
                continue
            if path.suffix != '.md':
                continue
            # Templates contain deliberately illustrative links; only inspect prose links.
            text = re.sub(r'```.*?```', '', path.read_text(), flags=re.S)
            text = re.sub(r'(`+).*?\1', '', text, flags=re.S)
            for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', text):
                if re.match(r'[a-z]+:', target) or target.startswith('#'):
                    continue
                target = target.split('#')[0]
                resolved = (path.parent / target).resolve()
                if not resolved.is_relative_to(root.resolve()) or not resolved.is_file():
                    errors.append(f'{asset}: unresolved/nonlocal reference {target}')
        if consumer:
            expected = {Path(a).parts[1] for a in assets if a.startswith('skills/')}
            errors.extend(validate_discovery(consumer, expected, discovery))
    return errors


def validate_discovery(consumer, expected, discovery, preflight=False):
    errors = []
    active = consumer / '.agents/skills'
    if discovery == 'repo':
        if not active.resolve().is_relative_to(consumer.resolve()):
            errors.append('Codex discovery directory must stay within the consumer')
        for name in sorted(expected):
            link = active / name
            target = Path('../../.claude/skills') / name
            if not (consumer / '.claude/skills' / name).resolve().is_relative_to(consumer.resolve()):
                errors.append(f'Codex skill target must stay within the consumer: {name}')
            exists = link.exists() or link.is_symlink()
            if preflight and not exists:
                continue  # The vendor will create absent profile links.
            if (not link.is_symlink() or link.readlink() != target
                    or (not preflight and not (link / 'SKILL.md').is_file())):
                errors.append(f'Codex discovery missing/customized local link: {name}')
    if active.exists():
        seen = set()
        for skill in active.glob('*/SKILL.md'):
            match = re.search(r'^name:\s*(.+)$', skill.read_text(), re.M)
            if match:
                name = match[1].strip().strip("\"'")
                if name in seen:
                    errors.append(f'duplicate Codex skill name: {name}')
                seen.add(name)
        for link in active.iterdir():
            if not link.is_symlink():
                continue  # Consumer-owned real directories are not baseline links.
            target = Path('../../.claude/skills') / link.name
            will_vendor = preflight and link.name in expected
            if (link.readlink() != target
                    or (not will_vendor and not (link / 'SKILL.md').is_file())
                    or not link.resolve().is_relative_to(consumer.resolve())):
                errors.append(f'Codex skill link must resolve to its local owner: {link.name}')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--consumer', type=Path)
    parser.add_argument('--profile')
    parser.add_argument('--preflight-discovery', action='store_true')
    parser.add_argument('--discovery', choices=['legacy', 'repo'], default='legacy')
    args = parser.parse_args()
    if args.preflight_discovery:
        if args.consumer is None or args.profile is None:
            parser.error('preflight requires consumer and profile')
        assets = profile_assets(args.payload, args.profile)
        expected = {Path(a).parts[1] for a in assets if a.startswith('skills/')}
        errors = validate_discovery(args.consumer, expected, args.discovery, preflight=True)
    else:
        errors = validate(args.payload, args.consumer, args.profile, args.discovery)
    for error in errors:
        print('CONTRACT: ' + error, file=sys.stderr)
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
