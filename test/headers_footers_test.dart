import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/header_footer_painter.dart';
import 'package:voges_word/editor/page_numbers.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const _gif = 'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a page number at the top goes into the file and comes back as a field',
    () {
      final codec = DocxCodec(TableStore());
      final blank = codec.createEmpty();
      final stories = withPageNumber(
        blank.headersFooters,
        PageNumberPosition.topRight,
      ).copyWith(differentFirstPage: true);

      final bytes = codec.encode(
        Delta()..insert('Texto\n'),
        source: blank.source,
        headersFooters: stories,
      );
      final package = DocxPackage.decode(bytes);
      final document = package.text('word/document.xml')!;
      expect(document, contains('<w:headerReference w:type="default"'));
      expect(document, contains('<w:titlePg/>'));
      expect(
        package.text('[Content_Types].xml'),
        contains('/word/header1.xml'),
      );
      expect(package.text('word/header1.xml'), contains(' PAGE '));

      final reopened = codec.decode(bytes).headersFooters;
      expect(reopened.differentFirstPage, isTrue);
      expect(pageNumberPosition(reopened), PageNumberPosition.topRight);
      expect(
        reopened.headers[PageVariant.normal]?.partPath,
        'word/header1.xml',
      );
    },
  );

  test(
    'moving the number to the footer takes it off the header; removing clears both',
    () {
      const empty = HeadersFooters();
      final top = withPageNumber(empty, PageNumberPosition.topCenter);
      final bottom = withPageNumber(top, PageNumberPosition.bottomRight);

      expect(pageNumberPosition(bottom), PageNumberPosition.bottomRight);
      final header = bottom.headers[PageVariant.normal]!.delta.toList();
      expect(header.any(isPageNumberOperation), isFalse);
      expect(pageNumberPosition(withoutPageNumbers(bottom)), isNull);
    },
  );

  test(
    'only the edited header is rewritten; the others come back unchanged',
    () {
      final codec = DocxCodec(TableStore());
      final blank = codec.createEmpty();
      HeaderFooterStory story(String text) =>
          HeaderFooterStory(delta: Delta()..insert('$text\n'), edited: true);
      final first = codec.encode(
        Delta()..insert('Texto\n'),
        source: blank.source,
        headersFooters: blank.headersFooters.copyWith(
          headers: {PageVariant.normal: story('Header')},
          footers: {PageVariant.normal: story('Footer')},
        ),
      );
      final loaded = codec.decode(first);
      final footerPath =
          loaded.headersFooters.footers[PageVariant.normal]!.partPath!;
      final footerBefore = DocxPackage.decode(first).parts[footerPath];

      final header = loaded.headersFooters.headers[PageVariant.normal]!;
      final second = codec.encode(
        loaded.delta,
        source: loaded.source,
        headersFooters: loaded.headersFooters.copyWith(
          headers: {
            PageVariant.normal: HeaderFooterStory(
              delta: Delta()..insert('New header\n'),
              partPath: header.partPath,
              edited: true,
            ),
          },
        ),
      );
      final package = DocxPackage.decode(second);
      expect(package.parts[footerPath], footerBefore);
      expect(package.text(header.partPath!), contains('New header'));
      expect(
        RegExp(
          'headerReference',
        ).allMatches(package.text('word/document.xml')!),
        hasLength(1),
      );
    },
  );

  test('a new picture does not overwrite one from an earlier save', () {
    final codec = DocxCodec(TableStore());
    final blank = codec.createEmpty();
    final first = codec.encode(
      Delta()
        ..insert({EmbedTypes.image: 'data:image/png;base64,$_png'})
        ..insert('\n'),
      source: blank.source,
    );
    final loaded = codec.decode(first);
    final second = codec.encode(
      loaded.delta.concat(
        Delta()
          ..insert({EmbedTypes.image: 'data:image/gif;base64,$_gif'})
          ..insert('\n'),
      ),
      source: loaded.source,
    );

    final images = codec
        .decode(second)
        .delta
        .toList()
        .map((op) => op.data)
        .whereType<Map>()
        .map((data) => data[EmbedTypes.image] as String?)
        .nonNulls
        .toList();
    expect(images, hasLength(2));
    expect(images.first, contains(_png));
    expect(images.last, contains(_gif));
  });

  test('a tall header pushes the text down, as in Word', () {
    final codec = DocxCodec(TableStore());
    final look = codec.createEmpty().look;
    final lines = List.generate(8, (i) => 'Linha $i\n').join();
    final painter = HeaderFooterPainter(
      HeadersFooters(
        headers: {
          PageVariant.normal: HeaderFooterStory(delta: Delta()..insert(lines)),
        },
      ),
      look,
    );
    addTearDown(painter.dispose);

    expect(painter.headerBottom, greaterThan(look.margins.top));
    expect(painter.footerTop, 0);
  });

  test('reads PAGE fields of headers that came from Word', () {
    final xml =
        '<w:fldSimple xmlns:w="w" w:instr=" PAGE   \\* MERGEFORMAT"><w:r><w:t>3</w:t></w:r></w:fldSimple>';
    expect(fieldNameOf(xml), 'PAGE');
    expect(
      fieldNameOf(
        '<w:r><w:instrText xml:space="preserve"> NUMPAGES </w:instrText></w:r>',
      ),
      'NUMPAGES',
    );
  });
}
