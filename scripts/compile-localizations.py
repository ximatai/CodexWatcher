#!/usr/bin/env python3
"""Compile the canonical catalog for SwiftPM; --check detects stale generated resources."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import shutil
import plistlib
import json

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'CodexWatcher/Localizable.xcstrings'
OUTPUT = ROOT / 'CodexWatcher/PackageLocalization'

def is_complete_translation(node):
    """Inspect string units without interpreting plural/substitution metadata."""
    units = []
    def visit(value):
        if isinstance(value, dict):
            if 'stringUnit' in value:
                units.append(value['stringUnit'])
            for key, child in value.items():
                if key != 'stringUnit':
                    visit(child)
    visit(node)
    return bool(units) and all(unit.get('state') == 'translated' and bool(unit.get('value')) for unit in units)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--stringsdata', type=Path, help='Check compiler-extracted keys after an Xcode build')
    args = parser.parse_args()
    if args.stringsdata:
        catalog = json.loads(CATALOG.read_text())['strings']
        extracted = set()
        files = list(args.stringsdata.rglob('*.stringsdata'))
        if not files:
            parser.exit(1, 'No compiler-extracted strings found. Build the app first.\n')
        for path in files:
            data = json.loads(path.read_text())
            for entry in data.get('tables', {}).get('Localizable', []):
                extracted.add(entry['key'])
        missing = sorted(extracted - catalog.keys())
        if missing:
            parser.exit(1, 'Missing catalog translations: ' + repr(missing) + '\n')
        for key in extracted:
            for language in ('en', 'zh-Hans'):
                translation = catalog[key].get('localizations', {}).get(language)
                if not is_complete_translation(translation):
                    parser.exit(1, f'Missing or incomplete {language} translation: {key}\n')
    with tempfile.TemporaryDirectory(prefix='WatcherLocalization-') as directory:
        temporary = Path(directory)
        subprocess.run(['xcrun', 'xcstringstool', 'compile', str(CATALOG),
                        '--output-directory', directory], check=True)
        def contents(directory):
            # Compare plist values, not serialization order across Xcode versions.
            return {p.relative_to(directory): plistlib.loads(subprocess.check_output(
                ['plutil', '-convert', 'xml1', '-o', '-', str(p)]))
                for p in directory.rglob('*') if p.is_file()}
        if args.check:
            if contents(temporary) != contents(OUTPUT):
                parser.exit(1, 'Generated localization resources are stale. Run python3 scripts/compile-localizations.py\n')
        else:
            if OUTPUT.exists():
                shutil.rmtree(OUTPUT)
            shutil.copytree(temporary, OUTPUT)

if __name__ == '__main__':
    main()
