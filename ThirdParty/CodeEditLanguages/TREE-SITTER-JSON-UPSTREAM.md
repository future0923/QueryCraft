# tree-sitter-json upstream

- Upstream: https://github.com/tree-sitter/tree-sitter-json
- Version: v0.24.8
- License: MIT (`TreeSitterJSON-LICENSE.md`)
- Vendored generated files: `src/parser.c` and `src/tree_sitter/parser.h`
- Query: upstream `queries/highlights.scm`, with capture names adapted to the
  local CodeEdit theme vocabulary (keys, strings, numbers, boolean/null, escapes).

The generated parser is vendored so QueryCraft's trimmed CodeEditLanguages fork
supports JSON without importing the complete upstream language bundle.
