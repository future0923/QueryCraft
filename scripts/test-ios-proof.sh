#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
simulator="${1:?Usage: bash scripts/test-ios-proof.sh SIMULATOR_UUID}"
docker="${DOCKER_BIN:-$(command -v docker || true)}"
if [[ -z "$docker" && -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
    docker=/Applications/Docker.app/Contents/Resources/bin/docker
fi
[[ -x "$docker" ]] || { echo "Docker CLI is required for the isolated fixture." >&2; exit 1; }
"$docker" info >/dev/null
name="querycraft-ios-proof-$(uuidgen | tr '[:upper:]' '[:lower:]')"
root_password="$(uuidgen)"
cleanup() { "$docker" rm --force --volumes "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$docker" run --detach --rm --name "$name" --publish 127.0.0.1::3306 \
    --env "MYSQL_ROOT_PASSWORD=$root_password" --env MYSQL_ROOT_HOST=% mysql:8.4 >/dev/null
ready=0
for attempt in {1..90}; do
    if "$docker" exec --env "MYSQL_PWD=$root_password" "$name" mysqladmin --protocol=tcp --host=127.0.0.1 --user=root ping >/dev/null 2>&1; then
        ready=1; break
    fi
    sleep 1
done
[[ "$ready" == 1 ]] || { "$docker" logs --tail 30 "$name"; exit 1; }
"$docker" exec --interactive --env "MYSQL_PWD=$root_password" "$name" mysql --user=root --default-character-set=utf8mb4 <<'SQL'
CREATE DATABASE querycraft_ios_proof CHARACTER SET utf8mb4;
CREATE TABLE querycraft_ios_proof.sample (
    id INT PRIMARY KEY COMMENT 'primary identifier', name VARCHAR(80), nullable_value VARCHAR(30),
    payload VARBINARY(10), amount DECIMAL(12,2)
);
INSERT INTO querycraft_ios_proof.sample VALUES
    (1, '你好 iPad 👋', NULL, X'0041FF', 123.45), (2, 'second', '', X'42', 0.00);
CREATE VIEW querycraft_ios_proof.sample_view AS SELECT id, name FROM querycraft_ios_proof.sample;
CREATE TABLE querycraft_ios_proof.epoch_values (
    id BIGINT PRIMARY KEY, created_at BIGINT COMMENT 'Unix seconds', updated_at BIGINT COMMENT 'Unix milliseconds', created_time VARCHAR(30)
);
INSERT INTO querycraft_ios_proof.epoch_values VALUES
    (318987599031067570, 1700000000, 1700000000000, '1700000000'),
    (318987599031067571, NULL, 1700003600000, ''),
    (318987599031067572, 0, -1, '2023-11-14 22:13:20');
CREATE TABLE querycraft_ios_proof.export_rows (id INT PRIMARY KEY, note VARCHAR(80), amount DECIMAL(20,2));
INSERT INTO querycraft_ios_proof.export_rows
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<455)
SELECT n, CASE WHEN MOD(n,3)=0 THEN NULL WHEN MOD(n,3)=1 THEN '' ELSE CONCAT('雪,',n) END, n+0.25 FROM seq;
CREATE VIEW querycraft_ios_proof.export_view AS SELECT * FROM querycraft_ios_proof.export_rows;
CREATE TABLE querycraft_ios_proof.export_large (id INT PRIMARY KEY, payload LONGTEXT);
INSERT INTO querycraft_ios_proof.export_large VALUES (1, REPEAT('a', 8388609));
CREATE DATABASE querycraft_ios_other;
CREATE TABLE querycraft_ios_other.epoch_values LIKE querycraft_ios_proof.epoch_values;
INSERT INTO querycraft_ios_other.epoch_values SELECT * FROM querycraft_ios_proof.epoch_values;
CREATE USER 'proof_reader'@'%' IDENTIFIED BY 'querycraft-proof-reader';
GRANT SELECT ON querycraft_ios_proof.* TO 'proof_reader'@'%';
GRANT SELECT ON querycraft_ios_other.* TO 'proof_reader'@'%';
CREATE DATABASE querycraft_ios_edit CHARACTER SET utf8mb4;
CREATE USER 'proof_writer'@'%' IDENTIFIED BY 'querycraft-proof-writer';
GRANT SELECT,INSERT,UPDATE,DELETE ON querycraft_ios_edit.* TO 'proof_writer'@'%';
GRANT SELECT ON querycraft_ios_edit.* TO 'proof_reader'@'%';
CREATE TABLE querycraft_ios_edit.edit_rows (
 id BIGINT PRIMARY KEY, name VARCHAR(80), amount DECIMAL(20,2) NOT NULL DEFAULT 1.25,
 payload VARBINARY(10), computed VARCHAR(100) GENERATED ALWAYS AS (CONCAT(name,'!')) STORED,
 stamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO querycraft_ios_edit.edit_rows(id,name,payload) VALUES (318987599031067570,'original',X'0041FF');
CREATE TABLE querycraft_ios_edit.edit_atomic (id INT PRIMARY KEY, name VARCHAR(80), amount INT CHECK(amount>=0));
INSERT INTO querycraft_ios_edit.edit_atomic VALUES (1,'first',10),(2,'second',20);
CREATE TABLE querycraft_ios_edit.edit_cancel LIKE querycraft_ios_edit.edit_atomic;
INSERT INTO querycraft_ios_edit.edit_cancel SELECT * FROM querycraft_ios_edit.edit_atomic;
CREATE TABLE querycraft_ios_edit.edit_defaults (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(80) NOT NULL DEFAULT 'untouched', note TEXT, required_value INT NOT NULL);
CREATE TABLE querycraft_ios_edit.edit_composite (tenant INT, id BIGINT, name VARCHAR(80), PRIMARY KEY(tenant,id));
INSERT INTO querycraft_ios_edit.edit_composite VALUES (1,318987599031067570,'one'),(2,318987599031067570,'two');
CREATE TABLE querycraft_ios_edit.edit_nopk (id INT, name VARCHAR(30));
INSERT INTO querycraft_ios_edit.edit_nopk VALUES (1,'a'),(1,'b');
CREATE TABLE querycraft_ios_edit.edit_myisam (id INT PRIMARY KEY, name VARCHAR(30)) ENGINE=MyISAM;
INSERT INTO querycraft_ios_edit.edit_myisam VALUES (1,'unchanged');
CREATE TABLE querycraft_ios_edit.reliability_cancel (id INT PRIMARY KEY, name VARCHAR(80));
INSERT INTO querycraft_ios_edit.reliability_cancel VALUES (1,'before');
CREATE TABLE querycraft_ios_edit.reliability_commit LIKE querycraft_ios_edit.reliability_cancel;
INSERT INTO querycraft_ios_edit.reliability_commit VALUES (1,'before');
CREATE TABLE querycraft_ios_edit.reliability_inflight LIKE querycraft_ios_edit.reliability_cancel;
INSERT INTO querycraft_ios_edit.reliability_inflight VALUES (1,'before');
CREATE TABLE querycraft_ios_edit.reliability_disconnect LIKE querycraft_ios_edit.reliability_cancel;
INSERT INTO querycraft_ios_edit.reliability_disconnect VALUES (1,'before');
CREATE VIEW querycraft_ios_edit.edit_view AS SELECT id,name FROM querycraft_ios_edit.edit_rows;
CREATE TABLE querycraft_ios_edit.query_rows (id BIGINT PRIMARY KEY, name VARCHAR(80) COMMENT 'physical name', amount INT DEFAULT 7, payload VARBINARY(10));
INSERT INTO querycraft_ios_edit.query_rows VALUES (318987599031067570,'original',10,X'0041FF'),(318987599031067571,'second',20,NULL);
CREATE TABLE querycraft_ios_edit.query_failure (id INT PRIMARY KEY, name VARCHAR(80), amount INT CHECK(amount>=0));
INSERT INTO querycraft_ios_edit.query_failure VALUES (1,'first',10),(2,'second',20);
CREATE TABLE querycraft_ios_edit.query_defaults (id INT PRIMARY KEY, name VARCHAR(80) DEFAULT 'server default');
INSERT INTO querycraft_ios_edit.query_defaults VALUES (1,'original');
CREATE TABLE querycraft_ios_edit.query_denied LIKE querycraft_ios_edit.query_defaults;
INSERT INTO querycraft_ios_edit.query_denied VALUES (1,'unchanged');
CREATE VIEW querycraft_ios_edit.query_view AS SELECT * FROM querycraft_ios_edit.query_denied;
CREATE DATABASE querycraft_ios_query_other;
CREATE TABLE querycraft_ios_query_other.query_rows (tenant INT, id BIGINT, name VARCHAR(80), PRIMARY KEY(tenant,id));
INSERT INTO querycraft_ios_query_other.query_rows VALUES (1,318987599031067570,'one'),(2,318987599031067570,'two');
GRANT SELECT,INSERT,UPDATE,DELETE ON querycraft_ios_query_other.* TO 'proof_writer'@'%';
CREATE DATABASE querycraft_ios_table_actions CHARACTER SET utf8mb4;
CREATE USER 'proof_table_admin'@'%' IDENTIFIED BY 'querycraft-proof-table-admin';
GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,ALTER,DROP,INDEX ON querycraft_ios_table_actions.* TO 'proof_table_admin'@'%';
GRANT SELECT ON querycraft_ios_table_actions.* TO 'proof_reader'@'%';
CREATE TABLE querycraft_ios_table_actions.action_clear (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(80)) AUTO_INCREMENT=41;
INSERT INTO querycraft_ios_table_actions.action_clear(name) VALUES ('first'),('second');
CREATE TABLE querycraft_ios_table_actions.action_audit (id BIGINT);
CREATE TRIGGER querycraft_ios_table_actions.action_delete_audit AFTER DELETE ON querycraft_ios_table_actions.action_clear FOR EACH ROW INSERT INTO querycraft_ios_table_actions.action_audit VALUES (OLD.id);
CREATE TABLE querycraft_ios_table_actions.action_truncate LIKE querycraft_ios_table_actions.action_clear;
INSERT INTO querycraft_ios_table_actions.action_truncate(id,name) VALUES (41,'first'),(42,'second');
CREATE TABLE querycraft_ios_table_actions.action_rename (id INT PRIMARY KEY, name VARCHAR(80));
INSERT INTO querycraft_ios_table_actions.action_rename VALUES (1,'keep me');
CREATE TABLE querycraft_ios_table_actions.action_navigation (id INT PRIMARY KEY, name VARCHAR(80));
INSERT INTO querycraft_ios_table_actions.action_navigation VALUES (1,'navigation');
CREATE TABLE querycraft_ios_table_actions.schema_columns (
 id BIGINT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(80) NOT NULL DEFAULT 'original' COMMENT 'title',
 note VARCHAR(20), generated_len INT GENERATED ALWAYS AS (CHAR_LENGTH(title)) STORED,
 stamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
 hidden_value INT DEFAULT 3 INVISIBLE
);
INSERT INTO querycraft_ios_table_actions.schema_columns(title,note) VALUES ('abc','note');
CREATE TABLE querycraft_ios_table_actions.schema_add_drop (id INT PRIMARY KEY, remove_me VARCHAR(20));
INSERT INTO querycraft_ios_table_actions.schema_add_drop VALUES (1,'old');
CREATE TABLE querycraft_ios_table_actions.schema_indexes (id INT PRIMARY KEY, a VARCHAR(80), b INT, KEY old_idx(b), KEY functional_idx((lower(a))));
INSERT INTO querycraft_ios_table_actions.schema_indexes VALUES(1,'abc',2);
CREATE TABLE querycraft_ios_table_actions.schema_stale (id INT PRIMARY KEY);
CREATE TABLE querycraft_ios_table_actions.schema_denied LIKE querycraft_ios_table_actions.schema_stale;
CREATE TABLE querycraft_ios_table_actions.schema_authorization LIKE querycraft_ios_table_actions.schema_stale;
CREATE TABLE querycraft_ios_table_actions.schema_partial LIKE querycraft_ios_table_actions.schema_stale;
CREATE TABLE querycraft_ios_table_actions.schema_cancel LIKE querycraft_ios_table_actions.schema_stale;
CREATE TABLE querycraft_ios_table_actions.schema_unknown LIKE querycraft_ios_table_actions.schema_stale;
CREATE TABLE querycraft_ios_table_actions.action_drop (id INT PRIMARY KEY);
INSERT INTO querycraft_ios_table_actions.action_drop VALUES (1);
CREATE TABLE querycraft_ios_table_actions.action_auto (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(80)) AUTO_INCREMENT=99;
CREATE TABLE querycraft_ios_table_actions.action_no_auto (id BIGINT PRIMARY KEY);
CREATE TABLE querycraft_ios_table_actions.action_denied (id INT PRIMARY KEY);
INSERT INTO querycraft_ios_table_actions.action_denied VALUES (1);
CREATE TABLE querycraft_ios_table_actions.action_parent (id INT PRIMARY KEY);
CREATE TABLE querycraft_ios_table_actions.action_child (id INT PRIMARY KEY, parent_id INT, FOREIGN KEY(parent_id) REFERENCES querycraft_ios_table_actions.action_parent(id));
INSERT INTO querycraft_ios_table_actions.action_parent VALUES (1);
INSERT INTO querycraft_ios_table_actions.action_child VALUES (1,1);
CREATE VIEW querycraft_ios_table_actions.action_view AS SELECT * FROM querycraft_ios_table_actions.action_no_auto;
CREATE TABLE querycraft_ios_table_actions.action_unknown (id INT PRIMARY KEY);
INSERT INTO querycraft_ios_table_actions.action_unknown VALUES (1);
SQL
# Owned wide-table fixture for phone layout and catalog matching; no user data.
python3 - <<'PYSQL' | "$docker" exec --interactive --env "MYSQL_PWD=$root_password" "$name" mysql --user=root --default-character-set=utf8mb4
columns = ', '.join(f'field_{i:02d} VARCHAR(30)' for i in range(1, 75))
print(f'CREATE TABLE querycraft_ios_proof.admin_user (id INT PRIMARY KEY, user_name VARCHAR(80), user_nick VARCHAR(80), user_real_name VARCHAR(80), {columns});')
for i in range(1, 121):
    print(f"INSERT INTO querycraft_ios_proof.admin_user (id,user_name,user_nick,user_real_name,field_01) VALUES ({i},'user_{i:03d}','Display {i}','Example {i}','value');")
print('CREATE TABLE querycraft_ios_proof.`Case_Search%_表` (id INT PRIMARY KEY);')
print("CREATE TABLE querycraft_ios_proof.filter_cases (id INT PRIMARY KEY, text_value VARCHAR(255), note VARCHAR(255), score DECIMAL(20,2), flag BOOLEAN, state ENUM('one','two'), happened DATE, bits VARBINARY(10), `odd?` VARCHAR(30));")
text = "literal%_\\quote'\u96ea".encode('utf-8').hex()
print(f"INSERT INTO querycraft_ios_proof.filter_cases VALUES (1,CONVERT(0x{text} USING utf8mb4),NULL,1.10,1,'one','2024-01-02',X'0041FF','needle'),(2,'literalXX','',20,0,'two','2024-02-02',NULL,'other'),(3,CONVERT(0x27204f5220313d31202d2d USING utf8mb4),'normal',30,1,'one','2024-03-02',X'41','other');")
PYSQL
port="$("$docker" port "$name" 3306/tcp | awk -F: '{print $NF}')"
cd "$root"
xcodegen generate --spec QueryCraftMobile/project.yml >&2
mkdir -p "$root/.build/ios-validation"
test_report="$root/.build/ios-validation/mysql-first-$simulator-tests.json"
xcodebuildmcp simulator test \
    --project-path "$root/QueryCraftMobile/QueryCraftMobile.xcodeproj" \
    --scheme QueryCraftMobileProof --simulator-id "$simulator" \
    --derived-data-path "${IOS_PROOF_DERIVED_DATA:-$root/.build/ios-proof-derived}" \
    --json "$(python3 - "$port" <<'PYENV'
import json,os,sys
values=json.loads(os.environ.get('PROOF_ADDITIONAL_TEST_ENV', '{}'))
values['PROOF_MYSQL_PORT']=sys.argv[1]
print(json.dumps({'testRunnerEnv': values}))
PYENV
)" --output json > "$test_report"
cat "$test_report"
# The CLI may exit zero while its structured result reports a build/test failure.
# Never render a stale binary after a failed test/build.
python3 - "$test_report" <<'PYTEST'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert not result['didError'], result.get('error')
assert result['data']['summary']['status'] == 'SUCCEEDED', result['data']['summary']
PYTEST
if [[ "${2:-}" == render ]]; then
    mkdir -p "$root/.build/ios-validation"
    read -r -a render_scenes <<< "${IOS_RENDER_SCENES:-home empty-home catalog views query table structure}"
    for scene in "${render_scenes[@]}"; do
        xcodebuildmcp simulator stop --simulator-id "$simulator" --bundle-id io.github.future0923.QueryCraft.MobileProof --output json > /dev/null || true
        launch_json="$(python3 - "$port" "$scene" <<'PY'
import json,sys
scene = sys.argv[2]
print(json.dumps({'env':{'QUERYCRAFT_PROOF_MYSQL_PORT':sys.argv[1], 'QUERYCRAFT_PROOF_AUTORUN':'1', 'QUERYCRAFT_PROOF_TABLE': '0' if scene in ('query', 'query-fullscreen', 'query-find', 'timestamp-query', 'query-export', 'editor', 'editor-landscape', 'query-edit', 'query-edit-form', 'query-edit-pending') else '1', 'QUERYCRAFT_PROOF_SURFACE': scene.removeprefix('surface-') if scene.startswith('surface-') else '', 'QUERYCRAFT_PROOF_SQL_EDITOR': '1' if scene in ('editor', 'editor-landscape') else '0', 'QUERYCRAFT_PROOF_DATA_EDIT': '1' if scene in ('data-edit', 'query-edit-form') else '0', 'QUERYCRAFT_PROOF_QUERY_EDIT': '1' if scene.startswith('query-edit') else '0', 'QUERYCRAFT_PROOF_QUERY_PENDING': '1' if scene=='query-edit-pending' else '0', 'QUERYCRAFT_PROOF_EDIT_EXPERIENCE': '1' if scene.startswith(('query-edit', 'surface-')) else '0', 'QUERYCRAFT_PROOF_EXPORT': '1' if scene in ('export', 'query-export', 'all-export') else '0', 'QUERYCRAFT_PROOF_EXPORT_ALL': '1' if scene=='all-export' else '0', 'QUERYCRAFT_PROOF_TIMESTAMP': '1' if scene.startswith('timestamp') else '0', 'QUERYCRAFT_PROOF_SERVER_FILTER': '1' if scene=='server-filter' else '0', 'QUERYCRAFT_PROOF_FILTER_EDITOR': '1' if scene=='filter-editor' else '0', 'QUERYCRAFT_PROOF_STRUCTURE': '1' if scene=='structure' else '0', 'QUERYCRAFT_PROOF_HOME': '1' if scene=='home' else '0', 'QUERYCRAFT_PROOF_EMPTY_HOME': '1' if scene=='empty-home' else '0', 'QUERYCRAFT_PROOF_VIEWS': '1' if scene=='views' else '0', 'QUERYCRAFT_PROOF_SEARCH': 'amu' if scene=='search' else '', 'QUERYCRAFT_PROOF_GRID_FIND': ('user_090' if scene=='find' else 'second' if scene=='query-find' else ''), 'QUERYCRAFT_PROOF_FULLSCREEN': '1' if scene in ('fullscreen', 'fullscreen-landscape', 'query-fullscreen', 'timestamp-fullscreen') else '0', 'QUERYCRAFT_PROOF_LANDSCAPE': '1' if scene in ('landscape', 'fullscreen-landscape', 'editor-landscape', 'surface-full-landscape') else '0', 'QUERYCRAFT_PROOF_CATALOG': '1' if scene in ('catalog', 'search') else '0'}}))
PY
)"
        xcodebuildmcp simulator launch-app --simulator-id "$simulator" --bundle-id io.github.future0923.QueryCraft.MobileProof \
            --json "$launch_json" --output json > "$root/.build/ios-validation/mysql-first-$simulator-$scene-launch.json"
        # Bounded render settling; no simulated desktop input is used.
        sleep 3
        xcodebuildmcp simulator screenshot --simulator-id "$simulator" --return-format path --output json \
            > "$root/.build/ios-validation/mysql-first-$simulator-$scene-screenshot.json"
        python3 - "$root/.build/ios-validation/mysql-first-$simulator-$scene-screenshot.json" <<'PYIMAGE'
import json, pathlib, shutil, sys
file = pathlib.Path(sys.argv[1])
result = json.loads(file.read_text())
assert not result['didError'], result.get('error')
shutil.copy2(result['data']['artifacts']['screenshotPath'], file.with_suffix('.jpg'))
PYIMAGE
    done
fi

if [[ "${CHECK_MAC_DRIVERS:-0}" == 1 ]]; then
    PROOF_MYSQL_PORT="$port" DYLD_FRAMEWORK_PATH="$root/.build/ios-mac-regression/Build/Products/Debug/PackageFrameworks" \
        PACKAGE_RESOURCE_BUNDLE_PATH="$root/.build/ios-mac-regression/Build/Products/Debug" \
        "$root/.build/ios-validation/driver-load" "$root/.build/ios-driver-mixed" \
        > "$root/.build/ios-validation/mysql-first-mixed-driver-load.txt"
fi
