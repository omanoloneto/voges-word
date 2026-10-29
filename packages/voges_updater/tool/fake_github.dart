/// A stand-in for github.com on this computer: one release of one
/// repository, with its checksums and their signature, as the updater reads
/// them. The tests and the end-to-end checks import it; it also runs alone:
///
///     dart run tool/fake_github.dart init-key --key-file <path>
///     dart run tool/fake_github.dart serve --port <p> --repository <owner/repo>
///         --tag <vX.Y.Z> --key-file <path> [--tamper] [--no-signature]
///         <asset files...>
///
/// `init-key` writes a random test key and prints its public key, for the
/// `VOGES_UPDATE_TEST_KEY` define of a test build.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import 'release_signing.dart' show publicKeyOf, signChecksums;

Future<void> main(List<String> arguments) async {
  try {
    switch (arguments) {
      case ['init-key', '--key-file', final path]:
        stdout.writeln(await _initKey(File(path)));
      case ['serve', ...final options]:
        await _serve(options);
      default:
        throw const _UsageError(_usage);
    }
  } on _UsageError catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

class FakeGitHub {
  FakeGitHub._(this._server, this._repository, this._version, this._files);

  /// Serves [version] of [repository] with [assets] (release name to file),
  /// its `SHA256SUMS.txt`, and the signature of the sums made with [seed].
  /// [tamper] serves the assets with altered bytes; [unsigned] serves no
  /// signature.
  static Future<FakeGitHub> start({
    required String repository,
    required ReleaseVersion version,
    required Map<String, File> assets,
    required List<int> seed,
    bool tamper = false,
    bool unsigned = false,
    int port = 0,
  }) async {
    final files = <String, Uint8List>{};
    final sums = StringBuffer();
    for (final MapEntry(key: name, value: file) in assets.entries) {
      final bytes = await file.readAsBytes();
      sums.write('${crypto.sha256.convert(bytes)}  $name\n');
      files[name] = tamper ? _tampered(bytes) : bytes;
    }
    final checksums = utf8.encode('$sums');
    files[checksumsAsset] = checksums;
    if (!unsigned) {
      files[signatureAsset] = await signChecksums(
        seed: seed,
        repository: repository,
        version: version,
        checksums: checksums,
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final fake = FakeGitHub._(server, repository, version, files);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  final String _repository;
  final ReleaseVersion _version;
  final Map<String, Uint8List> _files;

  /// `http://127.0.0.1:<port>`, the origin for `VOGES_UPDATE_TEST_ORIGIN`.
  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    final releases = '/$_repository/releases';
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
    } else if (path == '$releases/latest') {
      _redirect(response, '$releases/tag/${_version.tag}');
    } else if (_fileAt(path, '$releases/download/${_version.tag}/')
        case final name?) {
      // like GitHub, the files themselves come from another address
      _redirect(response, '/files/$name');
    } else if (_fileAt(path, '/files/') case final name?) {
      final bytes = _files[name]!;
      response.headers.contentType = ContentType.binary;
      response.contentLength = bytes.length;
      if (request.method == 'GET') response.add(bytes);
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  /// The name of the file served at [path] below [prefix], or null.
  String? _fileAt(String path, String prefix) {
    if (!path.startsWith(prefix)) return null;
    final name = path.substring(prefix.length);
    return _files.containsKey(name) ? name : null;
  }

  void _redirect(HttpResponse response, String path) {
    response.statusCode = HttpStatus.found;
    response.headers.set(HttpHeaders.locationHeader, '$origin$path');
  }

  static Uint8List _tampered(Uint8List bytes) {
    if (bytes.isEmpty) return Uint8List.fromList([0]);
    return Uint8List.fromList(bytes)..[0] ^= 0xff;
  }
}

const _usage =
    'Usage:\n'
    '  dart run tool/fake_github.dart init-key --key-file <path>\n'
    '  dart run tool/fake_github.dart serve --port <p> '
    '--repository <owner/repo> --tag <vX.Y.Z> --key-file <path> '
    '[--tamper] [--no-signature] <asset files...>';

final class _UsageError implements Exception {
  const _UsageError(this.message);

  final String message;
}

/// Writes a new random seed to [file], readable only by this user, and
/// returns its public key.
Future<String> _initKey(File file) async {
  final random = Random.secure();
  final seed = [for (var i = 0; i < 32; i++) random.nextInt(256)];
  // exclusive: never overwrite a key, nor write through a planted link
  await file.create(exclusive: true);
  if (!Platform.isWindows) {
    final chmod = await Process.run('/bin/chmod', ['600', file.path]);
    if (chmod.exitCode != 0) {
      await file.delete();
      throw FileSystemException('chmod failed: ${chmod.stderr}', file.path);
    }
  }
  await file.writeAsBytes(seed, flush: true);
  return publicKeyOf(seed);
}

Future<void> _serve(List<String> arguments) async {
  final options = <String, String>{};
  final flags = <String>{};
  final assets = <String, File>{};
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--port' || '--repository' || '--tag' || '--key-file':
        if (i + 1 == arguments.length) {
          throw _UsageError('${arguments[i]} needs a value.');
        }
        options[arguments[i]] = arguments[++i];
      case '--tamper' || '--no-signature':
        flags.add(arguments[i]);
      case final option when option.startsWith('-'):
        throw _UsageError('Unknown option $option.');
      case final path:
        final name = p.basename(path);
        if (!_assetName.hasMatch(name) || assets.containsKey(name)) {
          throw _UsageError('$name is not a unique release file name.');
        }
        assets[name] = File(path);
    }
  }
  final port = int.tryParse(options['--port'] ?? '');
  final repository = options['--repository'] ?? '';
  final version = ReleaseVersion.tryParseTag(options['--tag'] ?? '');
  final keyFile = options['--key-file'];
  if (port == null ||
      port < 0 ||
      port > 65535 ||
      !_repository.hasMatch(repository) ||
      version == null ||
      keyFile == null ||
      assets.isEmpty) {
    throw const _UsageError(_usage);
  }
  final seed = await File(keyFile).readAsBytes();
  if (seed.length != 32) {
    throw FileSystemException('Not a 32-byte key', keyFile);
  }

  final fake = await FakeGitHub.start(
    repository: repository,
    version: version,
    assets: assets,
    seed: seed,
    tamper: flags.contains('--tamper'),
    unsigned: flags.contains('--no-signature'),
    port: port,
  );
  stdout.writeln(
    'Fake GitHub at ${fake.origin}: $repository ${version.tag} with '
    '${assets.keys.join(', ')}. Ctrl+C stops it.',
  );
  await Future.any([
    ProcessSignal.sigint.watch().first,
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().first,
  ]);
  await fake.close();
  exit(0);
}

final _assetName = RegExp(r'^[A-Za-z0-9._-]+$');
final _repository = RegExp(r'^[A-Za-z0-9-]+/[A-Za-z0-9_][A-Za-z0-9._-]*$');
