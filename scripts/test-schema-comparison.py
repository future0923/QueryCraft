#!/usr/bin/env python3
"""Compile the dynamic-framework smoke harness (XCTest statically links the API).

Requires a completed Debug build and an isolated, empty-password MySQL 8.4
fixture on localhost. Set DERIVED_DATA, QC_SCHEMA_TEST_PORT,
QC_SCHEMA_TEST_DRIVER and QC_SCHEMA_TEST_PREVIEW. This script never writes DBs.

Fixture (create with mysql --default-character-set=utf8mb4):
CREATE DATABASE qc_schema_source CHARACTER SET utf8mb4;
CREATE DATABASE qc_schema_target CHARACTER SET utf8mb4;
CREATE TABLE qc_schema_source.orders (id bigint NOT NULL PRIMARY KEY,
  created_at datetime DEFAULT NULL, note varchar(255) DEFAULT NULL COMMENT '买家备注',
  KEY idx_created_at (created_at));
CREATE TABLE qc_schema_target.orders (id bigint NOT NULL PRIMARY KEY,
  created_at datetime DEFAULT NULL);
CREATE TABLE qc_schema_source.users (id bigint NOT NULL PRIMARY KEY, email varchar(255) DEFAULT NULL);
CREATE TABLE qc_schema_target.users (id bigint NOT NULL PRIMARY KEY, email varchar(100) DEFAULT NULL);
CREATE TABLE qc_schema_target.legacy_events (id bigint NOT NULL PRIMARY KEY);
"""
from pathlib import Path
import os
import platform
import subprocess

root = Path(__file__).resolve().parent.parent
dd = Path(os.environ.get('DERIVED_DATA', root / '.build/DerivedData'))
products = dd / 'Build/Products/Debug'
frameworks = products / 'PackageFrameworks'
# Keep the executable beside SwiftPM resource bundles used by the SQL editor.
regression = os.environ.get('QC_SCHEMA_REGRESSION') == '1'
menu = os.environ.get('QC_SCHEMA_MENU') == '1'
binary = products / ('schema-comparison-menu' if menu else 'schema-comparison-regression' if regression else 'schema-comparison-smoke')
source = root / ('scripts/test-schema-comparison-regression.swift' if regression else 'scripts/test-schema-comparison.swift')
if os.environ.get('QC_SCHEMA_FULL_NATIVE') == '1':
    source = root / 'scripts/test-schema-comparison-full-native.swift'
    binary = products / 'schema-comparison-full-native'
if os.environ.get('QC_SCHEMA_DEMO_INSTALL') == '1':
    source = root / 'scripts/install-schema-comparison-demo.swift'
    binary = products / 'schema-comparison-demo-install'
if menu:
    app = (root / 'QueryCraft/QueryCraftApp.swift').read_text()
    commands = app[app.index('        .commands {'):app.rfind('\n    }')]
    source = dd / 'schema-comparison-menu-generated.swift'
    source.write_text((root / 'scripts/test-schema-comparison-menu.swift').read_text() + '''
@main struct MenuProbe: App {
    @NSApplicationDelegateAdaptor(MenuProbeDelegate.self) private var delegate
    private let softwareUpdateManager = ProbeUpdater()
    var body: some Scene {
        Settings { Text("Menu verification") }
''' + commands + '\n    }\n}\n')
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
args = [str(developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'),
        '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0',
        '-sdk', str(developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'),
        str(source), '-I', str(products),
        '-F', str(frameworks), '-framework', 'QueryCraftFeature', '-o', str(binary),
        '-Xlinker', '-rpath', '-Xlinker', str(frameworks)]
for name in ['TreeSitterJSON', 'TreeSitterSQL', 'TreeSitter', 'Internal']:
    args += ['-Xcc', '-fmodule-map-file=' + str(dd / f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap')]
args += ['-Xcc', '-fmodule-map-file=' + str(dd / 'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
for path in [root / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include',
             root / 'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include',
             dd / 'SourcePackages/checkouts/tree-sitter/lib/include',
             dd / 'SourcePackages/checkouts/TextStory/Sources/Internal',
             root / 'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
    args += ['-Xcc', '-I' + str(path)]
subprocess.run(args, check=True)
if regression:
    subprocess.run([str(developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'),
                    str(root / 'scripts/test-schema-comparison-accessibility.swift'),
                    '-o', str(products / 'schema-comparison-accessibility')], check=True)

if os.environ.get('QC_SCHEMA_COMPILE_ONLY') != '1':
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=os.environ.get('QC_SCHEMA_RUNTIME_FRAMEWORKS', str(frameworks)))
    subprocess.run([str(binary)], env=env, check=True, timeout=600)
