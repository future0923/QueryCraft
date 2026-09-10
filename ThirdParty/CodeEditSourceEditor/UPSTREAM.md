# CodeEditSourceEditor Upstream

This directory is a QueryCraft-maintained fork of the MIT-licensed
`CodeEditApp/CodeEditSourceEditor` package.

- Upstream: https://github.com/CodeEditApp/CodeEditSourceEditor
- Revision: `1fa4d3c3ffba007482111466cb9721416f97ae00`
- Imported: 2026-07-17

QueryCraft intentionally keeps this fork local because the upstream package
depends on the complete CodeEdit language bundle. QueryCraft uses SQL and JSON.
The package manifest points to the sibling trimmed compatibility package, and
non-SQL tag-completion filters are omitted. CodeEditTextView is supplied by the
sibling local fork at version `0.12.1`; its runtime patches are documented in
`../CodeEditTextView/UPSTREAM.md`, and its manifest omits SwiftLint.

Local compatibility fixes:

- JSON readers enable the existing layout-only line folding. Fold stream tasks
  keep weak owners, finish on teardown and yield between bounded line batches.
  Closing a reader must release its document and stop background fold work.
  A host-localized VoiceOver action toggles the current fold through the same
  implementation as clicking the gutter; stored text remains untouched.
  Fold depths use actual indentation rather than the Tab insertion width, so
  two-space JSON still folds when the user prefers four-space editing.
  Revision checks reject stale fold batches during document replacement; fold
  depth carries across line chunks and stream buffers keep only the newest work.

- Refresh completion candidates in place, measure the initial native row after
  assigning its available width, and reuse constraints. A completion session
  may expand for new candidates without shrinking as the user types/deletes.
  Native content-size constraints keep the anchored popup consistent.
- Update editor layout/configuration and folding geometry in place, including
  compact JSON inspectors and semantic colors, without replacing the host.

- Allow per-editor line-number leading padding and minimum digit reservation.
  Document JSON inspectors use a compact gutter; query editors retain upstream
  defaults. Gutter width still grows with actual line-number digits.

- Convert semantic AppKit theme colors to device RGB before reading their
  components in the minimap, reformatting guide, completion tint, and color
  helpers. Direct component access on colors such as
  `NSColor.textBackgroundColor` raises an AppKit exception.
- Defer the find panel's initial AppKit layout until its SwiftUI hosting view
  finishes the current render pass. Synchronous layout after `Cmd+F` otherwise
  triggers a reentrant `NSHostingView` layout warning and skips that pass.

No TablePro source code or patches are included in this directory.
