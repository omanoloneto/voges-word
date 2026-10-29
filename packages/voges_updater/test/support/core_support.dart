import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The Dart SDK that `flutter test` runs on, for tests that need a second
/// process.
String dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) throw StateError('Run the tests with flutter test');
  return p.join(
    root,
    'bin',
    'cache',
    'dart-sdk',
    'bin',
    Platform.isWindows ? 'dart.exe' : 'dart',
  );
}

/// A new folder that is deleted when the test ends.
Directory temporaryFolder() {
  final folder = Directory.systemTemp.createTempSync('voges-updater-test-');
  addTearDown(() => folder.delete(recursive: true));
  return folder;
}

/// What a [LoopbackServer] answers to one address.
typedef Answer = FutureOr<void> Function(HttpResponse response);

Answer redirectTo(String location, {int status = HttpStatus.found}) =>
    (response) {
      response.statusCode = status;
      response.headers.set(HttpHeaders.locationHeader, location);
    };

/// [body] with its Content-Length, or chunked without one.
Answer bytes(List<int> body, {bool chunked = false}) => (response) {
  if (!chunked) response.contentLength = body.length;
  response.add(body);
};

Answer status(int code) =>
    (response) => response.statusCode = code;

/// Sends [first] of a longer body, then nothing more.
Answer stall(List<int> first, {required int contentLength}) =>
    (response) async {
      response.contentLength = contentLength;
      response.add(first);
      await response.flush();
      await Completer<void>().future;
    };

/// An HTTP server on this computer that answers from [routes], keyed by host
/// and path, such as `github.com/owner/repo/releases/latest`.
final class LoopbackServer {
  LoopbackServer._(this._server);

  static Future<LoopbackServer> start() async {
    final server = LoopbackServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(server._serve);
    addTearDown(() => server._server.close(force: true));
    return server;
  }

  final HttpServer _server;

  Map<String, Answer> routes = {};

  /// `METHOD host/path` of every request, in order.
  final requests = <String>[];

  final userAgents = <String?>{};

  int get port => _server.port;

  /// `http://127.0.0.1:<port>`.
  Uri get origin => Uri.parse('http://127.0.0.1:$port');

  /// A client that sends every request here whatever its scheme and host, so
  /// the production rules for github.com are tested without TLS.
  HttpClient routedClient() =>
      HttpClient()
        ..connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, port);

  Future<void> _serve(HttpRequest request) async {
    final address = '${request.headers.host}${request.uri.path}';
    requests.add('${request.method} $address');
    userAgents.add(request.headers.value(HttpHeaders.userAgentHeader));
    final answer = routes[address];
    if (answer == null) {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      await answer(request.response);
    }
    await request.response.close();
  }
}
