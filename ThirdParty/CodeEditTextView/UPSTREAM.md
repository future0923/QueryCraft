# CodeEditTextView Upstream

This directory is a QueryCraft-maintained fork of the MIT-licensed
`CodeEditApp/CodeEditTextView` package.

- Upstream: https://github.com/CodeEditApp/CodeEditTextView
- Version: `0.12.1`
- Revision: `d7ac3f11f22ec2e820187acce8f3a3fb7aa8ddec`
- Imported: 2026-07-17

The local package manifest omits the SwiftLint build plugin because lint
tooling must not be required to build or distribute QueryCraft.

## QueryCraft patches

- `SelectionManipulation+Horizontal.swift` treats the insertion point at the
  end of a document as part of the final visual line fragment and only removes
  a line-ending width when that line actually has a line ending.
- Update line layout after completed edits, but defer it during an enclosing
  text-storage batch such as undo. Scroll using the current selection endpoint
  rather than a stale insertion-indicator frame, with at most three layout
  refinement passes and allowance for the gutter/minimap.
- Preserve the widest measured line across incremental layout by updating the
  layout manager's stored width rather than a shadowing local variable.

No TablePro source code or patches are included in this directory.
