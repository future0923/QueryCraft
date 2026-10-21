#!/usr/bin/env python3
"""Verify signed MCP install/rollback/launchd and render native settings without desktop input."""
from pathlib import Path
import argparse, functools, http.server, importlib.util, json, os, platform, plistlib, shutil, socket, subprocess, tempfile, threading, time
ROOT=Path(__file__).resolve().parent.parent

def run(args, **kw):
    subprocess.run([str(v) for v in args],check=True,**kw)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app',type=Path)
    parser.add_argument('--build-dir',type=Path,default=ROOT/'.build/DerivedData')
    parser.add_argument('--configuration',choices=['Debug','Release'],default='Debug')
    parser.add_argument('--output',type=Path,default=ROOT/'.build/mcp-desktop-check')
    parser.add_argument('--drivers-dir',type=Path,help='Also verify six-driver loading through the signed desktop host')
    parser.add_argument('--previous-drivers-dir',type=Path,help='Exercise desktop startup adoption of staged MySQL/Doris updates in isolated storage')
    parser.add_argument('--language',choices=['en','zh-Hans'],default='en',help='Language for native layout validation')
    parser.add_argument('--render-only',action='store_true',help='Only render isolated native settings; skip runtime lifecycle checks')
    parser.add_argument('--component-checks',action='store_true',help='Verify independent signed catalog install/update/rollback and standalone CLI')
    parser.add_argument('--launchd-checks',action='store_true',help='Opt in to real macOS background-service registration; may show system background-activity notifications')
    parser.add_argument('--measure-only',action='store_true',help='With --render-only, measure layout and retained pages without capturing screenshots')
    args=parser.parse_args()
    if args.component_checks and args.configuration == 'Release':
        parser.error('Component lifecycle fixtures use loopback HTTP and require Debug host/runtime builds. Release packages enforce HTTPS; verify them with test-mcp-package.py.')
    if not (args.render_only or args.component_checks or args.launchd_checks):
        parser.error('Choose --render-only or --component-checks for routine checks. Persistent HTTP lifecycle checks require --launchd-checks and may show macOS background-activity notifications.')
    dd=args.build_dir.resolve(); products=dd/'Build/Products'/args.configuration; frameworks=products/'PackageFrameworks'
    args.output.mkdir(parents=True,exist_ok=True)
    spec=importlib.util.spec_from_file_location('signer',ROOT/'scripts/code-signing.py');signer=importlib.util.module_from_spec(spec);spec.loader.exec_module(signer)
    identity=signer.activate()
    with tempfile.TemporaryDirectory(prefix='qc-mcp-desktop-') as temp:
        temp=Path(temp);host=temp/'Verifier.app';(host/'Contents/MacOS').mkdir(parents=True)
        binary=host/'Contents/MacOS/Verifier'
        (host/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'io.github.future0923.QueryCraft.MCP.Verifier','CFBundleExecutable':'Verifier','CFBundlePackageType':'APPL','CFBundleLocalizations':[args.language],'CFBundleDevelopmentRegion':args.language,'LSUIElement':True}))
        sdk=subprocess.check_output(['/usr/bin/xcode-select','-p'],text=True).strip()+'/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
        command=['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc','-parse-as-library','-target',platform.machine()+'-apple-macosx15.0','-sdk',sdk,ROOT/'scripts/test-mcp-desktop.swift',ROOT/'scripts/test-mcp-components.swift',ROOT/'scripts/test-mcp-download-progress.swift','-I',products,'-F',frameworks,'-framework','QueryCraftFeature','-o',binary,'-Xlinker','-rpath','-Xlinker',frameworks]
        for name in ['TreeSitterJSON','TreeSitterSQL','TreeSitter','Internal']:
            modulemap=dd/f'Build/Intermediates.noindex/GeneratedModuleMaps/{name}.modulemap'
            if modulemap.exists():command+=['-Xcc','-fmodule-map-file='+str(modulemap)]
        command+=['-Xcc','-fmodule-map-file='+str(dd/'SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap')]
        for path in [ROOT/'ThirdParty/CodeEditLanguages/Sources/TreeSitterJSON/include',ROOT/'ThirdParty/CodeEditLanguages/Sources/TreeSitterSQL/include',dd/'SourcePackages/checkouts/tree-sitter/lib/include',dd/'SourcePackages/checkouts/TextStory/Sources/Internal',ROOT/'ThirdParty/CodeEditTextView/Sources/CodeEditTextViewObjC/include']:
            command+=['-Xcc','-I'+str(path)]
        run(command)
        resources=host/'Contents/Resources';resources.mkdir()
        for bundle in products.glob('*.bundle'):shutil.copytree(bundle,resources/bundle.name,symlinks=True)
        signer.run('codesign','--force','--sign',identity,'--keychain',signer.KEYCHAIN,'--timestamp=none',host)
        # Signed fixture passes staging self-test, then fails only after replacement.
        broken=temp/'Broken.app';(broken/'Contents/MacOS').mkdir(parents=True)
        info=plistlib.loads((args.app/'Contents/Info.plist').read_bytes());(broken/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (broken/'Contents/Helpers').mkdir()
        shutil.copy2(args.app/'Contents/Helpers/querycraft-mcp-launcher',broken/'Contents/Helpers/querycraft-mcp-launcher')
        source=temp/'fail.c';source.write_text('#include <string.h>\nint main(int argc,char **argv){return strstr(argv[0],".install-") ? 0 : 42;}\n')
        run(['/usr/bin/cc',source,'-o',broken/'Contents/MacOS/querycraft-mcp'])
        signer.run('codesign','--force','--sign',identity,'--keychain',signer.KEYCHAIN,'--timestamp=none',broken)
        delayed=temp/'delayed-mcp'
        source=temp/'delayed.c'
        runtime=str(args.app.resolve()/'Contents/MacOS/querycraft-mcp')
        source.write_text('#include <unistd.h>\nint main(int argc,char **argv){sleep(5);argv[0]='+json.dumps(runtime)+';execv(argv[0],argv);return 127;}\n')
        run(['/usr/bin/cc',source,'-o',delayed])
        signer.run('codesign','--force','--sign',identity,'--keychain',signer.KEYCHAIN,'--timestamp=none',delayed)
        with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        storage=temp/('Data-'+temp.name)
        with socket.socket() as component_sock:
            component_sock.bind(("127.0.0.1",0));component_http_port=component_sock.getsockname()[1]
        component_server=None
        if args.component_checks:
            serving=args.output.resolve()/'catalog';serving.mkdir(parents=True,exist_ok=True)
            class QuietHandler(http.server.SimpleHTTPRequestHandler):
                def log_message(self,*args):pass
                def do_GET(self):
                    if not self.path.startswith('/progress-'):
                        return super().do_GET()
                    payload = b'q' * 524288
                    self.send_response(503 if self.path == '/progress-error' else 200)
                    if self.path != '/progress-unknown-size':
                        self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    if self.path == '/progress-error':
                        self.close_connection = True
                        return
                    try:
                        for offset in range(0, len(payload), 4096):
                            self.wfile.write(payload[offset:offset+4096])
                            self.wfile.flush()
                            time.sleep(.01)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
            component_server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(QuietHandler,directory=str(serving)))
            threading.Thread(target=component_server.serve_forever,daemon=True).start();port=component_server.server_port
        try:
            command=[binary,args.app.resolve(),storage,broken,args.output.resolve(),port]
            if args.drivers_dir:
                driver_root=storage/'DriverAPI-5'
                shutil.copytree(args.previous_drivers_dir or args.drivers_dir,driver_root/'Drivers',symlinks=True)
                if args.previous_drivers_dir:
                    for name in ['MySQL-'+platform.machine()+'.querycraftdriver','Doris-'+platform.machine()+'.querycraftdriver']:
                        shutil.copytree(args.drivers_dir/name,driver_root/'DriverUpdates'/name,symlinks=True)
                command.append(driver_root/'Drivers')
            run(command,env=dict(os.environ,DYLD_FRAMEWORK_PATH=str(frameworks),QC_MCP_COMPONENT_HTTP_PORT=str(component_http_port),QC_MCP_COMPONENT_CHECKS='1' if args.component_checks else '0',QC_MCP_LAUNCHD_CHECKS='1' if args.launchd_checks else '0',QC_MCP_COMPONENT_BASE_URL=f'http://127.0.0.1:{port}/',QC_MCP_SIGNING_IDENTITY=identity,QC_MCP_SIGNING_KEYCHAIN=str(signer.KEYCHAIN),QC_MCP_RENDER_ONLY='1' if args.render_only else '0',QC_MCP_MEASURE_ONLY='1' if args.measure_only else '0',QC_MCP_DELAYED_EXECUTABLE=str(delayed)),timeout=600)
            if args.render_only or args.component_checks:return
            if args.previous_drivers_dir:
                assert not list((driver_root/'DriverUpdates').glob('*.querycraftdriver')),'Pending driver updates were not adopted'
                for name in ['MySQL-'+platform.machine()+'.querycraftdriver','Doris-'+platform.machine()+'.querycraftdriver']:
                    for file in (args.drivers_dir/name).rglob('*'):
                        if file.is_file():assert file.read_bytes()==(driver_root/'Drivers'/name/file.relative_to(args.drivers_dir/name)).read_bytes()
                print('PASS desktop startup adopted staged MySQL/Doris updates with exact packaged contents',flush=True)
            spec=importlib.util.spec_from_file_location('lifecycle',ROOT/'scripts/test-mcp-lifecycle.py')
            lifecycle=importlib.util.module_from_spec(spec);spec.loader.exec_module(lifecycle)
            settings=json.loads((storage/'mcp-policy.json').read_text())
            client=lifecycle.HTTPClient(settings).connect()
            assert client.call('list_connections')==[]
            client.close()
            print('PASS HTTP remains usable after signed desktop host process exits',flush=True)
            label=f'io.github.future0923.QueryCraft.MCP.{storage.name}'
            plist=storage/'LaunchAgents'/f'{label}.plist'
            configuration=plistlib.loads(plist.read_bytes())
            assert configuration['RunAtLoad'] is True
            run(['/bin/launchctl','bootout',f'gui/{os.getuid()}/{label}'])
            # Re-bootstrap the saved job as launchd would at login. This is not
            # a claim to have rebooted or logged the user out of their machine.
            run(['/bin/launchctl','bootstrap',f'gui/{os.getuid()}',plist])
            deadline=time.monotonic()+20
            while time.monotonic()<deadline:
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.2):break
                except OSError:time.sleep(.1)
            else:raise AssertionError('Persisted launchd job failed to restart')
            client=lifecycle.HTTPClient(settings).connect()
            assert client.call('list_connections')==[]
            client.close()
            print('PASS saved RunAtLoad job re-bootstrap and authenticated client reconnect without desktop host',flush=True)
        except Exception:
            diagnostic=storage/'MCP/http.log'
            if diagnostic.exists():
                shutil.copy2(diagnostic,args.output/'service-failure.log')
            raise
        finally:
            if component_server:
                component_server.shutdown();component_server.server_close()
            if args.launchd_checks:
                # This exact random fixture label belongs to this harness only.
                subprocess.run(['/bin/launchctl','bootout',f'gui/{os.getuid()}/io.github.future0923.QueryCraft.MCP.{storage.name}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                owned_plist=Path.home()/'Library/LaunchAgents'/f'io.github.future0923.QueryCraft.MCP.{storage.name}.plist'
                if owned_plist.exists():owned_plist.unlink()


if __name__=='__main__':main()
