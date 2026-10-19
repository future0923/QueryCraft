#!/usr/bin/env python3
"""Owned localhost MySQL fixtures; tests the Swift production engine and deployer."""
from pathlib import Path
import json, os, platform, plistlib, shutil, subprocess, time, uuid
ROOT = Path(__file__).resolve().parent.parent
DD = Path(os.environ.get('DERIVED_DATA', ROOT/'output/schema-comparison-build')).resolve()
OUT = Path(os.environ.get('QC_FULL_OUTPUT', DD/'regression/full-native')).resolve()
OUT.mkdir(parents=True,exist_ok=True)
DOCKER = shutil.which('docker') or '/Applications/Docker.app/Contents/Resources/bin/docker'
PRODUCTS = DD/'Build/Products/Debug'
PROBE = PRODUCTS/'SchemaComparisonFullProbe.app'
if PROBE.exists():
    previous = plistlib.loads((PROBE/'Contents/Info.plist').read_bytes())
    assert previous.get('CFBundleIdentifier') == 'io.github.future0923.QueryCraft.SchemaFullProbe'
    shutil.rmtree(PROBE)
MACOS = PROBE/'Contents/MacOS'
MACOS.mkdir(parents=True)
RESOURCES = PROBE/'Contents/Resources'
RESOURCES.mkdir(parents=True)
shutil.copy2(PRODUCTS/'schema-comparison-full-native', MACOS/'schema-comparison-full-native')
(MACOS/'schema-comparison-accessibility').symlink_to(PRODUCTS/'schema-comparison-accessibility')
for bundle in PRODUCTS.glob('*.bundle'):
    (MACOS/bundle.name).symlink_to(bundle)
    (RESOURCES/bundle.name).symlink_to(bundle)
for locale in ['zh-Hans','en']:
    (PROBE/'Contents/Resources'/f'{locale}.lproj').mkdir(parents=True)
(PROBE/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='io.github.future0923.QueryCraft.SchemaFullProbe',CFBundleExecutable='schema-comparison-full-native',CFBundleName='Schema Full Probe',CFBundlePackageType='APPL',CFBundleDevelopmentRegion='en',CFBundleLocalizations=['zh-Hans','en'],NSHighResolutionCapable=True,LSUIElement=True)))
PREFIX = 'qc-schema-full-'+uuid.uuid4().hex[:8]
owned = []
def run(args, input=None, timeout=180):
    p = subprocess.run(list(map(str,args)),input=input,text=True,capture_output=True,timeout=timeout)
    if p.returncode: raise RuntimeError(p.stdout[-3000:]+p.stderr[-3000:])
    return p.stdout.strip()
def sql(name, text):
    return run([DOCKER,'exec','-i',name,'mysql','--protocol=TCP','-h127.0.0.1','-uroot','--default-character-set=utf8mb4','-N','-B'],input=text)
