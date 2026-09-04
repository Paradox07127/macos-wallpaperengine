#!/usr/bin/env python3
"""Catch translations that drifted away from the English they came from.

The `en` VALUE is the baseline, never the catalog key: some keys are explicit
identifiers (`error.app.file_access_denied`) whose text lives only in the value,
so comparing a key's placeholders against a value's reports every one of them.

Three failures, in descending severity:

  1. the placeholder set differs from `en` — the wrong value gets substituted,
     or `String(format:)` reads past its arguments
  2. a language is absent while `en` is present — that language silently falls
     back to English
  3. a language is present but not marked translated — it is a placeholder
     someone still has to write

Xcode omits the `en` entry entirely when the key *is* the English string; those
keys are checked against the key instead, which is the same text.

    python3 scripts/check_localization_drift.py [--self-test]
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'LiveWallpaper/Resources/Localizable.xcstrings'
REQUIRED = ('ja', 'zh-Hans', 'zh-Hant', 'es')

# %@  %1$@  %lld  %2$lld  %.2f  %03d
PLACEHOLDER = re.compile(r'%(?:\d+\$)?[-+ #0]*[\d.*]*(?:@|lld|ld|d|u|f|s)')


def signature(text):
    """Conversion types only, sorted, so `%@ %@` and `%1$@ %2$@` compare equal.

    Position is deliberately discarded: a translation is expected to reorder
    its placeholders, and a reorder is correct as long as the same set of
    values is consumed.
    """
    kinds = []
    for match in PLACEHOLDER.finditer(text):
        raw = match.group(0).lstrip('%').split('$')[-1]
        kinds.append(raw.lstrip('-+ #0123456789.*'))
    return sorted(kinds)


def audit(catalog):
    mismatch, missing, untranslated = [], [], []
    for key, entry in catalog.get('strings', {}).items():
        localizations = entry.get('localizations') or {}
        if not localizations:
            continue
        english = localizations.get('en', {}).get('stringUnit', {}).get('value')
        base = signature(english if english is not None else key)

        for lang in REQUIRED:
            unit = localizations.get(lang, {}).get('stringUnit')
            if unit is None:
                missing.append((key, lang))
                continue
            if unit.get('state') != 'translated':
                untranslated.append((key, lang, unit.get('state')))
            found = signature(unit.get('value', ''))
            if found != base:
                mismatch.append((key, lang, base, found))
    return mismatch, missing, untranslated


def self_test():
    """The guard has to fail on a drifted catalog, or it guards nothing."""
    def unit(value, state='translated'):
        return {'stringUnit': {'state': state, 'value': value}}

    drifted = {'strings': {
        'Linked %lld of %lld': {'localizations': {
            'en': unit('Linked %lld of %lld'),
            'ja': unit('%lld 件をリンク'),          # one placeholder lost
            'zh-Hans': unit('已链接 %lld / %lld'),
            'zh-Hant': unit('已連結 %lld / %lld'),
            'es': unit('Vinculados %lld de %lld'),
        }},
        'Reordered %1$@ then %2$@': {'localizations': {
            'en': unit('Reordered %1$@ then %2$@'),
            'ja': unit('%2$@ のあとに %1$@'),        # reorder: legal
            'zh-Hans': unit('先 %2$@ 再 %1$@'),
            'zh-Hant': unit('先 %2$@ 再 %1$@'),
            'es': unit('%2$@ y luego %1$@'),
        }},
        'Absent language': {'localizations': {
            'en': unit('Absent language'),
            'ja': unit('言語なし'),
            'zh-Hans': unit('缺语言'),
            'es': unit('Idioma ausente'),
        }},
        'Still a stub': {'localizations': {
            'en': unit('Still a stub'),
            'ja': unit('', 'new'),
            'zh-Hans': unit('存根'),
            'zh-Hant': unit('存根'),
            'es': unit('Borrador'),
        }},
    }}
    mismatch, missing, untranslated = audit(drifted)
    assert [m[0] for m in mismatch] == ['Linked %lld of %lld'], mismatch
    assert missing == [('Absent language', 'zh-Hant')], missing
    assert [u[0] for u in untranslated] == ['Still a stub'], untranslated

    clean = {'strings': {'All good %@': {'localizations': {
        'en': unit('All good %@'), 'ja': unit('問題なし %@'),
        'zh-Hans': unit('没问题 %@'), 'zh-Hant': unit('沒問題 %@'),
        'es': unit('Todo bien %@'),
    }}}}
    assert audit(clean) == ([], [], []), audit(clean)
    print('Localization drift self-test passed.')


def main():
    if '--self-test' in sys.argv:
        self_test()
        return 0

    catalog = json.loads(CATALOG.read_text())
    mismatch, missing, untranslated = audit(catalog)

    for key, lang, base, found in mismatch:
        print(f'PLACEHOLDER DRIFT  {lang:8} {key[:70]!r}\n'
              f'                   en={base}  {lang}={found}')
    for key, lang in missing:
        print(f'LANGUAGE ABSENT    {lang:8} {key[:70]!r}')
    for key, lang, state in untranslated:
        print(f'NOT TRANSLATED     {lang:8} [{state}] {key[:60]!r}')

    total = len(mismatch) + len(missing) + len(untranslated)
    checked = len(catalog.get('strings', {}))
    if total:
        print(f'\nLocalization drift: {total} problem(s) across {checked} keys.')
        return 1
    print(f'Localization drift: none across {checked} keys.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
