#!/usr/bin/env python3
"""Launch the packaged app with a local read-only fixture; never use real Codex."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1]).resolve()
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
    subprocess.run([str(app / 'Contents/MacOS/CodexWatcher'), '--release-smoke-test'],
                   env=environment, timeout=60, check=True, stdout=subprocess.DEVNULL)
    report = root / 'result.txt'
    if not report.exists() or report.read_text() != 'passed\n':
        raise SystemExit('Packaged app did not pass startup checks')
    methods = [json.loads(line)['method'] for line in (root / 'requests.jsonl').read_text().splitlines()]
    allowed = {'initialize', 'initialized', 'account/read', 'account/rateLimits/read'}
    if set(methods) != allowed:
        raise SystemExit('Smoke fixture received unexpected requests')
print('Packaged app startup, popover/menu lifecycle, wake, fake reminder and confirmation navigation passed; no writes.')