def start(tag,image):
    name=PREFIX+'-'+tag
    run([DOCKER,'run','--rm','-d','--name',name,'-e','MYSQL_ALLOW_EMPTY_PASSWORD=yes','-p','127.0.0.1::3306',image,'--character-set-server=utf8mb4','--collation-server=utf8mb4_general_ci'])
    owned.append(name)
    port=int(json.loads(run([DOCKER,'inspect',name]))[0]['NetworkSettings']['Ports']['3306/tcp'][0]['HostPort'])
    end=time.monotonic()+150
    while True:
        try: version=sql(name,'SELECT @@version;');break
        except RuntimeError:
            if time.monotonic()>end:raise
            time.sleep(.5)
    sql(name,"""
CREATE DATABASE qc_schema_source CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE qc_schema_target CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE TABLE qc_schema_source.parents (id bigint NOT NULL, code int NOT NULL, PRIMARY KEY(id,code));
CREATE TABLE qc_schema_target.parents (id int NOT NULL, code int NOT NULL, PRIMARY KEY(id,code));
CREATE TABLE qc_schema_source.orders (id int NOT NULL PRIMARY KEY, parent_id bigint, parent_code int, note varchar(200) DEFAULT NULL COMMENT '买家备注', KEY idx_note(note(12)), KEY idx_parent(parent_id,parent_code), CONSTRAINT fk_parent FOREIGN KEY(parent_id,parent_code) REFERENCES qc_schema_source.parents(id,code) ON DELETE CASCADE);
CREATE TABLE qc_schema_target.orders (id int NOT NULL PRIMARY KEY, parent_id int, parent_code int, KEY idx_parent(parent_id,parent_code), CONSTRAINT fk_parent FOREIGN KEY(parent_id,parent_code) REFERENCES qc_schema_target.parents(id,code) ON DELETE CASCADE);
CREATE TABLE qc_schema_source.users (id int NOT NULL PRIMARY KEY, email varchar(255), status varchar(16) DEFAULT 'active', UNIQUE KEY ux_email(email));
CREATE TABLE qc_schema_target.users (id int NOT NULL PRIMARY KEY, email varchar(100), obsolete varchar(30));
INSERT INTO qc_schema_target.users VALUES(1,'buyer@example.com','legacy');
CREATE TABLE qc_schema_source.new_parent(id int PRIMARY KEY);
CREATE TABLE qc_schema_source.new_child(id int, parent_id int, KEY ix(parent_id), CONSTRAINT fk_new_parent FOREIGN KEY(parent_id) REFERENCES qc_schema_source.new_parent(id));
CREATE TABLE qc_schema_source.promote_pk(id int NOT NULL AUTO_INCREMENT PRIMARY KEY);
CREATE TABLE qc_schema_target.promote_pk(id int);
INSERT INTO qc_schema_target.promote_pk VALUES(3);
CREATE TABLE qc_schema_target.old_parent(id int PRIMARY KEY);
CREATE TABLE qc_schema_target.old_child(id int, parent_id int, KEY ix(parent_id), CONSTRAINT fk_old_parent FOREIGN KEY(parent_id) REFERENCES qc_schema_target.old_parent(id));
CREATE VIEW qc_schema_source.v_users AS SELECT id,email FROM qc_schema_source.users WHERE id > 0;
CREATE VIEW qc_schema_target.v_users AS SELECT id,email FROM qc_schema_target.users;
CREATE TRIGGER qc_schema_source.trg_user BEFORE INSERT ON qc_schema_source.users FOR EACH ROW SET NEW.email=LOWER(NEW.email);
CREATE TRIGGER qc_schema_target.trg_user BEFORE INSERT ON qc_schema_target.users FOR EACH ROW SET NEW.email=UPPER(NEW.email);
CREATE TRIGGER qc_schema_source.trg_suffix BEFORE INSERT ON qc_schema_source.users FOR EACH ROW SET NEW.email=CONCAT(NEW.email,'A');
CREATE TRIGGER qc_schema_target.trg_suffix BEFORE INSERT ON qc_schema_target.users FOR EACH ROW SET NEW.email=CONCAT(NEW.email,'A');
CREATE USER 'qc_reader'@'%' IDENTIFIED BY '';
GRANT SELECT,SHOW VIEW ON qc_schema_source.* TO 'qc_reader'@'%';
CREATE USER 'qc_table_reader'@'%' IDENTIFIED BY '';
GRANT SELECT ON qc_schema_source.users TO 'qc_table_reader'@'%';
DELIMITER $$
CREATE FUNCTION qc_schema_target.double_id(n int) RETURNS int DETERMINISTIC RETURN n*3$$
CREATE FUNCTION qc_schema_source.double_id(n int) RETURNS int DETERMINISTIC RETURN n*2$$
CREATE PROCEDURE qc_schema_source.double_id(IN n int) SELECT n$$
CREATE PROCEDURE qc_schema_target.double_id(IN n int) SELECT n+1$$
CREATE PROCEDURE qc_schema_source.sample_proc() BEGIN SELECT 'A; B  C'; SELECT 2; END$$
DELIMITER ;
""")
    print('READY',tag,version,port,flush=True)
    return name,port,version
