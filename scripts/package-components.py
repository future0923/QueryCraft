#!/usr/bin/env python3
"""Build independent component artifacts and CI-signed immutable release records.

No upload, host embedding or personal installation is performed.
"""
import argparse, base64, hashlib, json, os, shutil, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent

def sign(package, tool, key_file=None):
    args = [str(tool), '--account', 'io.github.future0923.QueryCraft', '-p', str(package), '--disable-signing-warning']
    if key_file: args += ['--ed-key-file', str(key_file)]
    secret = os.environ.get('SPARKLE_PRIVATE_KEY')
    if secret and not key_file: args += ['--ed-key-file', '-']
    signature = subprocess.check_output(args, input=secret.encode() if secret and not key_file else None).strip()
    if len(base64.b64decode(signature, validate=True)) != 64: raise ValueError('Signing tool did not return an Ed25519 signature')
    result = package.with_name(package.name.replace('.package.json', '.release.json'))
    result.write_text(json.dumps({'payload': base64.b64encode(package.read_bytes()).decode(), 'signature': signature.decode()}, indent=2)+'\n')
    return result

def skill(output):
    metadata = json.loads((ROOT/'Components/versions.json').read_text())['skill']
    descriptor = dict(metadata, component='skill', architectures=['any'])
    archive = output / f"querycraft-skill-{metadata['version']}-{metadata['build']}.zip"
    with tempfile.TemporaryDirectory(prefix='qc-skill-package-') as temp:
        root=Path(temp)/'QueryCraftSkill';root.mkdir()
        shutil.copytree(ROOT/'Components/Skill/querycraft',root/'querycraft')
        (root/'component.json').write_text(json.dumps(descriptor,sort_keys=True))
        subprocess.run(['ditto','-c','-k','--norsrc','--noextattr','--keepParent',str(root),str(archive)],check=True)
    base=os.environ.get('QUERYCRAFT_COMPONENT_DOWNLOAD_BASE_URL','https://querycraft.debug-tools.cc/components').rstrip('/')
    release=dict(descriptor,sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),size=archive.stat().st_size,url=base+'/'+archive.name)
    package=archive.with_suffix('.package.json');package.write_text(json.dumps(release,indent=2)+'\n')
    return package

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--component',choices=['mcp','skill','all'],default='all')
    p.add_argument('--build-dir',type=Path)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--architecture',choices=['arm64','x86_64'])
    p.add_argument('--development',action='store_true')
    p.add_argument('--sign-existing',action='store_true',help='Sign existing .package.json records without rebuilding')
    p.add_argument('--unsigned',action='store_true',help='Local test fixtures only; cannot be uploaded to the server')
    p.add_argument('--sign-tool',type=Path)
    p.add_argument('--key-file',type=Path)
    args=p.parse_args();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
    packages=[]
    if args.sign_existing:
        packages=list(args.output.glob(('querycraft-*' if args.component=='all' else 'querycraft-'+args.component+'-*')+'.package.json'))
        if not packages:raise ValueError('No component records found to sign')
    elif args.component in ('mcp','all'):
        if not args.build_dir:p.error('--build-dir is required for MCP')
        command=['python3',str(ROOT/'scripts/package-mcp.py'),'--build-dir',str(args.build_dir),'--output',str(args.output/'QueryCraft MCP.app')]
        if args.architecture:command+=['--architecture',args.architecture]
        if args.development:command+=['--development']
        subprocess.run(command,check=True)
        packages+=list(args.output.glob('querycraft-mcp-*.package.json'))
    if not args.sign_existing and args.component in ('skill','all'):packages.append(skill(args.output))
    if not args.unsigned:
        tool=args.sign_tool or ROOT/'.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update'
        for package in packages:print(sign(package,tool,args.key_file))

if __name__=='__main__':main()
