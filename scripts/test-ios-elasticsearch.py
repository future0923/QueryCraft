#!/usr/bin/env python3
"""Run complete mobile ES acceptance against an owned, disposable local server."""
import argparse,json,os,shutil,subprocess,time,urllib.request,uuid
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('simulator');args=p.parse_args()
root=Path(__file__).resolve().parent.parent
docker=shutil.which('docker') or '/Applications/Docker.app/Contents/Resources/bin/docker'
image='docker.elastic.co/elasticsearch/elasticsearch:8.18.0';name='qc-mobile-es-'+uuid.uuid4().hex[:10]
subprocess.run([docker,'image','inspect',image],check=True,stdout=subprocess.DEVNULL)
try:
 subprocess.run([docker,'run','--detach','--rm','--name',name,'--publish','127.0.0.1::9200','--env','discovery.type=single-node','--env','xpack.security.enabled=false','--env','ES_JAVA_OPTS=-Xms512m -Xmx512m',image],check=True,stdout=subprocess.DEVNULL)
 info=json.loads(subprocess.check_output([docker,'inspect',name]))[0];port=info['NetworkSettings']['Ports']['9200/tcp'][0]['HostPort']
 for _ in range(120):
  try:
   with urllib.request.urlopen('http://127.0.0.1:'+port+'/',timeout=2) as r: json.load(r)
   break
  except Exception:time.sleep(1)
 else:raise RuntimeError('Owned Elasticsearch did not become ready')
 command=['xcodebuildmcp','simulator','test','--project-path','QueryCraftMobile/QueryCraftMobile.xcodeproj','--scheme','QueryCraftMobileProof','--simulator-id',args.simulator,'--derived-data-path','.build/ios-driver-derived','--output','json','--json',json.dumps({'testRunnerEnv':{'PROOF_ELASTICSEARCH_PORT':port,'PROOF_DRIVER_PREVIEW_OUTPUT':str(root/'.build/ios-driver-previews')}})]
 suites=['MobileElasticsearchTests','MobileElasticsearchStateTests','MobileElasticsearchPresentationTests','MobileGridFullscreenTests','ElasticsearchPaginationTests','ElasticsearchDocumentEditingTests','ElasticsearchDSLCompletionTests','ElasticsearchHTTPClientTests','ElasticsearchGETBodyTests','ElasticsearchMappingWriteTests','ElasticsearchMappingAndFilterTests','ElasticsearchReadOnlyRequestPolicyTests','ElasticsearchStreamingResponseTests']
 command+=['--extra-args']+['-only-testing:QueryCraftMobileProofTests/'+s for s in suites]
 output=root/'.build/ios-validation'/('es-acceptance-'+args.simulator+'.json');output.parent.mkdir(parents=True,exist_ok=True)
 with output.open('w') as f:result=subprocess.run(command,cwd=root,stdout=f)
 report=json.loads(output.read_text());print(json.dumps(report.get('data',{}).get('summary',{})),flush=True);print(output,flush=True)
 if result.returncode or report.get('didError') or report.get('data',{}).get('summary',{}).get('status')!='SUCCEEDED':raise RuntimeError('ES acceptance failed')
finally:
 subprocess.run([docker,'rm','--force','--volumes',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
