// Generates assets/fonts/google_fonts.txt from the code of the google_fonts
// package and the popularity published on fonts.google.com.
//
// Usage: dart run tool/google_fonts_catalog.dart <lib/src/google_fonts_parts folder>
import 'dart:convert';
import 'dart:io';

/// The default list holds a third of the catalog: the most popular fonts that
/// support Portuguese. The others only show up in search, to be added.
const _listedShare = 3;

/// Made for another script: CJK (huge files) and the Noto fonts for each
/// alphabet stay out of the default list even though they have Latin letters.
const _cjk = {'Jpan', 'Kore', 'Hans', 'Hant', 'Hira'};

final _family = RegExp(
  r'/// Applies the (.+) font family from Google Fonts to the\n',
);
final _variant = RegExp(
  r"fontWeight: FontWeight\.w(\d)00,\s*fontStyle: FontStyle\.(normal|italic),\s*\): GoogleFontsFile\(\s*'([0-9a-f]{64})'",
);

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/google_fonts_catalog.dart <google_fonts_parts>',
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

  final popularity = await _popularity();
  final ranked =
      families.keys.where((name) => popularity[name]?.latin ?? false).toList()
        ..sort((a, b) {
          final rank = popularity[a]!.rank.compareTo(popularity[b]!.rank);
          return rank != 0 ? rank : a.compareTo(b);
        });
  final listed = ranked.take((families.length / _listedShare).round()).toSet();

  final names = families.keys.toList()..sort();
  final output = File('assets/fonts/google_fonts.txt')
    ..writeAsStringSync(
      names
          .map(
            (name) =>
                '$name\t${families[name]!.join(' ')}\t'
                '${listed.contains(name) ? 1 : 0}\n',
          )
          .join(),
    );
  stdout.writeln(
    '${names.length} families, ${listed.length} listed, in ${output.path}',
  );
}

Future<Map<String, ({int rank, bool latin})>> _popularity() async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.https('fonts.google.com', '/metadata/fonts'),
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body.substring(body.indexOf('{'))) as Map;
    return {
      for (final entry in json['familyMetadataList'] as List)
        entry['family'] as String: (
          rank: entry['popularity'] as int,
          latin: _writesPortuguese(entry as Map),
        ),
    };
  } finally {
    client.close();
  }
}

bool _writesPortuguese(Map entry) {
  final script = entry['primaryScript'] as String? ?? '';
  final otherScript = script.isNotEmpty && script != 'Latn';
  return (entry['subsets'] as List).contains('latin') &&
      !(otherScript && (_cjk.contains(script) || entry['isNoto'] == true));
}

/// Up to four files: regular and italic, near weight 400 and 700.
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
