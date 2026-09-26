import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'models.dart';

/// Newline-delimited JSON to a Herdr server over forwarded Unix sockets.
///
/// Herdr serves **one request per connection** and closes it after replying,
/// so every call opens its own forwarded channel. The exception is
/// `events.subscribe`, which keeps its connection open and streams events —
/// that one gets a dedicated long-lived channel via [subscribe].
class HerdrClient {
  final SSHClient _ssh;
  final String socketPath;
  int _nextId = 1;

  /// Herdr serves one request per connection, so every call needs its own SSH
  /// channel — and sshd's default MaxSessions is 10, shared with the event
  /// subscription, the transcript tail and the PTY reads. Left unbounded, a
  /// launch burst exhausts the limit and calls fail for no visible reason.
  static const _maxConcurrent = 3;
  static int _inFlight = 0;
  static final _waiting = <Completer<void>>[];

  HerdrClient(this._ssh, this.socketPath);

  static Future<void> _acquire() async {
    if (_inFlight < _maxConcurrent) {
      _inFlight++;
      return;
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    // Waiting forever would wedge the app behind one stuck call, but taking
    // the slot anyway removes the bound exactly when the link is struggling:
    // every queued caller times out, opens a channel, and sshd — which allows
    // ten sessions — starts refusing, which is read as a dead connection and
    // triggers a reconnect that replays the same burst. Give up instead; the
    // caller's own retry is the right place to decide what to do about it.
    try {
      await completer.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      _waiting.remove(completer);
      throw StateError('busy: all $_maxConcurrent channels are in use');
    }
  }

  /// Run a shell command on the host under the same bound as everything else.
  ///
  /// sshd allows ten sessions, and a shell command takes one just as an RPC
  /// call does.
  static Future<Uint8List> run(SSHClient ssh, String command,
      {Duration timeout = const Duration(seconds: 30)}) async {
    await _acquire();
    try {
      return await ssh.run(command).timeout(timeout);
    } finally {
      _release();
    }
  }

  /// Start a long-lived session (a tail) under the same bound.
  static Future<SSHSession> execute(SSHClient ssh, String command) async {
    await _acquire();
    try {
      return await ssh.execute(command).timeout(const Duration(seconds: 20));
    } finally {
      // A tail holds its channel for as long as it runs; counting it for the
      // life of the session would starve everything else. The bound here is
      // on opening, which is what sshd refuses.
      _release();
    }
  }

  static void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
      return;
    }
    _inFlight--;
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    await _acquire();
    try {
      return await _call(method, params);
    } finally {
      _release();
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params,
  ) async {
    // Opening the channel can hang when the session is half-dead, which is
    // what leaves a slot held and the app silent.
    final channel = await _ssh
        .forwardLocalUnix(socketPath)
        .timeout(const Duration(seconds: 12));
    final id = 'sh_${_nextId++}';
    final completer = Completer<Map<String, dynamic>>();
    final buffer = StringBuffer();
    late StreamSubscription sub;

    sub = channel.stream.listen(
      (data) {
        buffer.write(utf8.decode(data, allowMalformed: true));
        final text = buffer.toString();
        final nl = text.indexOf('\n');
        if (nl < 0 || completer.isCompleted) return;
        _complete(completer, text.substring(0, nl));
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (completer.isCompleted) return;
        // Some replies arrive without a trailing newline before close.
        final text = buffer.toString().trim();
        if (text.isEmpty) {
          completer.completeError(
              const HerdrError('closed', 'herdr closed without replying'));
        } else {
          _complete(completer, text);
        }
      },
    );

    channel.sink.add(utf8.encode(
        '${jsonEncode({'id': id, 'method': method, 'params': params})}\n'));

    try {
      return await completer.future.timeout(const Duration(seconds: 20));
    } finally {
      await sub.cancel();
      try {
        await channel.close();
      } catch (_) {}
    }
  }

  void _complete(Completer<Map<String, dynamic>> completer, String line) {
    try {
      final msg = jsonDecode(line.trim()) as Map<String, dynamic>;
      if (msg.containsKey('error')) {
        completer.completeError(HerdrError.fromJson(msg['error']));
      } else {
        completer.complete((msg['result'] as Map<String, dynamic>?) ?? {});
      }
    } catch (e) {
      completer.completeError(HerdrError('parse', '$e: $line'));
    }
  }

