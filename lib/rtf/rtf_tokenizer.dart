import 'dart:math' as math;
import 'dart:typed_data';

enum RtfToken { groupStart, groupEnd, word, symbol, hex, text, binary, end }

/// Splits RTF into tokens; text and binary data are byte ranges of [bytes].
class RtfTokenizer {
  RtfTokenizer(this.bytes, {int start = 0}) : _position = start;

  final Uint8List bytes;
  int _position;

  /// The control word of a [RtfToken.word].
  String word = '';

  /// Its numeric parameter, when it has one.
  int? parameter;

  /// The character of a [RtfToken.symbol], or the byte of a [RtfToken.hex]
  /// (`\'hh`).
  int value = 0;

  /// The bytes of a [RtfToken.text] or [RtfToken.binary].
  int start = 0;
  int end = 0;

  static const _maxWordLength = 32;
  static const _maxParameter = 0x7FFFFFFF;

  RtfToken next() {
    while (_position < bytes.length) {
      switch (bytes[_position]) {
        case 0x7B:
          _position++;
          return RtfToken.groupStart;
        case 0x7D:
          _position++;
          return RtfToken.groupEnd;
        case 0x5C:
          return _control();
        case 0x0A || 0x0D:
          _position++;
        default:
          return _text();
      }
    }
    return RtfToken.end;
  }

  RtfToken _text() {
    start = _position;
    while (_position < bytes.length) {
      final byte = bytes[_position];
      if (byte == 0x7B ||
          byte == 0x7D ||
          byte == 0x5C ||
          byte == 0x0A ||
          byte == 0x0D) {
        break;
      }
      _position++;
    }
    end = _position;
    return RtfToken.text;
  }

  RtfToken _control() {
    _position++;
    if (_position >= bytes.length) return RtfToken.end;
    final first = bytes[_position];
    if (!_isLetter(first)) {
      _position++;
      if (first == 0x27) return _hex();
      value = first;
      return RtfToken.symbol;
    }
    final wordStart = _position;
    while (_position < bytes.length && _isLetter(bytes[_position])) {
      _position++;
    }
    word = String.fromCharCodes(
      bytes,
      wordStart,
      math.min(_position, wordStart + _maxWordLength),
    );
    parameter = _parameter();
    if (_position < bytes.length && bytes[_position] == 0x20) _position++;
    final length = parameter;
    if (word == 'bin' && length != null && length > 0) {
      start = _position;
      end = math.min(_position + length, bytes.length);
      _position = end;
      return RtfToken.binary;
    }
    return RtfToken.word;
  }

  int? _parameter() {
    var position = _position;
    final negative = position < bytes.length && bytes[position] == 0x2D;
    if (negative) position++;
    if (position >= bytes.length || !_isDigit(bytes[position])) return null;
    var number = 0;
    while (position < bytes.length && _isDigit(bytes[position])) {
      if (number < _maxParameter) {
        number = math.min(number * 10 + bytes[position] - 0x30, _maxParameter);
      }
      position++;
    }
    _position = position;
    return negative ? -number : number;
  }

  RtfToken _hex() {
    var number = 0;
    var digits = 0;
    while (digits < 2 && _position < bytes.length) {
      final digit = _hexDigit(bytes[_position]);
      if (digit < 0) break;
      number = number * 16 + digit;
      digits++;
      _position++;
    }
    if (digits == 0) {
      value = 0x27;
      return RtfToken.symbol;
    }
    value = number;
    return RtfToken.hex;
  }

  static bool _isLetter(int byte) =>
      (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A);

  static bool _isDigit(int byte) => byte >= 0x30 && byte <= 0x39;

  static int _hexDigit(int byte) {
    if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
    if (byte >= 0x61 && byte <= 0x66) return byte - 0x57;
    if (byte >= 0x41 && byte <= 0x46) return byte - 0x37;
    return -1;
  }
}
