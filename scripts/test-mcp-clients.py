#!/usr/bin/env python3
"""Check generated configurations with available real client CLIs without modifying user configuration."""
import argparse,importlib.util,json,os,shutil,socket,subprocess,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('protocol',ROOT/'scripts/test-mcp-protocol.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
a=argparse.ArgumentParser(description=__doc__);a.add_argument('templates',type=Path);args=a.parse_args()
with tempfile.TemporaryDirectory(prefix='qc-mcp-clients-') as temp:
 root=Path(temp);data=root/'Data';data.mkdir();(data/'mcp-policy.json').write_text(json.dumps(m.policy(5231)))
 claude=shutil.which('claude')
 if claude:
  config=json.loads((args.templates/'Claude Code-stdio.txt').read_text());config['mcpServers']['querycraft']['args']=['--stdio','--data-dir',str(data)]
  (root/'.mcp.json').write_text(json.dumps(config))
  result=subprocess.run([claude,'mcp','list'],cwd=root,env=dict(os.environ,CLAUDE_CONFIG_DIR=str(root/'Claude')),text=True,capture_output=True,timeout=60)
  assert result.returncode==0 and 'querycraft' in result.stdout and 'Connected' in result.stdout,result.stdout+result.stderr
  print('PASS Claude Code actual stdio configuration import and MCP connected health check')
  with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
  policy=m.policy(port);(data/'mcp-policy.json').write_text(json.dumps(policy))
  server=subprocess.Popen([config['mcpServers']['querycraft']['command'],'--http','--data-dir',str(data)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  try:
   for _ in range(100):
    try:
     with socket.create_connection(('127.0.0.1',port),timeout=.2):break
    except OSError:time.sleep(.1)
   else:raise AssertionError('HTTP process did not become ready')
   http=json.loads((args.templates/'Claude Code-http.txt').read_text())
   http['mcpServers']['querycraft']['url']=f'http://127.0.0.1:{port}/mcp'
   http['mcpServers']['querycraft']['headers']['Authorization']='Bearer '+policy['http']['token']
   (root/'.mcp.json').write_text(json.dumps(http))
   result=subprocess.run([claude,'mcp','list'],cwd=root,env=dict(os.environ,CLAUDE_CONFIG_DIR=str(root/'Claude')),text=True,capture_output=True,timeout=60)
   assert result.returncode==0 and 'querycraft' in result.stdout and 'Connected' in result.stdout,'Claude Code HTTP health check failed'
   print('PASS Claude Code actual authenticated Streamable HTTP connection')
  finally:
   server.terminate()
   try:server.wait(timeout=5)
   except subprocess.TimeoutExpired:server.kill();server.wait()

 else:print('SKIP Claude Code CLI not installed')
 codex=shutil.which('codex')
 if codex:
  lines=(args.templates/'Codex-stdio.txt').read_text().splitlines();overrides=[]
  for line in lines:
   if line.startswith('command = '):overrides+=['-c','mcp_servers.querycraft.command='+line.split(' = ',1)[1]]
   if line.startswith('args = '):overrides+=['-c','mcp_servers.querycraft.args='+json.dumps(['--stdio','--data-dir',str(data)])]
  result=subprocess.run([codex,*overrides,'mcp','get','querycraft','--json'],cwd=root,text=True,capture_output=True,timeout=30)
  assert result.returncode==0,result.stderr
  config=json.loads(result.stdout);assert config['name']=='querycraft' and config['transport']['args']==['--stdio','--data-dir',str(data)]
  print('PASS Codex actual TOML configuration parsing and stdio transport selection (no model request)')
 else:print('SKIP Codex CLI not installed')
