#!/usr/bin/env python3
"""Run PG mobile acceptance against an owned disposable server; never user connections."""
import argparse,json,shutil,subprocess,time,uuid
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('simulator');args=p.parse_args()
root=Path(__file__).resolve().parent.parent
docker=shutil.which('docker') or '/Applications/Docker.app/Contents/Resources/bin/docker'
name='qc-mobile-pg-'+uuid.uuid4().hex[:10];image='postgres:17'
subprocess.run([docker,'image','inspect',image],check=True,stdout=subprocess.DEVNULL)
try:
 subprocess.run([docker,'run','--detach','--rm','--name',name,'--publish','127.0.0.1::5432','--env','POSTGRES_PASSWORD=querycraft-proof-pg','--env','POSTGRES_DB=querycraft_ios_pg',image],check=True,stdout=subprocess.DEVNULL)
 info=json.loads(subprocess.check_output([docker,'inspect',name]))[0];port=info['NetworkSettings']['Ports']['5432/tcp'][0]['HostPort']
 command=[docker,'exec','-i',name,'psql','-U','postgres','-d','querycraft_ios_pg','-v','ON_ERROR_STOP=1']
 for _ in range(120):
  if subprocess.run(command+['-c','SELECT 1'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:break
  time.sleep(1)
 else:raise RuntimeError('Owned PostgreSQL did not become ready')
 subprocess.run(command,input=(root/'scripts/fixtures/mobile-postgresql.sql').read_bytes(),stdout=subprocess.DEVNULL,check=True)
 subprocess.run(['xcodegen','generate','--spec','QueryCraftMobile/project.yml'],cwd=root,check=True,stdout=subprocess.DEVNULL)
 suites=['MobilePostgreSQLTests','MobilePostgreSQLMutationTests','MobilePostgreSQLSessionTests','MobilePostgreSQLPresentationTests','MobilePostgreSQLParityTests','MobilePostgreSQLParityPresentationTests','MobilePostgreSQLStateTests','MobilePostgreSQLImportEngineTests','WorkspaceDataImportParserTests','WorkspaceDataImportStreamingTests','PostgreSQLSchemaEditingProviderTests','PostgreSQLCapabilitiesTests']
 call=['xcodebuildmcp','simulator','test','--project-path','QueryCraftMobile/QueryCraftMobile.xcodeproj','--scheme','QueryCraftMobileProof','--simulator-id',args.simulator,'--derived-data-path','.build/ios-driver-derived','--output','json','--json',json.dumps({'testRunnerEnv':{'PROOF_POSTGRES_PORT':port,'PROOF_DRIVER_PREVIEW_OUTPUT':str(root/'.build/ios-driver-previews')}}),'--extra-args']+['-only-testing:QueryCraftMobileProofTests/'+s for s in suites]
 output=root/'.build/ios-validation'/('pg-acceptance-'+args.simulator+'.json');output.parent.mkdir(parents=True,exist_ok=True)
 with output.open('w') as f: result=subprocess.run(call,cwd=root,stdout=f)
 report=json.loads(output.read_text());print(json.dumps(report.get('data',{}).get('summary',{})),flush=True)
 if result.returncode or report.get('didError') or report.get('data',{}).get('summary',{}).get('status')!='SUCCEEDED':raise RuntimeError('PG acceptance failed')
finally:subprocess.run([docker,'rm','--force','--volumes',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
