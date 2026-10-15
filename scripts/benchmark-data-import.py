#!/usr/bin/env python3
"""Measure the actual import parsers/storage compiled with -O, without UI or a database.

Only AppCopy localization is stubbed by the harness. Fixtures contain synthetic data.
Example: python3 scripts/benchmark-data-import.py --rows 28311 300000 --columns 78
"""
import argparse
import json
import csv
import tempfile
import zipfile
from pathlib import Path
import platform
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--rows', type=int, nargs='+', default=[28311, 300000])
parser.add_argument('--formats', nargs='+', choices=['sql','csv','json','jsonl','xlsx'], default=['sql'])
parser.add_argument('--columns', type=int, default=78)
args = parser.parse_args()
if any(n < 1 for n in args.rows) or args.columns < 1:
    parser.error('row and column counts must be positive')
root = Path(__file__).resolve().parent.parent
output = root / '.build/validation/import-performance'
output.mkdir(parents=True, exist_ok=True)
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
compiler = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
sdk = developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
source = root / 'QueryCraftPackage/Sources/QueryCraftFeature'
files = ['WorkspaceDataImportFile', 'WorkspaceDataImportRows', 'WorkspaceSQLImporter',
         'WorkspaceDelimitedImporter', 'WorkspaceJSONImporter', 'WorkspaceXLSXImporter', 'WorkspaceDataImportTextStream']
command = [str(compiler), '-O', '-parse-as-library', '-target', platform.machine() + '-apple-macosx15.0',
           '-sdk', str(sdk), str(root / 'scripts/benchmark-data-import.swift')]
command += [str(source / (name + '.swift')) for name in files]
command += ['-lz', '-o', str(output / 'benchmark')]
subprocess.run(command, check=True)
def fixture(path, rows, width):
    names = [f'column_{i}' for i in range(width)]
    # Exact integers and numeric text, Unicode, NULL and empty strings.
    values = ['9007199254740993'] + [None if i % 4 == 0 else '' if i % 4 == 1 else '中文🙂 O\'Reilly, line' if i % 4 == 2 else '1234567890.123456789' for i in range(1,width)]
    if path.suffix == '.xlsx':
        with zipfile.ZipFile(path,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=3) as archive:
            archive.writestr('xl/workbook.xml','<workbook xmlns:r="urn:r"><sheets><sheet name="Data" r:id="r1"/></sheets></workbook>')
            archive.writestr('xl/_rels/workbook.xml.rels','<Relationships><Relationship Id="r1" Target="worksheets/sheet1.xml"/></Relationships>')
            def cell(index, row, text):
                letters = ''; n = index+1
                while n: n,d = divmod(n-1,26); letters = chr(65+d)+letters
                if text is None: return ''
                escaped = text.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
                return f'<c r="{letters}{row}" t="inlineStr"><is><t>{escaped}</t></is></c>'
            with archive.open('xl/worksheets/sheet1.xml','w',force_zip64=True) as sheet:
                sheet.write(('<worksheet><sheetData><row r="1">'+''.join(cell(i,1,text) for i,text in enumerate(names))+'</row>').encode())
                for row in range(2,rows+2):
                    sheet.write((f'<row r="{row}">'+''.join(cell(i,row,text) for i,text in enumerate(values))+'</row>').encode())
                sheet.write(b'</sheetData></worksheet>')
        return
    with path.open('w',encoding='utf-8',newline='') as handle:
        if path.suffix == '.csv':
            writer = csv.writer(handle)
            writer.writerow(names)
            for _ in range(rows): writer.writerow(['NULL' if value is None else value for value in values])
        elif path.suffix == '.jsonl':
            line = json.dumps(dict(zip(names,values)),ensure_ascii=False,separators=(',',':'))+'\n'
            for _ in range(rows): handle.write(line)
        else:
            handle.write('{"columns":'+json.dumps(names)+',"rows":[')
            line = json.dumps(values,ensure_ascii=False,separators=(',',':'))
            for row in range(rows):
                if row: handle.write(',')
                handle.write(line)
            handle.write(']}')

for rows in args.rows:
    for fmt in args.formats:
        with tempfile.TemporaryDirectory(prefix='qc-import-measure-') as folder:
            command = [str(output/'benchmark'),str(rows),str(args.columns)]
            if fmt != 'sql':
                path = Path(folder)/('fixture.'+fmt)
                fixture(path,rows,args.columns)
                command.append(str(path))
            result = subprocess.check_output(command,text=True)
            data = json.loads(result)
            (output/f'{rows}x{args.columns}-{fmt}.json').write_text(result)
            print(json.dumps(data,ensure_ascii=False),flush=True)