try:
    source=start('57','public.ecr.aws/docker/library/mysql:5.7')
    targets=[start('80','public.ecr.aws/docker/library/mysql:8.0'),start('84','mysql:8.4')]
    # Native MySQL 8 features exercise the same Swift adapter in the reverse
    # version direction too, using a fresh owned schema on the 8.0 server.
    sql(targets[1][0], """
ALTER TABLE qc_schema_source.users ADD COLUMN normalized_email varchar(255) GENERATED ALWAYS AS (LOWER(email)) STORED;
CREATE INDEX fx_email ON qc_schema_source.users ((LOWER(email)));
ALTER TABLE qc_schema_source.orders ADD CONSTRAINT ck_positive CHECK (id > 0);
""")
    for instance in [source] + targets:
        sql(instance[0], "SET GLOBAL sql_select_limit=1;")
    summaries=[]
    cases = [(source,targets[0]),(source,targets[1]),(targets[1],targets[0])]
    case_limit = int(os.environ.get('QC_SCHEMA_FULL_CASE_LIMIT', len(cases)))
    assert 1 <= case_limit <= len(cases), 'QC_SCHEMA_FULL_CASE_LIMIT must be between 1 and 3'
    for current_source,target in cases[:case_limit]:
        if current_source == targets[1]:
            sql(target[0], "ALTER TABLE qc_schema_target.users DROP COLUMN concurrent_change;")
        folder=OUT/(current_source[2]+'-to-'+target[2]);folder.mkdir(parents=True,exist_ok=True)
        env=dict(os.environ,QC_SCHEMA_TEST_PORT=str(current_source[1]),QC_SCHEMA_TARGET_PORT=str(target[1]),QC_REGRESSION_OUTPUT=str(folder),QC_REGRESSION_DRIVERS=str(Path.home()/'Library/Application Support/QueryCraftDev/DriverAPI-5/Drivers'),QC_REGRESSION_ARCH=platform.machine(),DYLD_FRAMEWORK_PATH=os.environ.get('QC_SCHEMA_RUNTIME_FRAMEWORKS',str(DD/'Build/Products/Debug/PackageFrameworks')))
        if os.environ.get('QC_SCHEMA_SKIP_UI')!='1':
            deadline=time.monotonic()+240
            while True:
                session=plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg','-n','Root','-d1','-a']))
                if isinstance(session,list):session=session[0]
                locked=any(u.get('CGSSessionScreenIsLocked',False) for u in session.get('IOConsoleUsers',[]))
                if not locked:break
                if time.monotonic()>deadline:raise RuntimeError('Native UI is waiting for the user to unlock the desktop.')
                time.sleep(1)
        if os.environ.get('QC_SCHEMA_LAUNCHSERVICES')!='1':
            p=subprocess.run([str(MACOS/'schema-comparison-full-native'),'-AppleLanguages','(zh-Hans)'],env=env,text=True,capture_output=True,timeout=240)
            (folder/'run.log').write_text(p.stdout+p.stderr)
        else:
            status=folder/'probe-status.txt';status.unlink(missing_ok=True)
            env['QC_REGRESSION_STATUS']=str(status)
            # Register a real GUI application through LaunchServices. A shell
            # child can have an AXApplication object without a usable window
            # server/AX window bridge even when the display is unlocked.
            args=['/usr/bin/open','-g','-n','-W','-a',str(PROBE),'-o',str(folder/'run.log'),'--stderr',str(folder/'run.log')]
            for key,value in env.items():
                if key.startswith('QC_') or key=='DYLD_FRAMEWORK_PATH':args+=['--env',key+'='+value]
            p=subprocess.run(args+['--args','-AppleLanguages','(zh-Hans)'],text=True,capture_output=True,timeout=240)
            p.stdout=(folder/'run.log').read_text() if (folder/'run.log').exists() else p.stdout
            if not status.exists() or status.read_text()!='PASS':p.returncode=1
        if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr[-5000:])
        if os.environ.get('QC_SCHEMA_SKIP_UI')!='1':
            required=['review-object-compositor.png','review-large-compositor.png','review-large-scrolled-light.png','review-large-scrolled-dark.png','differences-large-compositor.png','differences-missing-side.png','setup-compositor.png','reading-compositor.png','differences-compositor.png','differences-narrow-light.png','differences-narrow-dark.png','review-compositor.png','deployment-compositor.png','rollback-compositor.png','options-compositor.png','options-dark-compositor.png','options-comparison-compositor.png','options-filters-compositor.png','options-advanced-compositor.png']
            missing=[name for name in required if not (folder/name).exists()]
            if missing:raise RuntimeError('Native screenshots incomplete: '+', '.join(missing))
        assert sql(target[0],"SELECT email FROM qc_schema_target.users WHERE id=1;")=='buyer@example.com'
        # The exported client script must choose its own database and handle
        # complete stored-program bodies without a caller-provided USE context.
        forward=(folder/'forward.sql').read_text()
        rollback=(folder/'rollback.sql').read_text()
        assert 'USE `qc_schema_target`;' in forward and 'DELIMITER' in forward
        sql(target[0],forward)
        assert sql(target[0],'SELECT qc_schema_target.double_id(3);')=='6'
        assert sql(target[0],'CALL qc_schema_target.double_id(3);')=='3'
        sql(target[0],"INSERT INTO qc_schema_target.users(id,email) VALUES(99,'MiXeD');")
        assert sql(target[0],'SELECT email FROM qc_schema_target.users WHERE id=99;')=='mixedA'
        sql(target[0],'DELETE FROM qc_schema_target.users WHERE id=99;')
        assert 'A; B  C' in sql(target[0],'CALL qc_schema_target.sample_proc();')
        sql(target[0],rollback)
        assert sql(target[0],'SELECT qc_schema_target.double_id(3);')=='9'
        assert sql(target[0],'CALL qc_schema_target.double_id(3);')=='4'
        print(p.stdout.strip(),flush=True)
        summaries.append({'source':current_source[2],'target':target[2],'status':'passed','native_ui':os.environ.get('QC_SCHEMA_SKIP_UI')!='1'})
    (OUT/'summary.json').write_text(json.dumps(summaries,indent=2))
finally:
    for name in owned:subprocess.run([DOCKER,'stop',name],capture_output=True,timeout=45)
