# tree-sitter-sql upstream

QueryCraft vendors only the generated SQL parser and SQL query resources from
the MIT-licensed `DerekStride/tree-sitter-sql` project.

- Upstream: https://github.com/DerekStride/tree-sitter-sql
- Baseline: post-`0.3.11` main
- Revision: `c2e1e08db1ea20dc23bdb8d228a81a8756e9c450`
- Generator: `tree-sitter-cli 0.26.3`, ABI 14
- Imported: 2026-07-27

The grammar was selected independently against QueryCraft-owned MySQL 5.7 and
8.x fixtures. No TablePro source or generated artifact is included.

## QueryCraft MySQL adaptations

- Reviewed generator inputs are retained under `Generator/TreeSitterSQL`; the
  generated C parser is intentionally not byte-for-byte upstream.
- `--` starts a comment only when followed by MySQL whitespace/control, and
  `#` line comments are supported.
- Ordinary block comments, optimizer hints, and executable comments have
  distinct `comment`, `optimizer_hint`, and `executable_comment` nodes.
- A standalone executable comment remains one exact unclassified statement.
- `DELIMITER` directives have a structural node so QueryCraft can fail
  stored-routine scripts closed without adding a second statement scanner.
- QueryCraft corrects the numeric highlight predicates to use ICU regular
  expression digit classes understood by SwiftTreeSitter instead of the
  upstream `%d` patterns.
- QueryCraft maps the upstream SQL capture names into its SQL-only editor theme
  in application code. No TablePro highlight query or patch is used.
