# flutter_quill (Voges Word copy)

A copy of [flutter_quill](https://pub.dev/packages/flutter_quill) 11.5.0 (MIT license, see `LICENSE`) with these changes:

- pagination, so the editor shows the document in pages like Word, including a page break at the start of a paragraph inside a block (a list, a centered or indented paragraph);
- long documents open in linear time: `Document.fromDelta` builds the tree in one pass (Quill's loader, which searched the tree for every insert, stays as `Document.fromDeltaByInserts` for tests), line and block offsets are found from the previous known one, and `toDelta` no longer copies the result once per child;
- long documents are edited in linear time: the line queries and edits (`collectStyle`, `getPlainText`, `retain`, `delete`, `insert` and the others) loop over the lines instead of recursing once per line, `Document.compose` walks on from the previous operation's line instead of searching the tree from the start, the history inverts a change in one pass, and deltas join the text of lines of one style once. A document made by `Document.fromDeltaByInserts` keeps Quill's algorithms (`Root.quillAlgorithms`), so tests compare both;
- the text of a line with an embed is built from the line's own runs, not from copies without a parent, so span builders (the spell checker) know their line.

The changes are marked with the comment `Voges Word:`. To update the package, copy the new version over it and reapply those parts.
