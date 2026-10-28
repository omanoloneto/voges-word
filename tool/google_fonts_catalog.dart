// Gera assets/fonts/google_fonts.txt a partir do código do pacote google_fonts.
//
// Uso: dart run tool/google_fonts_catalog.dart <pasta lib/src/google_fonts_parts>
import 'dart:io';

final _family = RegExp(
  r'/// Applies the (.+) font family from Google Fonts to the\n',
);
final _variant = RegExp(
  r"fontWeight: FontWeight\.w(\d)00,\s*fontStyle: FontStyle\.(normal|italic),\s*\): GoogleFontsFile\(\s*'([0-9a-f]{64})'",
);

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'Uso: dart run tool/google_fonts_catalog.dart <google_fonts_parts>',
    );
    exit(64);
  }
  final families = <String, List<String>>{};
  final parts =
      Directory(arguments.single)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final part in parts) {
    final source = part.readAsStringSync();
    final starts = _family.allMatches(source).toList();
    for (var i = 0; i < starts.length; i++) {
      final end = i + 1 < starts.length ? starts[i + 1].start : source.length;
      final block = source.substring(starts[i].end, end);
      final variants = <(int, bool), String>{
        for (final match in _variant.allMatches(block))
          (int.parse(match[1]!) * 100, match[2] == 'italic'): match[3]!,
      };
      final files = _documentFaces(variants);
      if (files.isNotEmpty) families[starts[i][1]!] = files;
    }
  }
  final names = families.keys.toList()..sort();
  final output = File('assets/fonts/google_fonts.txt')
    ..writeAsStringSync(
      names.map((name) => '$name\t${families[name]!.join(' ')}\n').join(),
    );
  stdout.writeln('${names.length} famílias em ${output.path}');
}

/// Até quatro arquivos: normal e itálico, perto do peso 400 e do 700.
List<String> _documentFaces(Map<(int, bool), String> variants) {
  String? pick(int target, bool italic, {int minimum = 0}) {
    final candidates = variants.keys
        .where((key) => key.$2 == italic && key.$1 >= minimum)
        .toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final distance = (a.$1 - target).abs().compareTo((b.$1 - target).abs());
      return distance != 0 ? distance : b.$1.compareTo(a.$1);
    });
    return variants[candidates.first];
  }

  return {
    pick(400, false) ?? pick(400, true),
    pick(700, false, minimum: 600),
    pick(400, true),
    pick(700, true, minimum: 600),
  }.nonNulls.toList();
}
