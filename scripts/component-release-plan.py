#!/usr/bin/env python3
"""Gate independent component/driver releases on actual relevant changes.

Version/build-only edits never count as implementation changes. Published
component tags provide independent baselines; --base provides an explicit baseline.
"""
import argparse, fnmatch, json, re, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
DRIVERS=['mysql','postgresql','doris','redis','elasticsearch','kafka']
DRIVER_NAMES={'mysql':'MySQL','postgresql':'PostgreSQL','doris':'Doris','redis':'Redis','elasticsearch':'Elasticsearch','kafka':'Kafka'}
def git(*args):return subprocess.check_output(['git',*args],cwd=ROOT,text=True,stderr=subprocess.DEVNULL).strip()
def read(ref,path):
    try:return git('show',ref+':'+path)
    except subprocess.CalledProcessError:return ''
def changes(base,head):return git('diff','--name-only',base,head).splitlines()
def meaningful(base,head,path):
    def normalize(text):
        return '\n'.join(line for line in text.splitlines() if not re.match(r'\s*(driver_version|driver_build)=',line))
    return normalize(read(base,path))!=normalize(read(head,path))
def component_paths(kind):
    if kind=='ssh':return ['QueryCraftSSHPlugin/**','QueryCraftSSHTerminalRenderer/**','ThirdPartyLicenses/SWIFTTERM-LICENSE.txt','ThirdParty/SwiftTerm/**','scripts/patch-swiftterm.py','QueryCraftPackage/Sources/CQueryCraftSSHPluginAPI/**','scripts/build-ssh-plugin.py','scripts/package-ssh-catalog.py']
    if kind=='skill':return ['Components/Skill/**','scripts/package-components.py']
    ssh_runtime = ['SSHAccountAccess','SSHConnection','SSHConnectionService','SSHDiagnostic','SSHFileRequest',
      'SSHPlugin','SSHPluginInstallation','SSHPluginManager','SSHRouteRequest','SSHTask','SSHTransfer','SSHTransferProgress']
    return [f'QueryCraftPackage/Sources/QueryCraftFeature/{name}.swift' for name in ssh_runtime] + [
      'QueryCraftPackage/Sources/QueryCraftFeature/ShellScript.swift','QueryCraftPackage/Sources/CQueryCraftSSHPluginAPI/**','QueryCraftMCPPackage/Sources/**','QueryCraftMCPPackage/Package.swift',
      'QueryCraftPackage/Sources/QueryCraftFeature/MCPHost*','QueryCraftPackage/Sources/QueryCraftFeature/MCPJSONValue*',
      'QueryCraftPackage/Sources/QueryCraftFeature/MCPRuntime*','QueryCraftPackage/Sources/QueryCraftFeature/MCPHTTP*',
      'QueryCraftPackage/Sources/QueryCraftFeature/MCPInitialization*','QueryCraftPackage/Sources/QueryCraftFeature/MCPPolicy*',
      'QueryCraftPackage/Sources/QueryCraftFeature/MCPSQL*','QueryCraftPackage/Sources/QueryCraftFeature/MCPRequest*',
      'QueryCraftPackage/Sources/QueryCraftFeature/MCPSchema*','QueryCraftPackage/Sources/QueryCraftFeature/MCPResult*',
      'QueryCraftPackage/Sources/QueryCraftFeature/MCPToolCatalog*','QueryCraftPackage/Sources/QueryCraftFeature/MCPHistory*',
      'QueryCraftPackage/Sources/QueryCraftFeature/MCPFailure*','QueryCraftPackage/Sources/QueryCraftFeature/MCPDesktopBridge*',
      'QueryCraftPackage/Sources/QueryCraftFeature/MCPCredential*','QueryCraftPackage/Sources/QueryCraftFeature/MCPInstallation*',
      'QueryCraftPackage/Sources/QueryCraftFeature/MCPComponent*','QueryCraftPackage/Sources/QueryCraftFeature/MCPSkillInstallation*',
      'QueryCraftPackage/Sources/QueryCraftFeature/QueryCraftMCPApplication*','QueryCraftPackage/Sources/QueryCraftMCPExecutable/**',
      'QueryCraftPackage/Sources/QueryCraftFeature/DatabaseDriver*.swift','QueryCraftPackage/Sources/QueryCraftFeature/SQLiteConnectionProfileRepository*',
      'QueryCraftPackage/Sources/QueryCraftFeature/SQL*.swift','QueryCraftPackage/Sources/QueryCraftFeature/ConnectionProfile.swift','QueryCraftPackage/Sources/QueryCraftFeature/KeychainCredentialStore.swift','QueryCraftPackage/Sources/QueryCraftFeature/WorkspaceCredentialHelperClient.swift','QueryCraftPackage/Sources/QueryCraftFeature/QueryCraftStorageLocation.swift',
      'QueryCraftPackage/Sources/QueryCraftFeature/SharedKeychainCredentialStore.swift',
      'QueryCraftPackage/Sources/QueryCraftFeature/Resources/**','QueryCraftPackage/Package.swift','MCPLauncher/**','CredentialHelper/**','scripts/package-mcp.py','scripts/package-components.py']