  Future<HostState> snapshot() async {
    final res = await call('session.snapshot');
    final snap = res['snapshot'] as Map<String, dynamic>?;
    if (snap == null) throw const HerdrError('snapshot', 'missing snapshot');
    return HostState.fromSnapshot(snap);
  }

  Future<void> focusPane(Pane pane) async {
    await call('workspace.focus', {'workspace_id': pane.workspaceId});
    await call('tab.focus', {'tab_id': pane.tabId});
    await call('pane.focus', {'pane_id': pane.paneId});
  }

  /// A null label clears it and lets Herdr fall back to its own naming.
  Future<void> renamePane(String paneId, String? label) => call(
        'pane.rename',
        {'pane_id': paneId, if (label != null) 'label': label},
      );

  Future<void> sendText(String paneId, String text) =>
      call('pane.send_input', {'pane_id': paneId, 'text': text});

  Future<void> sendKeys(String paneId, List<String> keys) =>
      call('pane.send_input', {'pane_id': paneId, 'keys': keys});

  /// `ReadSource` values use underscores over the socket; the CLI's
  /// `recent-unwrapped` spelling is rejected here.
  Future<String> readPane(
    String paneId, {
    String source = 'recent_unwrapped',
    int lines = 60,

    /// Keep the colours: some menus mark their selection with nothing else.
    bool ansi = false,
  }) async {
    final res = await call('pane.read', {
      'pane_id': paneId,
      'source': source,
      'lines': lines,
      'strip_ansi': !ansi,
    });
    return ((res['read'] as Map<String, dynamic>?)?['text'] as String?) ?? '';
  }

  /// Opens a connection that stays open and streams pushed events.
  ///
  /// Only global subscriptions are requested: the three per-pane kinds
  /// (`pane.agent_status_changed`, `pane.output_matched`,
  /// `pane.scroll_changed`) require a `pane_id` and would fail the call.
  Future<HerdrEventStream> subscribe() async {
    final channel = await _ssh.forwardLocalUnix(socketPath);
    final stream = HerdrEventStream(channel);
    channel.sink.add(utf8.encode('${jsonEncode({
          'id': 'sh_events',
          'method': 'events.subscribe',
          'params': {
            'subscriptions': const [
              {'type': 'workspace.created'},
              {'type': 'workspace.closed'},
              {'type': 'workspace.focused'},
              {'type': 'workspace.renamed'},
              {'type': 'tab.created'},
              {'type': 'tab.closed'},
              {'type': 'tab.focused'},
              {'type': 'pane.created'},
              {'type': 'pane.closed'},
              {'type': 'pane.updated'},
              {'type': 'pane.focused'},
              {'type': 'pane.exited'},
              {'type': 'pane.agent_detected'},
            ],
          },
        })}\n'));
    return stream;
  }
}

class HerdrEventStream {
  final SSHForwardChannel _channel;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  late final StreamSubscription _sub;
  String _buffer = '';

  HerdrEventStream(this._channel) {
    _sub = _channel.stream.listen(
      (data) {
        _buffer += utf8.decode(data, allowMalformed: true);
        while (true) {
          final nl = _buffer.indexOf('\n');
          if (nl < 0) break;
          final line = _buffer.substring(0, nl).trim();
          _buffer = _buffer.substring(nl + 1);
          if (line.isEmpty) continue;
          try {
            final msg = jsonDecode(line);
            if (msg is Map<String, dynamic>) _controller.add(msg);
          } catch (_) {}
        }
      },
      onError: (_) {},
      onDone: () {
        if (!_controller.isClosed) _controller.close();
      },
    );
  }

  Stream<Map<String, dynamic>> get events => _controller.stream;

  Future<void> close() async {
    await _sub.cancel();
    try {
      await _channel.close();
    } catch (_) {}
    if (!_controller.isClosed) await _controller.close();
  }
}

class HerdrError implements Exception {
  final String code;
  final String message;

  const HerdrError(this.code, this.message);

  factory HerdrError.fromJson(dynamic e) {
    if (e is Map) {
      return HerdrError(
        (e['code'] as String?) ?? 'error',
        (e['message'] as String?) ?? e.toString(),
      );
    }
    return HerdrError('error', e.toString());
  }

  @override
  String toString() => '$code: $message';
}
