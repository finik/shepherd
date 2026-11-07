import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'client.dart';
import 'core_client.dart';
import 'models.dart';

/// What the app asks of whatever runs the terminals on a host: the Herdr
/// server, or herdr-core.
abstract class HostClient {
  /// "herdr" or "herdr-core", and its version, for Settings to show.
  Future<String> ping();

  Future<HostState> snapshot();

  /// Notifications that something changed. Each one only says to look again.
  Future<HostEvents> subscribe();

  /// Bring the pane forward on the desktop, where that means anything.
  Future<void> focusPane(Pane pane);

  /// A null label goes back to the host's own naming.
  Future<void> renamePane(String paneId, String? label);

  /// Type [text] into the pane and press Enter.
  Future<void> submit(String paneId, String text);

  Future<void> sendKeys(String paneId, List<String> keys);

  /// A new place to work in [cwd], with a shell in it running [command].
  /// Returns the pane id.
  Future<String?> startAgent(String cwd, String command, {String? label});

  /// The agent running in the pane; null once it has exited to the shell.
  Future<String?> paneAgent(String paneId);

  /// Ends the pane, and the agent running in it.
  Future<void> closePane(String paneId);

  /// The screen of the pane as text, and [lines] above it.
  Future<String> readPane(String paneId,
      {String source = 'recent_unwrapped', int lines = 60, bool ansi = false});

  Future<void> close();

  /// herdr-core when the host has it, else the Herdr server at [socketPath].
  /// A host can have both while agents move from one to the other; the core
  /// is where new work goes.
  static Future<HostClient> open(SSHClient ssh, String socketPath) async {
    final core = await CoreClient.connect(ssh);
    if (core != null) return core;
    return HerdrClient(ssh, socketPath);
  }
}

/// A stream of change notifications that can be closed.
abstract class HostEvents {
  Stream<Map<String, dynamic>> get events;
  Future<void> close();
}

/// Lines of JSON from a channel, one message each. Split as bytes, so a
/// character cut in two by the channel is joined before it is decoded.
class JsonLines {
  final List<int> _buffer = [];

  Iterable<Map<String, dynamic>> add(List<int> data) sync* {
    _buffer.addAll(data);
    while (true) {
      final nl = _buffer.indexOf(0x0a);
      if (nl < 0) break;
      final line =
          utf8.decode(_buffer.sublist(0, nl), allowMalformed: true).trim();
      _buffer.removeRange(0, nl + 1);
      if (line.isEmpty) continue;
      try {
        final msg = jsonDecode(line);
        if (msg is Map<String, dynamic>) yield msg;
      } catch (_) {}
    }
  }
}