def plan(base,head,versions):
    paths=changes(base,head)
    components={}
    old=json.loads(read(base,'Components/versions.json') or '{}')
    for kind in versions:
        touched=[p for p in paths if any(fnmatch.fnmatch(p,pattern) for pattern in component_paths(kind))]
        before=dict(old.get(kind,{}));after=dict(versions[kind])
        for key in ['version','build']:before.pop(key,None);after.pop(key,None)
        if kind in old and before!=after:touched.append('Components/versions.json:'+kind+'.compatibility')
        identity_changed=old.get(kind)!=versions[kind]
        if identity_changed and not touched and kind in old:raise ValueError(f'{kind}: version/compatibility changed without implementation changes')
        components[kind]={'changed':bool(touched),'version':versions[kind]['version'],'build':versions[kind]['build'],'paths':touched}
    drivers={}
    # Match values, not regex Match object identities.
    def api(ref):
        match=re.search(r'querycraft_driver_api_version=(\d+)',read(ref,'scripts/driver-package-common.sh'))
        value=match.group(1) if match else None
        swift=re.search(r'currentDriverAPIVersion\s*=\s*(\d+)',read(ref,'QueryCraftPackage/Sources/QueryCraftFeature/DatabaseDriverPackage.swift'))
        if swift and swift.group(1)!=value:raise ValueError('Driver API differs between Swift and packaging scripts')
        return value
    api_changed=api(base)!=api(head)
    for driver in DRIVERS:
        script=f'scripts/package-{driver}-driver.sh';name=DRIVER_NAMES[driver]
        relevant=[p for p in paths if p.startswith(f'QueryCraftDrivers/Sources/QueryCraft{name}Driver/')
          or (driver in ['mysql','doris'] and (p.startswith('QueryCraftDrivers/MariaDBTransport/') or p.startswith('QueryCraftDrivers/Sources/CMariaDB/') or p.startswith('QueryCraftDrivers/Sources/QueryCraftMariaDBTransport/') or p=='scripts/build-mariadb-driver-library.sh'))
          or (p in [script,'scripts/driver-package-common.sh'] and meaningful(base,head,p))]
        def identity(ref):
            s=read(ref,script);return [re.search(rf'{key}="\$\{{[^:]+:-([^}}]+)\}}"',s).group(1) if re.search(rf'{key}="\$\{{[^:]+:-([^}}]+)\}}"',s) else None for key in ['driver_version','driver_build']]
        native={'mysql':['QueryCraftDrivers/Libs/libmariadb*','QueryCraftDrivers/Libs/libssl*','QueryCraftDrivers/Libs/libcrypto*'],
          'doris':['QueryCraftDrivers/Libs/libmariadb*','QueryCraftDrivers/Libs/libssl*','QueryCraftDrivers/Libs/libcrypto*'],
          'postgresql':['QueryCraftDrivers/Sources/CLibPQ/**','QueryCraftDrivers/Libs/libpq*','QueryCraftDrivers/Libs/libpg*','QueryCraftDrivers/Libs/libssl*','QueryCraftDrivers/Libs/libcrypto*','scripts/build-postgresql*'],
          'redis':['QueryCraftDrivers/Sources/CHiredis/**','QueryCraftDrivers/Libs/libhiredis*'],'kafka':['QueryCraftDrivers/Sources/CRdkafka/**','QueryCraftDrivers/Libs/librdkafka*','scripts/build-librdkafka*'],'elasticsearch':[]}
        relevant += [p for p in paths if any(fnmatch.fnmatch(p,pattern) for pattern in native[driver])]
        if 'QueryCraftDrivers/Package.swift' in paths:
            def target(ref):
                text=read(ref,'QueryCraftDrivers/Package.swift')
                match=re.search(r'\.target\(\s*name:\s*"QueryCraft'+name+r'Driver"',text)
                if not match:return ''
                rest=text[match.start():];end=re.search(r'\n\s*\.(target|testTarget|systemLibrary)\(',rest[1:])
                return rest[:end.start()+1] if end else rest
            if target(base)!=target(head):relevant.append('QueryCraftDrivers/Package.swift:'+driver)
        changed=api_changed or bool(relevant)
        if not changed and identity(base)!=identity(head):raise ValueError(f'{driver}: unchanged driver must not change version/build')
        shared_transport=driver in ['mysql','doris'] and any(p.startswith(('QueryCraftDrivers/MariaDBTransport/','QueryCraftDrivers/Sources/CMariaDB/','QueryCraftDrivers/Sources/QueryCraftMariaDBTransport/')) or p=='scripts/build-mariadb-driver-library.sh' for p in paths)
        together=DRIVERS if api_changed else ['mysql','doris'] if shared_transport else [driver]
        drivers[driver]={'changed':changed,'paths':relevant,'identity':identity(head),'requiredTogether':together}
    return {'components':components,'drivers':drivers}
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--base');p.add_argument('--head',default='HEAD');p.add_argument('--output',type=Path);p.add_argument('--github-output',type=Path);p.add_argument('--require-notes',action='store_true');args=p.parse_args()
    base=args.base
    if not base:
        tags=git('tag','--merged',args.head,'--sort=-version:refname').splitlines()
        base=next((t for t in tags if t.startswith('v') and git('rev-parse',t+'^{commit}')!=git('rev-parse',args.head+'^{commit}')),None) or git('hash-object','-w','-t','tree','/dev/null')
    versions=json.loads(read(args.head,'Components/versions.json') or (ROOT/'Components/versions.json').read_text());result=plan(base,args.head,versions)
    # Independent component tags take precedence over the last application tag.
    if not args.base:
        for kind in versions:
            tags=git('tag','--merged',args.head,'--sort=-version:refname',f'{kind}-v*').splitlines()
            previous=next((t for t in tags if git('rev-parse',t+'^{commit}')!=git('rev-parse',args.head+'^{commit}')),None)
            if previous:
                result['components'][kind]=plan(previous,args.head,versions)['components'][kind]
                published=json.loads(read(previous,'Components/versions.json'))[kind]
                if result['components'][kind]['changed'] and all(published[k]==versions[kind][k] for k in ['version','build']):
                    raise ValueError(f'{kind}: changed code needs a new release identity; published versions are immutable')
    if args.require_notes:
        for kind,item in result['components'].items():
            if not item['changed']:continue
            notes=ROOT/f"docs/releases/{kind}/{item['version']}.md"
            if not notes.is_file():raise ValueError(f'Missing release notes: {notes}')
            text=notes.read_text()
            if '中文' not in text or 'English' not in text:raise ValueError(f'Release notes must include Chinese and English: {notes}')
    encoded=json.dumps(result,ensure_ascii=False,indent=2)
    if args.output:args.output.write_text(encoded+'\n')
    if args.github_output:
        with args.github_output.open('a') as output:
            for kind,item in result['components'].items():output.write(f"{kind}_changed={str(item['changed']).lower()}\n")
            output.write('changed_drivers='+json.dumps([k for k,v in result['drivers'].items() if v['changed']])+'\n')
            output.write('driver_requirements='+json.dumps({k:v['requiredTogether'] for k,v in result['drivers'].items()})+'\n')
    print(encoded)
if __name__=='__main__':main()
