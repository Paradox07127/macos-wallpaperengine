#!/usr/bin/env python3
"""Validate repository-owned App Store text, without publishing anything."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Bundle resources use de/fr/en/es; Connect uses region-specific identifiers.
STORE_LOCALES = {'en-US', 'zh-Hans', 'zh-Hant', 'ja', 'es-ES', 'de-DE', 'fr-FR', 'ko', 'pt-BR'}


def inspect(metadata):
    errors = []
    if metadata.get('bundleID') != 'com.loomscreen.appstore':
        errors.append('Expected the App Store bundle identifier.')
    localizations = metadata.get('localizations', {})
    if set(localizations) != STORE_LOCALES:
        errors.append(f'Expected nine Store locales; got {sorted(localizations)}')
    for locale, fields in localizations.items():
        for field, limit in (('name', 30), ('subtitle', 30), ('description', 4000), ('keywords', 100)):
            value = fields.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(f'{locale}/{field}: missing text')
                continue
            length = len(value.encode('utf-8')) if field == 'keywords' else len(value)
            if length > limit:
                errors.append(f'{locale}/{field}: {length} exceeds {limit}')
    return errors


def self_test():
    fields = {'name': 'Loomscreen', 'subtitle': 'Video and web', 'description': 'Own media.', 'keywords': 'video,web'}
    data = {'bundleID': 'com.loomscreen.appstore', 'localizations': {locale: dict(fields) for locale in STORE_LOCALES}}
    assert not inspect(data)
    data['localizations']['de-DE']['subtitle'] = 'a' * 31
    assert any('de-DE/subtitle' in error for error in inspect(data))
    data['localizations']['de-DE']['subtitle'] = 'Video'
    data['localizations']['ko']['keywords'] = '가' * 34  # 102 UTF-8 bytes, 34 characters
    assert any('ko/keywords' in error for error in inspect(data))
    del data['localizations']['fr-FR']
    assert any('nine Store locales' in error for error in inspect(data))
    print('App Store metadata self-test passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('path', nargs='?', type=Path, default=ROOT / 'release/app-store/metadata.json')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        errors = inspect(json.loads(args.path.read_text()))
        if errors:
            parser.exit(1, '\n'.join(errors) + '\n')
        print('App Store metadata: nine locales, all required text within field limits.')
