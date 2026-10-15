#!/usr/bin/env python3
"""Publish only changed independent components through the resource deployment API.

Release records and ZIPs are immutable; GitHub retries accept identical assets only.
"""
import argparse, base64, hashlib, json, os, subprocess, tempfile
from pathlib import Path
from urllib.parse import urlparse
ROOT=Path(__file__).resolve().parent.parent

def digest(path):
    result=hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda:source.read(1024*1024),b''):result.update(block)
    return result.hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--directory',type=Path,required=True);parser.add_argument('--github',action='store_true');parser.add_argument('--validate-only',action='store_true');args=parser.parse_args()
    selected=[kind for kind in ['mcp','skill'] if os.environ.get(kind.upper()+'_CHANGED')=='true']
    records={}
    for kind in selected:
        entries=[]
        for record in args.directory.glob(f'querycraft-{kind}-*.release.json'):
            envelope=json.loads(record.read_text());release=json.loads(base64.b64decode(envelope['payload'],validate=True))
            if release['component']!=kind or len(base64.b64decode(envelope['signature'],validate=True))!=64:raise ValueError('Invalid component release record')
            name=Path(urlparse(release['url']).path).name;archive=args.directory/name
            if archive.stat().st_size!=release['size'] or digest(archive)!=release['sha256']:raise ValueError('Component artifact checksum mismatch')
            notes=ROOT/f"docs/releases/{kind}/{release['version']}.md"
            if not notes.is_file():raise ValueError('Component release notes are missing')
            entries.append((record,release,archive,notes))
        expected={'x86_64','arm64'} if kind=='mcp' else {'any'}
        if {r[1]['architectures'][0] for r in entries}!=expected or len(entries)!=len(expected):raise ValueError(f'Incomplete {kind} architecture matrix')
        if len({(r[1]['version'],r[1]['build']) for r in entries})!=1:raise ValueError('Component architecture versions disagree')
        records[kind]=entries
    if args.validate_only or not selected:
        print('Validated component selection: '+(', '.join(selected) or 'none'));return
    endpoint=os.environ.get('QUERYCRAFT_RESOURCE_DEPLOY_URL','https://querycraft.debug-tools.cc/admin/resources/deploy').rstrip('/')
    token=os.environ.get('QUERYCRAFT_RESOURCE_DEPLOY_TOKEN','')
    if urlparse(endpoint).scheme!='https' or not token:raise ValueError('HTTPS deployment endpoint and deployment token are required')
    for kind,entries in records.items():
        for record,release,archive,notes in entries:
            result=subprocess.run(['curl','--fail-with-body','--silent','--show-error','--header','@-',
                # Existing production proxies already allow large uploads here.
                # The server dispatches to the same authenticated component handler.
                '--form',f'manifest=@{record}','--form',f'archive=@{archive}','--form',f'release_notes=<{notes}',endpoint+'/drivers?component='+kind],
                input=('Authorization: Bearer '+token+'\n').encode(),capture_output=True)
            if result.returncode:raise RuntimeError(f'{kind} deployment failed (curl {result.returncode}); previously published artifacts were preserved')
        if args.github:
            _,release,_,notes=entries[0];tag=f"{kind}-v{release['version']}+{release['build']}"
            exists=subprocess.run(['gh','release','view',tag],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
            if not exists:subprocess.run(['gh','release','create',tag,'--target',os.environ['GITHUB_SHA'],'--title',f"QueryCraft {kind.upper()} {release['version']}",'--notes-file',str(notes)],check=True)
            assets=json.loads(subprocess.check_output(['gh','release','view',tag,'--json','assets']))['assets'];names={a['name'] for a in assets}
            for record,_,archive,_ in entries:
                for file in [record,archive]:
                    if file.name in names:
                        with tempfile.TemporaryDirectory(prefix='qc-release-retry-') as temp:
                            subprocess.run(['gh','release','download',tag,'--pattern',file.name,'--dir',temp],check=True)
                            if digest(Path(temp)/file.name)!=digest(file):raise ValueError('Refusing to replace an existing component release asset')
                    else:subprocess.run(['gh','release','upload',tag,str(file)],check=True)
        print('Published '+kind+' component; unchanged components were untouched')

if __name__=='__main__':main()
