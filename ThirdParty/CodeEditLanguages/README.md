# QueryCraft SQL Language Compatibility

This small package provides the SQL-only language API required by the vendored
CodeEditSourceEditor. It is QueryCraft-owned code and does not include the
CodeEditLanguages binary bundle or any TablePro source.

The package carries a QueryCraft-maintained MySQL specialization of the
MIT-licensed DerekStride SQL grammar selected against QueryCraft-owned MySQL
fixtures. It does not carry the upstream multi-language binary bundle or any
TablePro source. See `TREE-SITTER-SQL-UPSTREAM.md` for the pinned source,
generator, and local adaptations.

Reviewed generator inputs live under `Generator/TreeSitterSQL`. Regenerate the
ABI 14 C artifacts with:

```sh
ThirdParty/CodeEditLanguages/generate-tree-sitter-sql.sh
```

QueryCraft compiles the generated `parser.c` and `scanner.c` and calls them
through SwiftTreeSitter, so the application does not include a JavaScript
runtime. The grammar is not a complete MySQL validator. QueryCraft preserves an
exact top-level statement when this tree still exposes its semicolon boundary,
while ambiguous boundaries and `DELIMITER` routine scripts fail closed.
