#!/usr/bin/env python3
"""Deterministic release-scope checks in disposable Git fixture repositories."""
import importlib.util, json, os, subprocess, tempfile, textwrap, unittest
from pathlib import Path
SPEC=importlib.util.spec_from_file_location('release_plan',Path(__file__).with_name('component-release-plan.py'))
PLAN=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(PLAN)

class ReleasePlanTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='qc-release-plan-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);PLAN.ROOT=self.root
        self.git('init','-q');self.git('config','user.email','fixture@example.invalid');self.git('config','user.name','Fixture')
        self.versions={'mcp':{'version':'0.1.0','build':'1'},'skill':{'version':'1.0.0','build':'1'},'ssh':{'version':'0.7.0','build':'7'}}
        self.write('Components/versions.json',json.dumps(self.versions))
        self.write('scripts/driver-package-common.sh','querycraft_driver_api_version=5\n')
        for driver in PLAN.DRIVERS:self.write(f'scripts/package-{driver}-driver.sh','driver_version="${DRIVER_VERSION:-1.0.0}"\ndriver_build="${DRIVER_BUILD:-1}"\nbuild_driver\n')
        self.commit();self.base=self.git('rev-parse','HEAD')
    def git(self,*args):return subprocess.check_output(['git',*args],cwd=self.root,stderr=subprocess.DEVNULL,text=True).strip()
    def write(self,name,text):
        path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text)
    def commit(self):self.git('add','.');self.git('commit','-qm','fixture')
    def result(self):self.commit();return PLAN.plan(self.base,'HEAD',self.versions)
    def test_settings_only_does_not_release_mcp_skill_or_drivers(self):
        self.write('QueryCraftPackage/Sources/QueryCraftFeature/MCPSettingsPane.swift','struct Settings {}')
        result=self.result();self.assertFalse(any(item['changed'] for item in result['components'].values()));self.assertFalse(any(item['changed'] for item in result['drivers'].values()))
    def test_runtime_change_selects_mcp_only(self):
        self.write('QueryCraftPackage/Sources/QueryCraftFeature/MCPHTTPListener.swift','actor Listener {}')
        result=self.result();self.assertTrue(result['components']['mcp']['changed']);self.assertFalse(result['components']['skill']['changed']);self.assertFalse(any(item['changed'] for item in result['drivers'].values()))
    def test_independent_protocol_package_selects_mcp_only(self):
        self.write('QueryCraftMCPPackage/Sources/QueryCraftMCPRuntime/MCPHTTPListener.swift','actor Listener {}')
        result=self.result();self.assertTrue(result['components']['mcp']['changed']);self.assertFalse(result['components']['skill']['changed']);self.assertFalse(any(item['changed'] for item in result['drivers'].values()))
    def test_protocol_test_only_does_not_release_mcp(self):
        self.write('QueryCraftMCPPackage/Tests/QueryCraftMCPTests/HandshakeTests.swift','struct Tests {}')
        result=self.result();self.assertFalse(result['components']['mcp']['changed'])
    def test_shared_credential_change_selects_mcp_only(self):
        self.write('QueryCraftPackage/Sources/QueryCraftFeature/SharedKeychainCredentialStore.swift','actor SharedCredentials {}')
        result=self.result();self.assertTrue(result['components']['mcp']['changed']);self.assertFalse(result['components']['skill']['changed']);self.assertFalse(any(item['changed'] for item in result['drivers'].values()))
    def test_skill_change_selects_skill_only(self):
        self.write('Components/Skill/querycraft/SKILL.md','Workflow instructions')
        result=self.result();self.assertTrue(result['components']['skill']['changed']);self.assertFalse(result['components']['mcp']['changed'])
    def test_ssh_native_change_only_selects_ssh(self):
        self.write('QueryCraftSSHPlugin/src/ssh_plugin.c','int plugin;')
        result=self.result();self.assertEqual([k for k,v in result['components'].items() if v['changed']],['ssh'])
        self.assertFalse(any(item['changed'] for item in result['drivers'].values()))
    def test_ssh_settings_only_does_not_select_components(self):
        self.write('QueryCraftPackage/Sources/QueryCraftFeature/SSHPluginSettingsSection.swift','struct View {}')
        self.assertFalse(any(v['changed'] for v in self.result()['components'].values()))
    def test_shell_store_change_selects_mcp_only(self):
        self.write('QueryCraftPackage/Sources/QueryCraftFeature/ShellScript.swift','struct Script {}')
        result=self.result();self.assertEqual([k for k,v in result['components'].items() if v['changed']],['mcp'])
        self.assertFalse(any(v['changed'] for v in result['drivers'].values()))
    def test_ssh_host_change_selects_mcp(self):
        self.write('QueryCraftPackage/Sources/QueryCraftFeature/SSHPlugin.swift','struct Host {}')
        result=self.result();self.assertEqual([k for k,v in result['components'].items() if v['changed']],['mcp'])
    def test_ssh_shared_header_change_selects_both(self):
        self.write('QueryCraftPackage/Sources/CQueryCraftSSHPluginAPI/include/QueryCraftSSHPlugin.h','void api(void);')
        result=self.result();self.assertEqual([k for k,v in result['components'].items() if v['changed']],['mcp','ssh'])
    def test_ssh_version_only_is_rejected(self):
        self.versions['ssh']['build']='8';self.write('Components/versions.json',json.dumps(self.versions))
        with self.assertRaisesRegex(ValueError,'without implementation changes'):self.result()
    def test_driver_version_only_is_rejected(self):
        path=self.root/'scripts/package-mysql-driver.sh';path.write_text(path.read_text().replace('1.0.0','1.0.1'))
        with self.assertRaisesRegex(ValueError,'unchanged driver'):self.result()
    def test_driver_build_only_is_rejected(self):
        path=self.root/'scripts/package-redis-driver.sh';path.write_text(path.read_text().replace('DRIVER_BUILD:-1','DRIVER_BUILD:-2'))
        with self.assertRaisesRegex(ValueError,'unchanged driver'):self.result()
    def test_one_driver_only_selects_that_driver(self):
        self.write('QueryCraftDrivers/Sources/QueryCraftRedisDriver/Client.swift','class Client {}')
        result=self.result();self.assertEqual([k for k,v in result['drivers'].items() if v['changed']],['redis'])
    def test_test_only_changes_do_not_publish_a_driver(self):
        self.write('QueryCraftDrivers/Tests/QueryCraftMySQLDriverTests/ClientTests.swift','struct Tests {}')
        result=self.result();self.assertFalse(any(item['changed'] for item in result['drivers'].values()))
    def test_api_mismatch_is_rejected(self):
        self.write('QueryCraftPackage/Sources/QueryCraftFeature/DatabaseDriverPackage.swift','static let currentDriverAPIVersion = 6')
        with self.assertRaisesRegex(ValueError,'Driver API differs'):self.result()
    def test_shared_transport_only_selects_mysql_and_doris(self):
        self.write('QueryCraftDrivers/MariaDBTransport/Sources/client.swift','public class Client {}')
        result=self.result();self.assertEqual([k for k,v in result['drivers'].items() if v['changed']],['mysql','doris'])
        self.assertEqual(result['drivers']['mysql']['requiredTogether'],['mysql','doris'])
        self.assertEqual(result['drivers']['doris']['requiredTogether'],['mysql','doris'])
    def test_driver_api_change_selects_all_six(self):
        self.write('scripts/driver-package-common.sh','querycraft_driver_api_version=6\n')
        result=self.result();self.assertEqual([k for k,v in result['drivers'].items() if v['changed']],PLAN.DRIVERS)
        self.assertTrue(all(item['requiredTogether']==PLAN.DRIVERS for item in result['drivers'].values()))
    def test_version_only_component_change_is_rejected(self):
        self.versions['skill']['version']='1.0.1';self.write('Components/versions.json',json.dumps(self.versions))
        with self.assertRaisesRegex(ValueError,'without implementation changes'):self.result()

class WorkflowSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='qc-workflow-selection-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);(self.root/'Config').mkdir();(self.root/'docs/releases').mkdir(parents=True)
        (self.root/'Config/Shared.xcconfig').write_text('MARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 1\n')
        (self.root/'docs/releases/1.0.0.md').write_text('fixture')
        self.bin=self.root/'bin';self.bin.mkdir()
        stub=self.bin/'git';stub.write_text('#!/bin/sh\nexit 0\n');stub.chmod(0o755)
        self.workflow=(Path(__file__).resolve().parent.parent/'.github/workflows/release.yml').read_text()
        self.environment=dict(os.environ,PATH=str(self.bin)+':'+os.environ.get('PATH',''),
            REQUESTED_PUBLISH_COMPONENTS='false',REQUESTED_PUBLISH='false',REQUESTED_SOURCE_RUN_ID='123',
            REQUESTED_PUBLISH_DRIVERS='true',REQUESTED_REBUILD_DRIVER='none',CHANGED_DRIVERS='["mysql","doris"]',
            DRIVER_REQUIREMENTS=json.dumps({d: ['mysql','doris'] if d in ['mysql','doris'] else [d] for d in PLAN.DRIVERS}),
            GITHUB_OUTPUT=str(self.root/'output'),GITHUB_REF_TYPE='branch',GITHUB_REF_NAME='main')
    def metadata(self,**environment):
        block=self.workflow.split('      - id: release\n',1)[1].split('\n      - id: artifacts',1)[0].split('\n  build_client:',1)[0]
        script=textwrap.dedent(block.split('        run: |\n',1)[1])
        return subprocess.run(['bash','-c',script],cwd=self.root,env=dict(self.environment,**environment),capture_output=True,text=True)
    def test_actual_changed_driver_matrix_and_shared_group_enforcement(self):
        result=self.metadata();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('driver_matrix=["mysql","doris"]',(self.root/'output').read_text())
        result=self.metadata(REQUESTED_REBUILD_DRIVER='mysql');self.assertNotEqual(result.returncode,0)
        self.assertIn('require related drivers together',result.stderr)
        result=self.metadata(REQUESTED_REBUILD_DRIVER='redis');self.assertNotEqual(result.returncode,0)
        self.assertIn('no relevant changes',result.stderr)
    def test_unchanged_drivers_cannot_be_published(self):
        result=self.metadata(CHANGED_DRIVERS='[]');self.assertNotEqual(result.returncode,0)
        self.assertIn('refusing to publish unchanged drivers',result.stderr)
    def test_reused_artifacts_upload_only_selected_driver(self):
        stub=self.bin/'gh';stub.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$QC_GH_LOG"\n');stub.chmod(0o755)
        dist=self.root/'dist';dist.mkdir()
        for driver in PLAN.DRIVERS:
            for arch in ['x86_64','arm64']:
                (dist/f'{driver}-{arch}.json').write_text('{}')
                (dist/f'{driver}-driver-1.0.0-{arch}.zip').write_bytes(b'fixture')
        block=self.workflow.split('      - name: Update GitHub driver assets\n',1)[1]
        script=textwrap.dedent(block.split('        run: |\n',1)[1])
        result=subprocess.run(['bash','-c',script],cwd=self.root,env=dict(self.environment,RELEASE_TAG='v1.0.0',SELECTED_DRIVERS='["redis"]',QC_GH_LOG=str(self.root/'gh.log')),capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        calls=(self.root/'gh.log').read_text();self.assertIn('redis-driver-',calls)
        for driver in set(PLAN.DRIVERS)-{'redis'}:self.assertNotIn(driver+'-',calls)

if __name__=='__main__':unittest.main()
