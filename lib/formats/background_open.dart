import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../document/document_codec.dart';
import 'document_codecs.dart';

/// A file read as far as it can be away from the UI isolate.
typedef PreparedFile = ({
  DocumentFormat format,
  bool template,
  PreparedDocument document,
});

/// [prepareInBackground] of a file in the format [detectFormat] finds from
/// its [name] and content.
Future<PreparedFile> prepareFileInBackground(
  String name,
  Uint8List bytes, {
  required Duration timeLimit,
}) => _withProblems(
  () => runWithTimeLimit(_prepareFile, (name, bytes), timeLimit),
);

/// [DocumentCodecs.prepare] on another isolate. Failures are
/// [DocumentProblemException]s, as on the UI isolate; a file whose
/// preparation takes longer than [timeLimit] is refused as
/// [DocumentProblem.tooLarge], and one canceled with its [CancelScope]
/// throws [BackgroundWorkCanceled]. On the web, which has no isolates, it
/// runs here with no limit.
Future<PreparedDocument> prepareInBackground(
  DocumentFormat format,
  Uint8List bytes, {
  required Duration timeLimit,
}) =>
    _withProblems(() => runWithTimeLimit(_prepare, (format, bytes), timeLimit));

PreparedFile _prepareFile((String, Uint8List) file) {
  final (name, bytes) = file;
  final detected = detectFormat(name, bytes);
  if (detected == null) {
    throw DocumentProblemException(DocumentProblem.unsupportedFormat);
  }
  return (
    format: detected.format,
    template: detected.template,
    document: DocumentCodecs.prepare(detected.format, bytes),
  );
}

PreparedDocument _prepare((DocumentFormat, Uint8List) file) =>
    DocumentCodecs.prepare(file.$1, file.$2);

Future<T> _withProblems<T>(Future<T> Function() prepare) async {
  try {
    return await prepare();
  } on DocumentProblemException {
    rethrow;
  } on BackgroundWorkCanceled {
    rethrow;
  } on TimeoutException {
    throw DocumentProblemException(DocumentProblem.tooLarge);
  } catch (_) {
    // FormatException, and whatever else a hostile file trips.
    throw DocumentProblemException(DocumentProblem.damaged);
  }
}

/// Thrown by [runWithTimeLimit] when its [CancelScope] is canceled.
final class BackgroundWorkCanceled implements Exception {
  const BackgroundWorkCanceled();
}

/// Lets the user stop background work: [runWithTimeLimit] calls made inside
/// [run], however deep, kill their isolate as soon as [cancel] is called and
/// throw [BackgroundWorkCanceled]. The scope rides on the zone, so the code
/// between, such as the editor session, needn't pass it along.
final class CancelScope {
  final _canceled = Completer<void>();

  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_scopeKey: this});

  void cancel() {
    if (!_canceled.isCompleted) _canceled.complete();
  }

  static final _scopeKey = Object();

  static CancelScope? get _current => Zone.current[_scopeKey] as CancelScope?;
}

/// Runs [work] on [message] in a new isolate and returns or throws what it
/// does. Past [limit], or when the [CancelScope] it runs in is canceled, the
/// isolate is killed, whatever it is doing, and [TimeoutException] or
/// [BackgroundWorkCanceled] is thrown. [work] must be a top-level or static
/// function. On the web, which has no isolates, it runs here with no limit
/// and can't be canceled.
Future<R> runWithTimeLimit<M, R>(
  R Function(M message) work,
  M message,
  Duration limit,
) async {
  if (kIsWeb) return compute(work, message);
  final scope = CancelScope._current;
  final reply = Completer<Object?>();
  final port = RawReceivePort();
  port.handler = (Object? response) {
    port.close();
    reply.complete(response);
  };
  final Isolate isolate;
  try {
    isolate = await Isolate.spawn<_Task<M, R>>(
      _Task.run,
      _Task(port.sendPort, work, message),
      onExit: port.sendPort,
      debugName: 'background work',
    );
  } catch (_) {
    port.close();
    rethrow;
  }
  void stop(Object error) {
    isolate.kill(priority: Isolate.immediate);
    port.close();
    if (!reply.isCompleted) reply.completeError(error);
  }

  final timer = Timer(limit, () => stop(TimeoutException(null, limit)));
  scope?._canceled.future.then((_) => stop(const BackgroundWorkCanceled()));
  try {
    return switch (await reply.future) {
      [final result] => result as R,
      [final Object error, final StackTrace stack] => Error.throwWithStackTrace(
        error,
        stack,
      ),
      _ => throw RemoteError('The isolate ended without a result.', ''),
    };
  } finally {
    timer.cancel();
  }
}

/// What the new isolate runs: [run] is its entry point.
final class _Task<M, R> {
  const _Task(this.port, this.work, this.message);

  final SendPort port;
  final R Function(M message) work;
  final M message;

  static void run(_Task<Object?, Object?> task) => task._run();

  void _run() {
    final R result;
    try {
      result = work(message);
    } catch (error, stack) {
      Isolate.exit(port, [error, stack]);
    }
    Isolate.exit(port, [result]);
  }
}
