# flutter_quill (Voges Word copy)

A copy of [flutter_quill](https://pub.dev/packages/flutter_quill) 11.5.0 (MIT license, see `LICENSE`) with two changes:

- pagination, so the editor shows the document in pages like Word;
- long documents open in linear time: `Document.fromDelta` builds the tree in one pass (Quill's loader, which searched the tree for every insert, stays as `Document.fromDeltaByInserts` for tests), line and block offsets are found from the previous known one, and `toDelta` no longer copies the result once per child.

The changes are marked with the comment `Voges Word:`. To update the package, copy the new version over it and reapply those parts.
