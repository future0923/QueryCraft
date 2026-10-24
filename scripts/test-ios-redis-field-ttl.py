import subprocess,json,sys,time
from pathlib import Path
root=Path(__file__).resolve().parent.parent; docker='/Applications/Docker.app/Contents/Resources/bin/docker'; name='querycraft-field-ttl-proof-'+str(__import__('os').getpid())
try:
 (root/'.build/ios-validation').mkdir(parents=True,exist_ok=True)
 subprocess.run(['xcodegen','generate','--spec','QueryCraftMobile/project.yml'],cwd=root,check=True)
 subprocess.run([docker,'run','-d','--name',name,'-p','127.0.0.1::6379','redis:7.4.2','redis-server','--save','','--appendonly','no'],check=True,stdout=subprocess.DEVNULL)
 port=subprocess.check_output([docker,'port',name,'6379/tcp'],text=True).strip().split(':')[-1]
 for _ in range(40):
  if 'PONG' in subprocess.run([docker,'exec',name,'redis-cli','PING'],text=True,capture_output=True).stdout:break
  time.sleep(.1)
 report=root/'.build/ios-validation'/('redis-field-'+sys.argv[1]+'.json')
 with report.open('w') as out:
  result=subprocess.run(['xcodebuildmcp','simulator','test','--project-path','QueryCraftMobile/QueryCraftMobile.xcodeproj','--scheme','QueryCraftMobileProof','--simulator-id',sys.argv[1],'--derived-data-path','.build/ios-driver-derived','--json',json.dumps({'testRunnerEnv':{'PROOF_REDIS_PORT':port,'PROOF_REDIS_FIELD_TTL':'1','PROOF_DRIVER_PREVIEW_OUTPUT':str(root/'.build/ios-driver-previews')}}),'--extra-args','-only-testing:QueryCraftMobileProofTests/MobileRedisFieldTTLTests','-only-testing:QueryCraftMobileProofTests/MobileRedisPagingTests', '-only-testing:QueryCraftMobileProofTests/MobileRedisSearchTests','-only-testing:QueryCraftMobileProofTests/MobileRedisSearchStateTests','-only-testing:QueryCraftMobileProofTests/MobileRedisConsoleTests','-only-testing:QueryCraftMobileProofTests/MobileRedisMutationTests','-only-testing:QueryCraftMobileProofTests/MobileRedisPresentationTests','-only-testing:QueryCraftMobileProofTests/MobileRedisEditorStateTests','-only-testing:QueryCraftMobileProofTests/MobileRedisKeyActionTests','-only-testing:QueryCraftMobileProofTests/MobileRedisKeyActionStateTests','--output','json'],cwd=root,stdout=out)
 data=json.loads(report.read_text());print(data['data']['summary']);print(data['data'].get('diagnostics'))
 if result.returncode or data.get('didError'):raise RuntimeError('Field TTL tests failed')
finally:subprocess.run([docker,'rm','-f',name],stdout=subprocess.DEVNULL)
