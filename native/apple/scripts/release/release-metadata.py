#!/usr/bin/env python3
"""Validate local release artifacts and update public metadata without publishing."""
import datetime
import hashlib
import json
import plistlib
import re
import shlex
import sys
import zipfile
from pathlib import Path


# OpenStream plays media the user owns; public text never mentions add-ons (scripts/check-appstore-compliance.sh).
ADDON_WORDS = re.compile(r'stremio|strem[.]io|torrent|debrid|premiumize|torbox|magnet:|infohash|cinemeta|metahub|add-?on|manifest[.]json', re.I)


def require_no_addon_words(text, label):
    if ADDON_WORDS.search(text):
        raise SystemExit(f'FAIL: {label} mentions add-ons; say what OpenStream plays (media you own)')


def notes(checkout, version, build):
    changelog = (checkout / 'CHANGELOG.md').read_text()
    match = re.search(r'^## \[' + re.escape(f'{version} ({build})') + r'\][^\n]*\n(.*?)(?=^## |\Z)', changelog, re.M | re.S)
    if not match:
        raise SystemExit('FAIL: matching CHANGELOG version/build section is missing')
    text = re.split(r'^\[[^\n]+\]:', match.group(1), maxsplit=1, flags=re.M)[0].strip() + '\n'
    require_no_addon_words(text, f'CHANGELOG {version} ({build})')
    return text


def verify_info(info, version, build, label):
    if info.get('CFBundleShortVersionString') != version or info.get('CFBundleVersion') != build:
        raise SystemExit(f'FAIL: {label} has incorrect version/build')


def verify_app(app, version, build):
    found = 0
    for path in app.rglob('Info.plist'):
        if path.parent.suffix not in {'.app', '.appex'} and path.parent.name != 'Contents':
            continue
        # Framework versions are independent of the app's version.
        if any(part.endswith('.framework') for part in path.relative_to(app).parts):
            continue
        verify_info(plistlib.loads(path.read_bytes()), version, build, path.parent.name)
        found += 1
    if not found:
        raise SystemExit('FAIL: app Info.plist was not found')


def verify_zip(path, version, build, platform):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip():
            raise SystemExit('FAIL: corrupt release ZIP/IPA')
        names = archive.namelist()
        if any(n.startswith('/') or '..' in Path(n).parts for n in names):
            raise SystemExit('FAIL: unsafe archive member')
        main = f'Payload/OpenStream {platform}.app/Info.plist' if platform != 'macOS' else 'oStream.app/Contents/Info.plist'
        if main not in names:
            raise SystemExit('FAIL: archive app layout is incorrect')
        if platform != 'macOS' and any('_CodeSignature' in Path(n).parts or n.endswith('.mobileprovision') for n in names):
            raise SystemExit('FAIL: signed material remains in sideload IPA')
        verify_info(plistlib.loads(archive.read(main)), version, build, platform)
        for n in names:
            if n.endswith('/Info.plist') and (Path(n).parent.suffix in {'.app', '.appex'}) and '.framework/' not in n:
                verify_info(plistlib.loads(archive.read(n)), version, build, Path(n).parent.name)


mode = sys.argv[1]
if mode == 'fingerprint':
    root = Path(sys.argv[2])
    digest = hashlib.sha256()
    for p in sorted(root.rglob('*')):
        if p.is_file():
            relative = p.relative_to(root)
            # Tests and release utilities do not enter the application binary.
            if relative.parts[0] not in {'Sources', 'Apps'} and str(relative) not in {'Package.swift', 'Package.resolved'}:
                continue
            digest.update(str(relative).encode() + b'\0')
            digest.update(p.read_bytes())
    print(digest.hexdigest())
elif mode == 'verify-app':
    verify_app(Path(sys.argv[2]), sys.argv[3], sys.argv[4])
else:
    checkout, release = map(Path, sys.argv[2:4])
    version, build = sys.argv[4:6]
    tag = f'v{version}-{build}'
    assets = [release / f'{"oStream" if platform == "macOS" else "OpenStream"}-{platform}-{version}-{build}.{suffix}' for platform, suffix in [('iOS', 'ipa'), ('tvOS', 'ipa'), ('visionOS', 'ipa'), ('macOS', 'zip')]]
    if mode == 'notes':
        (release / 'notes.md').write_text(notes(checkout, version, build))
    elif mode == 'finish':
        sums = []
        for asset, platform in zip(assets, ['iOS', 'tvOS', 'visionOS', 'macOS']):
            verify_zip(asset, version, build, platform)
            digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            sums.append(f'{digest}  {asset.name}')
            print(f'{asset.name}: {asset.stat().st_size} bytes; SHA256 {digest}')
        (release / 'SHA256SUMS.txt').write_text('\n'.join(sums) + '\n')
        feed_path = checkout / 'altstore-source.json'
        feed = json.loads(feed_path.read_text())
        app = next(a for a in feed['apps'] if a['bundleIdentifier'] == 'com.orgista.openstream')
        entry = {'version': version, 'buildVersion': build, 'date': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
                 'localizedDescription': notes(checkout, version, build),
                 'downloadURL': f'https://github.com/orgista/openstream-apple/releases/download/{tag}/{assets[0].name}',
                 'size': assets[0].stat().st_size, 'minOSVersion': '18.0'}
        app['versions'] = [entry] + [v for v in app['versions'] if (v['version'], v.get('buildVersion')) != (version, build)]
        # Unsigned payloads declare no original signing entitlements. Privacy
        # usage strings are read from every actual app/extension in the IPA.
        privacy = {}
        with zipfile.ZipFile(assets[0]) as ipa:
            for name in ipa.namelist():
                if name.endswith('/Info.plist') and '.framework/' not in name:
                    info = plistlib.loads(ipa.read(name))
                    privacy.update({k: v for k, v in info.items() if k.startswith('NS') and k.endswith('UsageDescription')})
        app['appPermissions'] = {'entitlements': [], 'privacy': privacy}
        feed_path.write_text(json.dumps(feed, indent=2) + '\n')
        readme = checkout / 'README.md'
        text = readme.read_text()
        require_no_addon_words(text, 'public README.md')
        text = re.sub(r'https://img[.]shields[.]io/(?:github/v/release/orgista/openstream-apple|badge/release-[^)]*)',
                      f'https://img.shields.io/badge/release-{version}%20%28{build}%29-FF3366', text, count=1)
        readme.write_text(text)
    elif mode == 'commands':
        commands = [shlex.join(['git', '-C', str(checkout), 'push']),
                    shlex.join(['gh', 'release', 'create', tag, '-R', 'orgista/openstream-apple', '--title', f'OpenStream {version} ({build})', '-F', str(release / 'notes.md'), *map(str, assets), str(release / 'SHA256SUMS.txt')])]
        (release / 'publish-commands.txt').write_text('\n'.join(commands) + '\n')
        print('\n'.join(commands))
    else:
        raise SystemExit('FAIL: unknown release metadata action')
