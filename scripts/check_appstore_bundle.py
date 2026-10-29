#!/usr/bin/env python3
"""Inspect the actual MAS Release bundle; this does not replace Apple's validation."""

import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def inspect(app, require_distribution=False):
    errors = []
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.loomscreen.appstore':
        errors.append('Expected com.loomscreen.appstore; Lite has the same product filename.')
    if any(key.startswith('SU') for key in info):
        errors.append('Sparkle Info.plist keys are present.')
    for key in ('NSAppleEventsUsageDescription', 'NSAudioCaptureUsageDescription'):
        if key in info:
            errors.append(f'Unused permission: {key}')
    exports = info.get('UTExportedTypeDeclarations', [])
    if not any(item.get('UTTypeIdentifier') == 'com.loomscreen.appstore.config'
               and 'lwconfig' in item.get('UTTypeTagSpecification', {}).get('public.filename-extension', [])
               for item in exports):
        errors.append('MAS configuration UTI must declare .lwconfig.')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    run('bash', str(ROOT / 'scripts/check_entitlements.sh'), '--sku', 'appstore', '--app', str(app))
    signature = subprocess.run(['codesign', '-dvv', str(app)], check=True,
                               capture_output=True, text=True).stderr
    flags = re.search(r'flags=0x[0-9a-f]+\(([^)]*)\)', signature, re.IGNORECASE)
    if not flags or 'runtime' not in flags.group(1).split(','):
        errors.append('Hardened Runtime is not enabled in the signature.')
    if require_distribution and not re.search(r'Authority=(Apple Distribution:|3rd Party Mac Developer Application:)', signature):
        errors.append('A Mac App Store distribution signature is required for submission.')
    resources = app / 'Contents/Resources'
    catalogs = {
        'Localizable.strings': json.loads((ROOT / 'LiveWallpaper/Resources/Localizable.xcstrings').read_text()),
        'InfoPlist.strings': json.loads((ROOT / 'LiveWallpaper/Resources/AppStore/InfoPlist.xcstrings').read_text()),
    }
    for language in ('de', 'en', 'es', 'fr', 'ja', 'ko', 'pt-BR', 'zh-Hans', 'zh-Hant'):
        directory = resources / f'{language}.lproj'
        for name, catalog in catalogs.items():
            path = directory / name
            if not path.is_file():
                errors.append(f'Missing compiled localization: {language}/{name}')
                continue
            compiled = json.loads(run('plutil', '-convert', 'json', '-o', '-', str(path)))
            if not compiled:
                errors.append(f'Empty compiled localization: {language}/{name}')
            # Compare every flat translation to the source, catching stale/English
            # resources even when a nonempty .lproj exists.
            for key, entry in catalog['strings'].items():
                if entry.get('shouldTranslate') is False:
                    continue
                unit = entry.get('localizations', {}).get(language, {}).get('stringUnit')
                if unit and unit.get('state') == 'translated' and 'substitutions' not in entry.get('localizations', {}).get(language, {}):
                    if compiled.get(key) != unit['value']:
                        errors.append(f'Stale compiled translation: {language}/{name}/{key}')
        plural_keys = {
            key for key, entry in catalogs['Localizable.strings']['strings'].items()
            if any(field in entry.get('localizations', {}).get(language, {})
                   for field in ('variations', 'substitutions'))
        }
        plural_path = directory / 'Localizable.stringsdict'
        if plural_keys and not plural_path.is_file():
            errors.append(f'Missing compiled plurals: {language}')
        elif plural_keys:
            plurals = json.loads(run('plutil', '-convert', 'json', '-o', '-', str(plural_path)))
            for key in sorted(plural_keys - plurals.keys()):
                errors.append(f'Missing compiled plural: {language}/{key}')
    privacy = plistlib.loads((resources / 'PrivacyInfo.xcprivacy').read_bytes())
    if privacy.get('NSPrivacyTracking') is not False:
        errors.append('Tracking must remain disabled.')
    reasons = {item['NSPrivacyAccessedAPIType'] for item in privacy.get('NSPrivacyAccessedAPITypes', [])}
    for category in ('UserDefaults', 'FileTimestamp', 'SystemBootTime'):
        if f'NSPrivacyAccessedAPICategory{category}' not in reasons:
            errors.append(f'Missing required-reason API category: {category}')
    forbidden_names = ('sparkle', 'steamconnector', 'wallpapermaintenance', 'systemwallpaperprovider')
    macho_magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
    payloads = []
    for path in app.rglob('*'):
        if path.suffix in ('.xpc', '.appex') or any(word in path.name.lower() for word in forbidden_names):
            errors.append(f'Forbidden bundled component: {path.relative_to(app)}')
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) in macho_magic:
                    payloads.append(path)
    if not payloads:
        errors.append('No Mach-O payload found.')
    forbidden_symbols = re.compile(r'\b(?:_IOServiceOpen|_proc_listallpids|_proc_pidpath|_proc_pid_rusage|_proc_pidinfo|_OBJC_CLASS_\$_NSAppleScript)\b')
    forbidden_strings = ('drawsBackground', 'CGSSessionScreenIsLocked', 'com.apple.screenIsLocked',
                         'com.apple.screenIsUnlocked', 'idleassetsd', 'AppleSMC', 'SUFeedURL',
                         'loomscreen-feed.', 'lrclib.net', 'itunes.apple.com/search', 'open.spotify.com/oembed')
    for payload in payloads:
        relative = payload.relative_to(app)
        architectures = set(run('lipo', '-archs', str(payload)).split())
        if architectures != {'arm64', 'x86_64'}:
            errors.append(f'{relative}: expected arm64 + x86_64, got {architectures}')
        dependencies = run('otool', '-L', str(payload))
        if any(word in dependencies for word in ('Sparkle', 'LiveWallpaperProWPE', 'JavaScriptCore')):
            errors.append(f'{relative}: forbidden direct dependency')
        for symbol in set(forbidden_symbols.findall(run('nm', '-u', str(payload)))):
            errors.append(f'{relative}: forbidden imported symbol {symbol}')
        strings = run('strings', '-a', str(payload))
        for needle in forbidden_strings:
            if needle in strings:
                errors.append(f'{relative}: forbidden API/endpoint string {needle}')
        if 'QAControlPlane' in strings or 'loomscreen-qa.sock' in strings:
            errors.append(f'{relative}: DEBUG QA implementation in Release')
        print(f'Inspected {relative}: {", ".join(sorted(architectures))}')
    if errors:
        raise ValueError('\n'.join(errors))
    print(f'Local MAS bundle checks passed: {app}')
    print('App Store Connect/Organizer validation and runtime acceptance remain separate requirements.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--require-distribution', action='store_true')
    args = parser.parse_args()
    try:
        inspect(args.app.resolve(), args.require_distribution)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'ERROR: {error}\n')
