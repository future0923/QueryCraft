# tree-sitter-json upstream

- Upstream: https://github.com/tree-sitter/tree-sitter-json
- Version: v0.24.8
- License: MIT (`TreeSitterJSON-LICENSE.md`)
- Vendored generated files: `src/parser.c` and `src/tree_sitter/parser.h`
- Query: upstream `queries/highlights.scm`, with capture names adapted to the
  local CodeEdit theme vocabulary (keys, strings, numbers, boolean/null, escapes).

The generated parser is vendored so QueryCraft's trimmed CodeEditLanguages fork
supports JSON without importing the complete upstream language bundle.

Local grammar corrections (2026-10-14): accept a plus sign in numeric exponents
and capture all four hexadecimal digits of a Unicode escape as one escape_sequence.
Reviewed generator source is retained in `Generator/TreeSitterJSON/grammar.js`.
Regenerate ABI 14 C sources with `sh generate-tree-sitter-json.sh` (CLI v0.26.3).
