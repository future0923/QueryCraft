#!/usr/bin/env python3
"""Verify release pairing and feed selection metadata without macOS or signing keys."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('updates', ROOT / 'update-archives.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
S = '{' + MODULE.SPARKLE + '}'


class UpdateArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.notes = self.root / 'notes.md'
        self.notes.write_text('中文说明\nEnglish notes\n<keep> & preserve')
        for arch in MODULE.ARCHITECTURES:
            archive = self.root / f'QueryCraft-0.2.0-{arch}.tar.xz'
            archive.write_bytes(('archive ' + arch).encode())
            self.metadata(arch, dict(schemaVersion=2, version='0.2.0', build='30',
                minimumSystemVersion='15.0', architecture=arch, archive=archive.name,
                length=archive.stat().st_size, sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                edSignature=base64.b64encode(bytes(64)).decode()))

    def metadata(self, arch, changes):
        file = self.root / f'update-{arch}.json'
        value = json.loads(file.read_text()) if file.exists() else {}
        value.update(changes)
        file.write_text(json.dumps(value))

    def assemble(self, previous=None):
        MODULE.assemble(self.root, '0.2.0', self.notes, 'https://querycraft.test', previous)
        return self.root / 'appcast.xml'

    def test_arm64_precedes_intel_and_notes_survive_xml(self):
        feed = self.assemble()
        records = MODULE.validate_feed(self.root, feed, 'https://querycraft.test')
        self.assertEqual([record['architecture'] for record in records], ['arm64', 'x86_64'])
        items = ET.parse(feed).findall('./channel/item')
        self.assertEqual(items[0].findtext(S + 'hardwareRequirements'), 'arm64')
        self.assertIsNone(items[1].find(S + 'hardwareRequirements'))
        self.assertEqual(items[0].findtext('description'), self.notes.read_text())

    def test_missing_architecture_fails(self):
        (self.root / 'update-arm64.json').unlink()
        with self.assertRaises(FileNotFoundError): self.assemble()

    def test_digest_and_length_tampering_fail(self):
        for changes in [dict(sha256='wrong'), dict(length=1)]:
            with self.subTest(changes=changes):
                self.metadata('arm64', changes)
                with self.assertRaises(ValueError): self.assemble()

    def test_mixed_release_build_and_system_fail(self):
        for key in ('build', 'minimumSystemVersion'):
            self.metadata('arm64', {key:'31'})
            with self.assertRaises(ValueError): self.assemble()
            self.metadata('arm64', {key:'30' if key == 'build' else '15.0'})

    def test_legacy_artifact_and_wrong_architecture_fail(self):
        for changes in [dict(schemaVersion=1), dict(architecture='x86_64'), dict(archive='../escape.tar.xz')]:
            self.metadata('arm64', dict(schemaVersion=2, architecture='arm64', archive='QueryCraft-0.2.0-arm64.tar.xz'))
            self.metadata('arm64', changes)
            with self.assertRaises(ValueError): self.assemble()

    def test_public_feed_rejects_wrong_order_or_signature(self):
        feed = self.assemble()
        tree = ET.parse(feed)
        channel = tree.find('channel')
        items = channel.findall('item')
        channel.remove(items[0]); channel.append(items[0]); tree.write(feed)
        with self.assertRaises(ValueError): MODULE.validate_feed(self.root, feed, 'https://querycraft.test')
        feed = self.assemble()
        tree = ET.parse(feed)
        tree.find('./channel/item/enclosure').set(S + 'edSignature', 'wrong'); tree.write(feed)
        with self.assertRaises(ValueError): MODULE.validate_feed(self.root, feed, 'https://querycraft.test')

    def test_canonical_hashed_urls_and_both_architectures(self):
        feed = self.assemble()
        tree = ET.parse(feed)
        for arch, item in zip(MODULE.ARCHITECTURES, tree.findall('./channel/item')):
            item.find('enclosure').set('url', 'https://querycraft.test/releases/QueryCraft-0.2.0-30-' + arch + '-' + json.loads((self.root / f'update-{arch}.json').read_text())['sha256'][:16] + '.tar.xz')
        tree.write(feed)
        MODULE.validate_feed(self.root, feed, 'https://querycraft.test', canonical=True)
        tree.find('./channel/item/enclosure').set('url', 'https://attacker.test/archive.tar.xz'); tree.write(feed)
        with self.assertRaises(ValueError): MODULE.validate_feed(self.root, feed, 'https://querycraft.test', canonical=True)

    def test_history_preserved_without_duplicating_current_release(self):
        previous = self.assemble()
        tree = ET.parse(previous)
        old = ET.SubElement(tree.find('channel'), 'item')
        ET.SubElement(old, S + 'shortVersionString').text = '0.1.11'
        tree.write(previous)
        self.assemble(previous)
        items = ET.parse(previous).findall('./channel/item')
        self.assertEqual(len(items), 3)
        self.assertEqual(items[-1].findtext(S + 'shortVersionString'), '0.1.11')


if __name__ == '__main__': unittest.main()
