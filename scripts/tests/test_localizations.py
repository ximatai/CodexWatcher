import importlib.util
from pathlib import Path
import unittest

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
