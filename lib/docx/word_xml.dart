import 'package:xml/xml.dart';

abstract final class Namespaces {
  static const w =
      'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  static const r =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const wp =
      'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
  static const a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
  static const pic = 'http://schemas.openxmlformats.org/drawingml/2006/picture';
  static const m = 'http://schemas.openxmlformats.org/officeDocument/2006/math';
  static const packageRelationships =
      'http://schemas.openxmlformats.org/package/2006/relationships';
  static const contentTypes =
      'http://schemas.openxmlformats.org/package/2006/content-types';

  static const known = <String, String>{
    'w': w,
    'r': r,
    'wp': wp,
    'a': a,
    'pic': pic,
    'm': m,
    'mc': 'http://schemas.openxmlformats.org/markup-compatibility/2006',
    'v': 'urn:schemas-microsoft-com:vml',
    'o': 'urn:schemas-microsoft-com:office:office',
    'w10': 'urn:schemas-microsoft-com:office:word',
    'w14': 'http://schemas.microsoft.com/office/word/2010/wordml',
    'w15': 'http://schemas.microsoft.com/office/word/2012/wordml',
    'w16': 'http://schemas.microsoft.com/office/word/2018/wordml',
    'w16cex': 'http://schemas.microsoft.com/office/word/2018/wordml/cex',
    'w16cid': 'http://schemas.microsoft.com/office/word/2016/wordml/cid',
    'w16se': 'http://schemas.microsoft.com/office/word/2015/wordml/symex',
    'w16sdtdh':
        'http://schemas.microsoft.com/office/word/2020/wordml/sdtdatahash',
    'w16du': 'http://schemas.microsoft.com/office/word/2023/wordml/word16du',
    'wp14':
        'http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing',
    'wpc': 'http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas',
    'wpg': 'http://schemas.microsoft.com/office/word/2010/wordprocessingGroup',
    'wpi': 'http://schemas.microsoft.com/office/word/2010/wordprocessingInk',
    'wne': 'http://schemas.microsoft.com/office/word/2006/wordml',
    'wps': 'http://schemas.microsoft.com/office/word/2010/wordprocessingShape',
  };
}

/// Resolve nomes com namespace usando as declarações da raiz da parte.
class WordXml {
  WordXml(XmlElement root) {
    for (final attribute in root.attributes) {
      if (attribute.name.prefix == 'xmlns') {
        _prefixes[attribute.name.local] = attribute.value;
      } else if (attribute.name.qualified == 'xmlns') {
        _prefixes[null] = attribute.value;
      }
    }
  }

  final _prefixes = <String?, String>{};

  String? namespaceOf(XmlName name) =>
      _prefixes[name.prefix] ?? name.namespaceUri;

  bool isW(XmlElement element, String local) =>
      element.name.local == local && namespaceOf(element.name) == Namespaces.w;

  bool isIn(XmlElement element, String namespace) =>
      namespaceOf(element.name) == namespace;

  XmlElement? child(XmlElement? parent, String local) {
    if (parent == null) return null;
    for (final element in parent.childElements) {
      if (isW(element, local)) return element;
    }
    return null;
  }

  Iterable<XmlElement> children(XmlElement parent, String local) =>
      parent.childElements.where((element) => isW(element, local));

  String? attr(XmlElement? element, String local) =>
      _attribute(element, local, Namespaces.w);

  String? relAttr(XmlElement? element, String local) =>
      _attribute(element, local, Namespaces.r);

  String? val(XmlElement? element) => attr(element, 'val');

  String? childVal(XmlElement? parent, String local) =>
      val(child(parent, local));

  /// Propriedade liga/desliga do OOXML: presente sem valor significa ligada.
  bool? onOff(XmlElement? element) {
    if (element == null) return null;
    final value = val(element);
    return value == null ||
        !const {'0', 'false', 'off', 'none'}.contains(value);
  }

  String? _attribute(XmlElement? element, String local, String namespace) {
    if (element == null) return null;
    for (final attribute in element.attributes) {
      if (attribute.name.local == local &&
          namespaceOf(attribute.name) == namespace) {
        return attribute.value;
      }
    }
    return null;
  }
}

String escapeXmlText(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String escapeXmlAttribute(String text) =>
    escapeXmlText(text).replaceAll('"', '&quot;');

final _invalidXmlChars = RegExp(
  r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]',
);

String stripInvalidXmlChars(String text) =>
    text.replaceAll(_invalidXmlChars, '');

/// Ordem exigida pelo schema dentro de w:pPr.
const paragraphPropertyOrder = [
  'pStyle',
  'keepNext',
  'keepLines',
  'pageBreakBefore',
  'framePr',
  'widowControl',
  'numPr',
  'suppressLineNumbers',
  'pBdr',
  'shd',
  'tabs',
  'suppressAutoHyphens',
  'kinsoku',
  'wordWrap',
  'overflowPunct',
  'topLinePunct',
  'autoSpaceDE',
  'autoSpaceDN',
  'bidi',
  'adjustRightInd',
  'snapToGrid',
  'spacing',
  'ind',
  'contextualSpacing',
  'mirrorIndents',
  'suppressOverlap',
  'jc',
  'textDirection',
  'textAlignment',
  'textboxTightWrap',
  'outlineLvl',
  'divId',
  'cnfStyle',
  'rPr',
  'sectPr',
  'pPrChange',
];

/// Ordem exigida pelo schema dentro de w:rPr.
const runPropertyOrder = [
  'rStyle',
  'rFonts',
  'b',
  'bCs',
  'i',
  'iCs',
  'caps',
  'smallCaps',
  'strike',
  'dstrike',
  'outline',
  'shadow',
  'emboss',
  'imprint',
  'noProof',
  'snapToGrid',
  'vanish',
  'webHidden',
  'color',
  'spacing',
  'w',
  'kern',
  'position',
  'sz',
  'szCs',
  'highlight',
  'u',
  'effect',
  'bdr',
  'shd',
  'fitText',
  'vertAlign',
  'rtl',
  'cs',
  'em',
  'lang',
  'eastAsianLayout',
  'specVanish',
  'oMath',
  'rPrChange',
];

/// Ordena filhos de propriedades; elementos de extensões (w14 etc.) vão para o
/// fim, como o Word grava.
List<XmlElement> sortProperties(List<XmlElement> elements, List<String> order) {
  int rank(XmlElement element) {
    final prefix = element.name.prefix;
    if (prefix != null && prefix != 'w') return order.length - 1;
    final index = order.indexOf(element.name.local);
    return index < 0 ? order.length - 1 : index;
  }

  final indexed = elements.indexed.toList()
    ..sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return [for (final entry in indexed) entry.$2];
}

/// Faz o parse de um fragmento guardado (prefixos sem declaração são aceitos).
XmlElement parseFragment(String xml) => XmlDocument.parse(xml).rootElement;
