import 'package:flutter_quill/quill_delta.dart';

import '../document/embeds.dart';
import '../document/headers_footers.dart';

enum PageNumberPosition {
  topRight(header: true, align: 'right'),
  topCenter(header: true, align: 'center'),
  bottomRight(header: false, align: 'right'),
  bottomCenter(header: false, align: 'center');

  const PageNumberPosition({required this.header, required this.align});

  final bool header;
  final String align;
}

typedef _Line = ({List<Operation> content, Map<String, dynamic>? attributes});

/// Page number in the header or footer; it is removed from the other one so
/// it does not appear twice.
HeadersFooters withPageNumber(
  HeadersFooters current,
  PageNumberPosition position,
) {
  final target = position.header ? current.headers : current.footers;
  final other = position.header ? current.footers : current.headers;
  final placed = {
    ...target,
    PageVariant.normal: _place(target[PageVariant.normal], position.align),
  };
  final cleaned = _withoutNumbers(other);
  return current.copyWith(
    headers: position.header ? placed : cleaned,
    footers: position.header ? cleaned : placed,
  );
}

HeadersFooters withoutPageNumbers(HeadersFooters current) => current.copyWith(
  headers: _withoutNumbers(current.headers),
  footers: _withoutNumbers(current.footers),
);

/// Where the page number sits on regular pages, to mark it in the menu.
PageNumberPosition? pageNumberPosition(HeadersFooters current) {
  for (final header in [true, false]) {
    final story = (header
        ? current.headers
        : current.footers)[PageVariant.normal];
    if (story == null) continue;
    for (final line in _linesOf(story.delta)) {
      if (!line.content.any(isPageNumberOperation)) continue;
      final align = line.attributes?['align'] as String? ?? 'left';
      for (final position in PageNumberPosition.values) {
        if (position.header == header && position.align == align) {
          return position;
        }
      }
    }
  }
  return null;
}

bool isPageNumberOperation(Operation operation) => switch (operation.data) {
  {EmbedTypes.pageNumber: _} => true,
  {EmbedTypes.opaqueInline: final Object data} =>
    fieldNameOf(OpaqueContent.decode(data).xml) == 'PAGE',
  _ => false,
};

HeaderFooterStory _place(HeaderFooterStory? story, String align) {
  final lines = story == null ? <_Line>[] : _linesOf(story.delta);
  Map<String, dynamic> aligned(Map<String, dynamic>? attributes) => {
    ...?attributes,
    'align': align,
  };
  final index = lines.indexWhere(
    (line) => line.content.any(isPageNumberOperation),
  );
  final number = Operation.insert({EmbedTypes.pageNumber: 'PAGE'});
  if (index >= 0) {
    lines[index] = (
      content: lines[index].content,
      attributes: aligned(lines[index].attributes),
    );
  } else if (lines.every(_isEmpty)) {
    lines
      ..clear()
      ..add((content: [number], attributes: aligned(null)));
  } else {
    lines.add((content: [number], attributes: aligned(null)));
  }
  return HeaderFooterStory(
    delta: _deltaOf(lines),
    partPath: story?.partPath,
    edited: true,
  );
}

Map<PageVariant, HeaderFooterStory> _withoutNumbers(
  Map<PageVariant, HeaderFooterStory> stories,
) => {
  for (final MapEntry(:key, :value) in stories.entries)
    key: value.delta.toList().any(isPageNumberOperation)
        ? HeaderFooterStory(
            delta: _deltaOf([
              for (final line in _linesOf(value.delta))
                (
                  content: [
                    for (final operation in line.content)
                      if (!isPageNumberOperation(operation)) operation,
                  ],
                  attributes: line.attributes,
                ),
            ]),
            partPath: value.partPath,
            edited: true,
          )
        : value,
};

bool _isEmpty(_Line line) => line.content.every(
  (operation) =>
      operation.data is String && (operation.data as String).trim().isEmpty,
);

List<_Line> _linesOf(Delta delta) {
  final lines = <_Line>[];
  var content = <Operation>[];
  for (final operation in delta.toList()) {
    final data = operation.data;
    if (data is! String) {
      content.add(operation);
      continue;
    }
    var start = 0;
    while (true) {
      final newline = data.indexOf('\n', start);
      if (newline < 0) {
        if (start < data.length) {
          content.add(
            Operation.insert(data.substring(start), operation.attributes),
          );
        }
        break;
      }
      if (newline > start) {
        content.add(
          Operation.insert(
            data.substring(start, newline),
            operation.attributes,
          ),
        );
      }
      lines.add((content: content, attributes: operation.attributes));
      content = [];
      start = newline + 1;
    }
  }
  if (content.isNotEmpty) lines.add((content: content, attributes: null));
  return lines;
}

Delta _deltaOf(List<_Line> lines) {
  final delta = Delta();
  for (final line in lines) {
    for (final operation in line.content) {
      delta.push(operation);
    }
    delta.insert('\n', line.attributes);
  }
  if (delta.isEmpty) delta.insert('\n');
  return delta;
}
