#!/usr/bin/env python3
"""Check the packaged app with a read-only fixture; optional second argument exports layout previews."""
import argparse
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('previews', nargs='?', type=Path)
parser.add_argument('--language', choices=('en', 'zh-Hans'))
args = parser.parse_args()
app = args.app.resolve()
with tempfile.TemporaryDirectory(prefix='WatcherSmoke-') as directory:
    root = Path(directory)
    fake = root / 'fake-codex'
    fake.write_text('''#!/bin/sh
fixture_dir=$(/usr/bin/dirname "$0")
while IFS= read -r line; do
  printf '%s\\n' "$line" >> "$fixture_dir/requests.jsonl"
  id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
  case "$line" in
    *initialized*) continue ;;
    *initialize*) result='{}' ;;
    *account*rateLimits*read*) result=$(/bin/cat "$fixture_dir/usage.json") ;;
    *account*read*) result='{"account":{"type":"chatgpt","email":"smoke@example.invalid","planType":"pro"}}' ;;
    *) printf '{"id":%s,"error":{"code":-32601}}\\n' "$id"; continue ;;
  esac
  printf '{"id":%s,"result":%s}\\n' "$id" "$result"
done
''')
    fake.chmod(0o700)
    (root / 'usage.json').write_text(json.dumps({
        'accountId': 'smoke-fixture',
        'rateLimits': {'limitId': 'codex', 'primary': {
            'usedPercent': 0, 'windowDurationMins': 60, 'resetsAt': time.time() + 1800}},
        'rateLimitResetCredits': {'availableCount': 1, 'credits': [{
            'id': 'smoke-card', 'status': 'available', 'resetType': 'codexRateLimits',
            'grantedAt': time.time() - 60, 'expiresAt': time.time() + 800}]}
    }))
    # Strip credentials and proxy variables; the only child executable is the fixture.
    environment = {key: value for key, value in os.environ.items()
                   if key in ('HOME', 'USER', 'LOGNAME', 'TMPDIR', 'PATH', 'LANG')}
    environment['WATCHER_SMOKE_ROOT'] = directory
    command = [str(app / 'Contents/MacOS/CodexWatcher'), '--release-smoke-test']
    if args.language:
        command += ['-AppleLanguages', f'({args.language})', '-AppleLocale',
                    'en_US' if args.language == 'en' else 'zh_CN']
    subprocess.run(command,
                   env=environment, timeout=60, check=True, stdout=subprocess.DEVNULL)
    report = root / 'result.txt'
    if not report.exists() or report.read_text() != 'passed\n':
        raise SystemExit('Packaged app did not pass startup checks')
    methods = [json.loads(line)['method'] for line in (root / 'requests.jsonl').read_text().splitlines()]
    allowed = {'initialize', 'initialized', 'account/read', 'account/rateLimits/read'}
    if set(methods) != allowed:
        raise SystemExit('Smoke fixture received unexpected requests')
    if args.previews:
        previews = args.previews.resolve()
        previews.mkdir(parents=True, exist_ok=True)
        for preview in root.glob('popover-cards-*.png'):
            shutil.copy2(preview, previews / preview.name)
print('Packaged app startup, quota trend mouse/keyboard switching, popover/menu lifecycle, wake, fake reminder and confirmation navigation passed; no writes.')
