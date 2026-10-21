#!/usr/bin/env python3
"""Package single-architecture Sparkle updates and assemble the shared legacy feed."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)
ARCHITECTURES = ('arm64', 'x86_64')  # Equal versions select the first supported item.


def run(*args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs).strip()


def archive_metadata(directory, architecture):
    metadata = json.loads((directory / f'update-{architecture}.json').read_text())
    if metadata['architecture'] != architecture or metadata.get('schemaVersion') != 2:
        raise ValueError('Incompatible update artifact schema/architecture')
    name = f"QueryCraft-{metadata['version']}-{architecture}.tar.xz"
    if metadata['archive'] != name or not re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z._-]*', metadata['version']):
        raise ValueError('Invalid update archive name')
    archive = directory / name
    if (archive.stat().st_size != metadata['length'] or
            hashlib.sha256(archive.read_bytes()).hexdigest() != metadata['sha256']):
        raise ValueError('Update archive size/digest mismatch')
    if (not re.fullmatch(r'[0-9]+', metadata['build']) or
            len(base64.b64decode(metadata['edSignature'], validate=True)) != 64):
        raise ValueError('Incomplete update identity/signature')
    return metadata


def validate_feed(directory, feed_path, base_url, canonical=False):
    if not base_url.startswith('https://'):
        raise ValueError('Update download URLs must use HTTPS')
    records = [archive_metadata(directory, arch) for arch in ARCHITECTURES]
    if any(any(record[key] != records[0][key] for key in
               ('version', 'build', 'minimumSystemVersion')) for record in records):
        raise ValueError('Mixed architecture release identities')
    items = [item for item in ET.parse(feed_path).findall('./channel/item')
             if item.findtext(f'{{{SPARKLE}}}shortVersionString') == records[0]['version']]
    if len(items) != 2:
        raise ValueError('The current release must contain exactly two ordered architecture items')
    for item, record in zip(items, records):
        required = item.findtext(f'{{{SPARKLE}}}hardwareRequirements', '')
        enclosure = item.find('enclosure')
        expected_url = base_url.rstrip('/') + '/releases/' + record['archive']
        actual_url = enclosure.get('url', '')
        if canonical:
            # The server stores immutable version/build/architecture/hash names.
            prefix = f"{base_url.rstrip('/')}/releases/QueryCraft-{record['version']}-{record['build']}-{record['architecture']}-"
            valid_url = actual_url == prefix + record['sha256'][:16] + '.tar.xz'
        else:
            valid_url = actual_url == expected_url
        if (required != ('arm64' if record['architecture'] == 'arm64' else '') or
                item.findtext(f'{{{SPARKLE}}}version') != record['build'] or
                item.findtext(f'{{{SPARKLE}}}minimumSystemVersion') != record['minimumSystemVersion'] or
                enclosure.get('length') != str(record['length']) or
                enclosure.get(f'{{{SPARKLE}}}edSignature') != record['edSignature'] or not valid_url):
            raise ValueError('Architecture feed order/identity/signature/download metadata mismatch')
    return records


def package(app, architecture, directory, sign_tool):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if app.name != 'QueryCraft.app':
        raise ValueError('Update root must be named QueryCraft.app')
    if info['CFBundleIdentifier'] != 'io.github.future0923.QueryCraft':
        raise ValueError('Only the production application identity may be packaged')
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z._-]*', version):
        raise ValueError('Invalid version')
    for binary in (app / 'Contents/MacOS/QueryCraft',
                   app / 'Contents/Frameworks/QueryCraftFeature.framework/Versions/A/QueryCraftFeature'):
        if run('lipo', '-archs', binary).split() != [architecture]:
            raise ValueError(f'Update must contain exactly {architecture}: {binary}')
    run('codesign', '--verify', '--deep', '--strict', app, stderr=subprocess.STDOUT)
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / f'QueryCraft-{version}-{architecture}.tar.xz'
    # bsdtar preserves framework links/modes without resource-fork sidecars.
    run('/usr/bin/tar', '--no-xattrs', '-cJf', archive, '-C', app.parent, app.name,
        env=dict(os.environ, COPYFILE_DISABLE='1'))
    key = os.environ.get('SPARKLE_PRIVATE_KEY')
    options = ['--ed-key-file', '-'] if key else ['--account', 'io.github.future0923.QueryCraft']
    signature = run(sign_tool, *options, '-p', archive, input=key).strip()
    run(sign_tool, *options, '--verify', archive, signature, input=key)
    metadata = dict(schemaVersion=2, version=version, build=build,
                    minimumSystemVersion=info['LSMinimumSystemVersion'], architecture=architecture,
                    archive=archive.name, length=archive.stat().st_size,
                    sha256=hashlib.sha256(archive.read_bytes()).hexdigest(), edSignature=signature)
    (directory / f'update-{architecture}.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(metadata, indent=2))


def assemble(directory, version, notes, base_url, previous=None):
    if not base_url.startswith('https://'):
        raise ValueError('Update download URLs must use HTTPS')
    records = [archive_metadata(directory, arch) for arch in ARCHITECTURES]
    if any(record['version'] != version or any(record[key] != records[0][key]
           for key in ('build', 'minimumSystemVersion')) for record in records):
        raise ValueError('Architecture updates belong to different releases')
    feed = ET.Element('rss', version='2.0')
    channel = ET.SubElement(feed, 'channel')
    for tag, value in [('title', 'QueryCraft'), ('description', 'QueryCraft software updates.'), ('language', 'en')]:
        ET.SubElement(channel, tag).text = value
    for record in records:
        item = ET.SubElement(channel, 'item')
        for tag, value in [('title', version), ('pubDate', format_datetime(datetime.now(timezone.utc))),
                           (f'{{{SPARKLE}}}version', record['build']),
                           (f'{{{SPARKLE}}}shortVersionString', version),
                           (f'{{{SPARKLE}}}minimumSystemVersion', record['minimumSystemVersion'])]:
            ET.SubElement(item, tag).text = value
        if record['architecture'] == 'arm64':
            ET.SubElement(item, f'{{{SPARKLE}}}hardwareRequirements').text = 'arm64'
        ET.SubElement(item, 'enclosure', {'url': base_url.rstrip('/') + '/releases/' + record['archive'],
                      'length': str(record['length']), 'type': 'application/octet-stream',
                      f'{{{SPARKLE}}}edSignature': record['edSignature']})
        ET.SubElement(item, 'description', {f'{{{SPARKLE}}}format': 'markdown'}).text = notes.read_text()
    if previous and previous.exists():
        for item in ET.parse(previous).findall('./channel/item'):
            if item.findtext(f'{{{SPARKLE}}}shortVersionString') != version:
                channel.append(item)
    ET.indent(feed)
    ET.ElementTree(feed).write(directory / 'appcast.xml', encoding='utf-8', xml_declaration=True)
    (directory / 'release-notes.md').write_bytes(notes.read_bytes())
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    pack = commands.add_parser('package')
    pack.add_argument('--app', type=Path, required=True)
    pack.add_argument('--architecture', choices=ARCHITECTURES, required=True)
    pack.add_argument('--directory', type=Path, required=True)
    pack.add_argument('--sign-tool', type=Path, required=True)
    merge = commands.add_parser('assemble')
    merge.add_argument('--directory', type=Path, required=True)
    merge.add_argument('--version', required=True)
    merge.add_argument('--notes', type=Path, required=True)
    merge.add_argument('--base-url', default='https://querycraft.debug-tools.cc')
    merge.add_argument('--previous', type=Path)
    validate = commands.add_parser('validate')
    validate.add_argument('--directory', type=Path, required=True)
    validate.add_argument('--feed', type=Path, required=True)
    validate.add_argument('--base-url', default='https://querycraft.debug-tools.cc')
    validate.add_argument('--canonical', action='store_true')
    args = parser.parse_args()
    if args.command == 'package':
        package(args.app.resolve(), args.architecture, args.directory.resolve(), args.sign_tool.resolve())
    elif args.command == 'assemble':
        assemble(args.directory, args.version, args.notes, args.base_url, args.previous)
    else:
        validate_feed(args.directory, args.feed, args.base_url, args.canonical)


if __name__ == '__main__':
    main()
