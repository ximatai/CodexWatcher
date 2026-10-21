import importlib.util
from pathlib import Path
import unittest
import subprocess
import sys
import tempfile

script = Path(__file__).resolve().parents[1] / 'generate-release-notes.py'
spec = importlib.util.spec_from_file_location('release_notes', script)
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ReleaseNotesTests(unittest.TestCase):
    def test_selects_only_exact_version_and_preserves_subheadings(self):
        text = '''# Changes
## 未发布
- Future work
## 0.2.1 — 2026-10-21
### 修复
- Released fix
## 0.2.0 — 2026-10-21
- Older work
'''
        self.assertEqual(notes.extract_changes(text, 'v0.2.1'), '### 修复\n- Released fix')

    def test_prerelease_requires_its_own_section(self):
        text = '## 0.3.0 — 2026-10-21\n- Stable\n'
        with self.assertRaises(ValueError):
            notes.extract_changes(text, 'v0.3.0-beta.1')
        text += '## 0.3.0-beta.1 — 2026-10-21\n- Beta\n'
        self.assertEqual(notes.extract_changes(text, 'v0.3.0-beta.1'), '- Beta')

    def test_missing_version_does_not_use_unreleased_or_prefix_match(self):
        for text in ['## 未发布\n- Future\n', '## 0.2.10 — 2026-10-21\n- Other\n']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                notes.extract_changes(text, 'v0.2.1')

    def test_empty_placeholder_and_comments_fail(self):
        for body in ['', '\n', '- ', '<!-- - TODO -->', '### Changes\n']:
            with self.subTest(body=body), self.assertRaises(ValueError):
                notes.extract_changes('## 0.2.1 — 2026-10-21\n' + body, 'v0.2.1')

    def test_duplicate_sections_fail(self):
        with self.assertRaises(ValueError):
            notes.extract_changes('## 0.2.1 — 2026-10-21\n- One\n' * 2, 'v0.2.1')

    def test_cli_missing_version_fails_without_writing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            changelog = root / 'CHANGELOG.md'
            changelog.write_text('## 未发布\n- Future\n')
            output = root / 'notes.md'
            result = subprocess.run([sys.executable, str(script), 'v9.9.9', str(output),
                '--changelog', str(changelog), '--repository', 'ximatai/CodexWatcher',
                '--revision', 'a' * 40], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Expected exactly one CHANGELOG section', result.stderr)
            self.assertFalse(output.exists())

    def test_invalid_tag_and_malformed_heading_fail(self):
        for tag in ['0.2.1', 'v0.2.1/other', 'v0.2.1;command']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                notes.extract_changes('## 0.2.1 — 2026-10-21\n- Fix', tag)
        with self.assertRaises(ValueError):
            notes.extract_changes('## 0.2.1\n- Missing date', 'v0.2.1')


if __name__ == '__main__':
    unittest.main()
