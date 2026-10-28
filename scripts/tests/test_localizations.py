import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile

spec = importlib.util.spec_from_file_location('localizations', Path(__file__).resolve().parents[1] / 'compile-localizations.py')
localizations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localizations)


class LocalizationValidationTests(unittest.TestCase):
    def unit(self, value='credits', state='translated'):
        return {'stringUnit': {'state': state, 'value': value}}

    def test_requires_a_translated_nonempty_string(self):
        for invalid in [None, {}, self.unit(''), self.unit(state='needs_review')]:
            self.assertFalse(localizations.is_complete_translation(invalid))
        self.assertTrue(localizations.is_complete_translation(self.unit()))

    def test_checks_every_plural_variant(self):
        translation = {'variations': {'plural': {'one': self.unit('credit'), 'other': self.unit()}}}
        self.assertTrue(localizations.is_complete_translation(translation))
        translation['variations']['plural']['other'] = self.unit(state='new')
        self.assertFalse(localizations.is_complete_translation(translation))

    def test_substitution_metadata_does_not_count_as_untranslated_text(self):
        translation = {'substitutions': {'count': {'argNum': 1, 'formatSpecifier': 'lld', 'variations': {'plural': {'other': self.unit()}}}}}
        self.assertTrue(localizations.is_complete_translation(translation))


class LocalizationGenerationTests(unittest.TestCase):
    def test_regeneration_replaces_corrupt_old_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'Generated'
            output.mkdir()
            (output / 'broken.strings').write_text('invalid old resource')

            def compile_catalog(command, **kwargs):
                compiled = Path(command[command.index('--output-directory') + 1]) / 'en.lproj'
                compiled.mkdir()
                (compiled / 'Localizable.strings').write_text('"hello" = "Hello";')

            with patch.object(localizations, 'OUTPUT', output), \
                 patch('sys.argv', ['compile-localizations.py']), \
                 patch.object(localizations.subprocess, 'run', side_effect=compile_catalog):
                localizations.main()

            self.assertFalse((output / 'broken.strings').exists())
            self.assertEqual((output / 'en.lproj/Localizable.strings').read_text(), '"hello" = "Hello";')
