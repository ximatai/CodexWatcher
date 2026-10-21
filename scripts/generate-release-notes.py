#!/usr/bin/env python3
"""Generate release notes from one exact, nonempty CHANGELOG version section."""
import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?'


def extract_changes(changelog: str, tag: str) -> str:
    if not re.fullmatch('v' + VERSION, tag):
        raise ValueError('Invalid version tag')
    version = tag[1:]
    sections = re.split(r'^##\s+', changelog, flags=re.MULTILINE)[1:]
    matches = []
    for section in sections:
        heading, _, body = section.partition('\n')
        if re.fullmatch(re.escape(version) + r'\s+—\s+\d{4}-\d{2}-\d{2}\s*', heading):
            matches.append(body.strip())
    if len(matches) != 1:
        raise ValueError(f'Expected exactly one CHANGELOG section: ## {version} — YYYY-MM-DD')
    body = re.sub(r'<!--.*?-->', '', matches[0], flags=re.DOTALL).strip()
    if not re.search(r'^-\s+\S', body, flags=re.MULTILINE):
        raise ValueError(f'CHANGELOG section {version} must contain at least one change')
    return body


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('output', type=Path)
    parser.add_argument('--changelog', type=Path, default=ROOT / 'CHANGELOG.md')
    parser.add_argument('--repository', required=True)
    parser.add_argument('--revision', required=True, help='Commit containing this CHANGELOG')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
        parser.error('Invalid repository')
    if not re.fullmatch(r'[0-9a-f]{40}', args.revision):
        parser.error('Revision must be a full Git commit SHA')
    try:
        changes = extract_changes(args.changelog.read_text(), args.tag)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    installation = (ROOT / 'docs/RELEASE_INSTALLATION.md').read_text().strip()
    source = f'https://github.com/{args.repository}/blob/{args.revision}/CHANGELOG.md'
    args.output.write_text(f'## 本版变更\n\n{changes}\n\n'
                           f'[完整更新记录]({source})\n\n{installation}\n')


if __name__ == '__main__':
    main()
