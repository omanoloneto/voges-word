import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'release_trust.dart';
import 'release_verifier.dart';
import 'update_failure.dart';
import 'updater_lock.dart';

/// Tells which apps the suite has. Never fails: when nothing better is
/// known, they are the apps of the build.
abstract interface class SuiteSource {
  Future<List<SuiteApp>> apps();
}

/// Always the same apps: those compiled into this build, unless told
/// otherwise.
final class FixedSuite implements SuiteSource {
  const FixedSuite([this._apps = vogesSuite]);

  final List<SuiteApp> _apps;

  @override
  Future<List<SuiteApp>> apps() async => _apps;
}

/// The apps compiled into this build, plus those of the signed list that
/// the website publishes, so an installed app offers a suite app that came
/// after it.
///
/// A list is used only with a valid signature of the release key, and never
/// when this computer remembers a newer one. Without one that passes, the
/// suite is the one of the build. Only called while holding the updater
/// lock, which also guards the copy kept in [cache].
final class PublishedSuite implements SuiteSource {
  PublishedSuite({
    required this.verifier,
    required this.cache,
    Uri? url,
    this.builtIn = vogesSuite,
    this.connectTimeout = const Duration(seconds: 5),
    this.timeout = const Duration(seconds: 8),
    this.diskTimeout = const Duration(seconds: 2),
  }) : url = url ?? Uri.parse(address);

  /// The list of the website, or of the loopback origin in a test build.
  factory PublishedSuite.production({required ReleaseVerifier verifier}) =>
      PublishedSuite(
        verifier: verifier,
        cache: () => UpdaterLock.defaultDirectory(
          Platform.operatingSystem,
          Platform.environment,
        ),
        url: testOrigin?.resolve('/voges/suite.json'),
      );

  final ReleaseVerifier verifier;

  /// The Voges cache folder, where the newest list seen is kept. Asked for
  /// on every call: holding the updater lock is what proves it resolves.
  final Directory Function() cache;

  final Uri url;
  final List<SuiteApp> builtIn;

  /// The longest the whole download may take: the list only adds apps, so
  /// a slow website must not hold the updates back.
  final Duration timeout;

  final Duration connectTimeout;

  /// The longest reading or writing the kept list may take: what sits in
  /// its place may not be a file, and would never answer.
  final Duration diskTimeout;

  /// Where the website publishes the list, next to its `.sig`.
  static const address = 'https://omanoloneto.pro/voges/suite.json';

  static const userAgent = 'Voges-Updater';

  /// Size limits, in bytes: anything larger is not the suite list.
  static const listLimit = 64 * 1024;
  static const signatureLimit = 1024;

  /// The kept list: the signature in its first line and the list after it,
  /// in one file so that neither is ever there without the other.
  static const _keptFile = 'suite.signed';

  static const _newline = 0x0A;

  @override
  Future<List<SuiteApp>> apps() async {
    final Directory folder;
    try {
      folder = cache();
    } on StateError {
      // without a place to remember the newest list, an old one could be
      // replayed
      return builtIn;
    }
    final kept = await _accept(await _readKept(folder));
    final published = await _accept(await _download());
    // only a newer list takes the place of the kept one, so two lists
    // signed with the same serial can't take turns
    if (published == null || published.serial <= (kept?.serial ?? 0)) {
      return kept?.apps ?? builtIn;
    }
    await _keep(folder, published);
    return published.apps;
  }

  /// The suite that [files] stand for; null unless they are a signed list
  /// that agrees with the apps of the build.
  Future<_Accepted?> _accept(_Files? files) async {
    if (files == null) return null;
    try {
      final list = await verifier.verifySuiteList(
        list: files.list,
        signature: files.signature,
      );
      return _Accepted(list.serial, list.mergedInto(builtIn), files);
    } on UpdateFailure {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<_Files?> _download() async {
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..userAgent = userAgent;
    try {
      return await _fetchBoth(client).timeout(timeout);
    } on Exception {
      // whatever is wrong with the website, the updates do not depend on it
      return null;
    } finally {
      // also drops a request that the time limit left under way
      client.close(force: true);
    }
  }

  Future<_Files?> _fetchBoth(HttpClient client) async {
    final list = await _fetch(client, url, listLimit);
    if (list == null) return null;
    final signature = await _fetch(
      client,
      url.replace(path: '${url.path}.sig'),
      signatureLimit,
    );
    return signature == null ? null : _Files(list, signature);
  }

  /// The body of [address]; null unless the answer is a 200 of at most
  /// [maxBytes]. A redirect is never followed.
  Future<Uint8List?> _fetch(
    HttpClient client,
    Uri address,
    int maxBytes,
  ) async {
    final request = await client.getUrl(address);
    request.followRedirects = false;
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > maxBytes) {
      await response.listen(null).cancel();
      return null;
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (body.length + chunk.length > maxBytes) return null;
      body.add(chunk);
    }
    return body.takeBytes();
  }

  Future<_Files?> _readKept(Directory folder) async {
    try {
      return await _read(
        File(p.join(folder.path, _keptFile)),
      ).timeout(diskTimeout);
    } on Exception {
      // missing, unreadable or silent, it is a list never seen
      return null;
    }
  }

  Future<_Files?> _read(File file) async {
    if (await file.length() > signatureLimit + listLimit) return null;
    final bytes = await file.readAsBytes();
    final end = bytes.indexOf(_newline);
    if (end < 0) return null;
    return _Files(
      Uint8List.sublistView(bytes, end + 1),
      Uint8List.sublistView(bytes, 0, end),
    );
  }

  /// Keeps [accepted] as the newest list seen. A copy that cannot be
  /// written only loses that memory, so the failure is not reported.
  Future<void> _keep(Directory folder, _Accepted accepted) async {
    final _Files(:list, :signature) = accepted.files;
    final bytes = Uint8List.fromList([
      ...signature,
      if (signature.last != _newline) _newline,
      ...list,
    ]);
    try {
      await _replace(folder, bytes).timeout(diskTimeout);
    } on Exception {
      // nothing else to do
    }
  }

  /// Writes through a temporary file, so a crash never leaves half a file.
  Future<void> _replace(Directory folder, Uint8List bytes) async {
    await folder.create(recursive: true);
    final temporary = File(p.join(folder.path, '$_keptFile.new'));
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(p.join(folder.path, _keptFile));
  }
}

final class _Files {
  const _Files(this.list, this.signature);

  final Uint8List list;
  final Uint8List signature;
}

final class _Accepted {
  const _Accepted(this.serial, this.apps, this.files);

  final int serial;
  final List<SuiteApp> apps;
  final _Files files;
}
