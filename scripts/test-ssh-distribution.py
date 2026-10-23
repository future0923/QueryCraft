#!/usr/bin/env python3
"""Regression checks for native SSH package identity and selected deployment inputs."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
def load(name, file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
CATALOG=load('ssh_catalog','package-ssh-catalog.py')
DEPLOY=load('deploy','deploy-components.py')

class SSHDistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)
        self.metadata=json.loads((ROOT/'Components/versions.json').read_text())['ssh']
    def package(self, transform=lambda entries:None):
        root='QueryCraftSSH.bundle/'
        entries={root+'Contents/Info.plist':plistlib.dumps(dict(CFBundleIdentifier='io.github.future0923.QueryCraft.SSH',QCSSHPluginABIVersion=1,CFBundleShortVersionString=self.metadata['version'],CFBundleVersion=self.metadata['build'])),
          root+'Contents/Resources/build.json':json.dumps(dict(architecture='x86_64',abi=1,local_crypto_override=False)).encode(),
          root+'Contents/Resources/component.json':json.dumps(dict(self.metadata,component='ssh',architectures=['x86_64'])).encode(),
          root+'Contents/MacOS/QueryCraftSSH':struct.pack('<II',0xfeedfacf,0x01000007),
          root+'Contents/_CodeSignature/CodeResources':b'fixture',root+'Contents/Resources/Licenses/libssh2.txt':b'license',root+'Contents/Resources/Licenses/OpenSSL.txt':b'license'}
        transform(entries)
        path=self.directory/'package.zip'
        with zipfile.ZipFile(path,'w') as archive:
            for name,data in entries.items():archive.writestr(name,data)
        return path
    def test_matching_metadata_and_native_cpu(self):
        CATALOG.inspect_package(self.package(),'x86_64',self.metadata)
    def test_wrong_native_architecture_rejected(self):
        path=self.package(lambda e:e.update({'QueryCraftSSH.bundle/Contents/MacOS/QueryCraftSSH':struct.pack('<II',0xfeedfacf,0x0100000c)}))
        with self.assertRaisesRegex(ValueError,'native architecture'):CATALOG.inspect_package(path,'x86_64',self.metadata)
    def test_metadata_drift_and_missing_descriptor_rejected(self):
        path=self.package()
        with self.assertRaisesRegex(ValueError,'compatibility'):CATALOG.inspect_package(path,'x86_64',dict(self.metadata,build='999'))
        path=self.package(lambda e:e.pop('QueryCraftSSH.bundle/Contents/Resources/component.json'))
        with self.assertRaises(KeyError):CATALOG.inspect_package(path,'x86_64',self.metadata)
    def test_local_crypto_and_escaping_paths_rejected(self):
        for transform in [lambda e:e.update({'QueryCraftSSH.bundle/Contents/Resources/build.json':json.dumps(dict(architecture='x86_64',abi=1,local_crypto_override=True))}),lambda e:e.update({'QueryCraftSSH.bundle/../outside':b'x'})]:
            with self.assertRaises(ValueError):CATALOG.inspect_package(self.package(transform),'x86_64',self.metadata)
    def test_symbolic_link_rejected(self):
        path=self.package()
        with zipfile.ZipFile(path,'a') as archive:
            link=zipfile.ZipInfo('QueryCraftSSH.bundle/link');link.create_system=3;link.external_attr=0o120777<<16;archive.writestr(link,'/tmp')
        with self.assertRaisesRegex(ValueError,'symbolic'):CATALOG.inspect_package(path,'x86_64',self.metadata)
    def records(self, architectures=('x86_64','arm64'), version=None):
        for arch in architectures:
            name=f'querycraft-ssh-fixture-{arch}.zip'
            archive=self.directory/name;archive.write_bytes(b'package')
            record=dict(self.metadata,component='ssh',architectures=[arch],url='https://querycraft.debug-tools.cc/components/'+name,size=7,sha256=hashlib.sha256(b'package').hexdigest())
            if version:record['version']=version
            archive.with_suffix('.release.json').write_text(json.dumps(dict(payload=base64.b64encode(json.dumps(record).encode()).decode(),signature=base64.b64encode(bytes(64)).decode())))
    def validate(self, **environment):
        with patch.dict(os.environ,dict(MCP_CHANGED='false',SKILL_CHANGED='false',SSH_CHANGED='true',**environment)),patch.object(sys,'argv',['deploy','--directory',str(self.directory),'--validate-only']),contextlib.redirect_stdout(io.StringIO()):DEPLOY.main()
    def test_complete_native_pair_selected_and_unselected_stale_packages_ignored(self):
        self.records();(self.directory/'querycraft-mcp-unselected.release.json').write_text('bad stale artifact');self.validate()
    def test_missing_architecture_and_stale_identity_rejected(self):
        self.records(['x86_64'])
        with self.assertRaisesRegex(ValueError,'architecture matrix'):self.validate()
        self.records(version='99.0.0')
        with self.assertRaisesRegex(ValueError,'source metadata'):self.validate()
    def test_tampered_archive_rejected(self):
        self.records();next(self.directory.glob('*.zip')).write_bytes(b'bad')
        with self.assertRaisesRegex(ValueError,'checksum'):self.validate()

if __name__=='__main__':unittest.main()
