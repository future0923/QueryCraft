#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
generator_dir="$script_dir/Generator/TreeSitterSQL"
output_dir="$script_dir/Sources/TreeSitterSQL"

cd "$generator_dir"
npx --yes --package=tree-sitter-cli@v0.26.3 -- \
    tree-sitter generate --abi 14

cp "$generator_dir/src/parser.c" "$output_dir/parser.c"
cp "$generator_dir/src/scanner.c" "$output_dir/scanner.c"
cp "$generator_dir/src/tree_sitter/parser.h" \
    "$output_dir/tree_sitter/parser.h"
