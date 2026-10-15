# Import workbook fixture

Synthetic OOXML archive generated with Python's standard `zipfile`, using DEFLATE compression. No external or customer data.

- `数据`: shared and rich strings, Chinese text, XML entities, a large integer, built-in date style, and sparse cells.
- `Second`: an inline string and a formula with a cached numeric result.
- `Escapes`: OOXML character escapes, ignored phonetic annotations, and a time-only cell.

Used by WorkspaceDataImportParserTests. A separate test exercises the application's ZIP writer through a real export/import round trip.
