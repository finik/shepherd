import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// Puts a file on the host and hands back the path the agent should read.
///
/// The agent is never handed bytes — it is handed a path and reads it with
/// the tools it already has, so the type of file barely matters here: a
/// picture, a PDF, a CSV, a log.
///
/// This is what Herdr's own `--remote` client does when you paste an image:
/// bridge the bytes to the host, stage them in a private temp directory, and
/// let the path go to the agent. Shepherd needs no protocol for it — SFTP over
/// the connection it already has.
class Uploads {
  /// Shepherd's staging directory: `$TMPDIR/shepherd-uploads-<uid>`, mode 0700
  /// so nothing on a shared host can read what you sent.
  ///
  /// Herdr stages pasted images in a directory of its own; anything that is
  /// not an image has no business in it, and one directory for every kind of
  /// attachment is one thing to explain and one thing for the OS to reap.
  ///
  /// TMPDIR carries a trailing slash on macOS, which would otherwise show up
  /// in the path the agent is handed.
  static const remoteDirScript =
      r't="${TMPDIR:-/tmp}"; t="${t%/}"; '
      r'd="$t/shepherd-uploads-$(id -u)"; '
      r'mkdir -p "$d" && chmod 700 "$d" && printf %s "$d"';

  /// The most an attachment can be before the link is the problem.
  ///
  /// This goes up the phone's uplink through SSH. Twenty megabytes is already
  /// a minute on a bad connection, and nothing an agent reads is bigger.
  static const maxBytes = 20 * 1024 * 1024;

  /// The name the agent will see, made safe to put in a shell command.
  ///
  /// The original name is worth keeping: `fares.csv` in a prompt tells the
  /// agent what it is holding, where `shepherd-1764212880.bin` tells it
  /// nothing. Everything outside a conservative set is replaced rather than
  /// quoted, because this name also has to survive the agent's own tooling.
  static String safeName(String original) {
    final base = original.split('/').last.split(r'\').last;
    final cleaned = base
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^[.-]+'), '');
    final trimmed = cleaned.length > 60
        ? cleaned.substring(cleaned.length - 60)
        : cleaned;
    return trimmed.isEmpty ? 'attachment' : trimmed;
  }

  /// Sends [file] and returns its path on the host, or null.
  static Future<String?> send(
    SSHClient ssh, {
    required String host,
    required int port,
    required String user,
    String? privateKeyPem,
    String? password,
    required File file,

    /// What the file is called where it came from. The local copy may be a
    /// cache entry with a machine-made name, and the agent should see the
    /// name you picked.
    String? name,

    /// Bytes sent so far and the total, as they go up.
    void Function(int sent, int total)? onProgress,
  }) async {
    if (await file.length() > maxBytes) return null;
    final directory = await _remoteDirectory(ssh);
    if (directory == null) return null;
    // Two attachments called notes.txt in one session must not be the same
    // file on the host.
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final remote = '$directory/$stamp-${safeName(name ?? file.path)}';

    // Encrypting a few megabytes is enough to drop frames, and this happens
    // while the user is looking at the composer waiting for it.
    final events = ReceivePort();
    final done = Completer<String?>();
    events.listen((message) {
      // onExit posts null and onError posts [error, stack]; both mean the
      // isolate died, and both end the wait as a failure.
      if (message == null) {
        if (!done.isCompleted) done.complete(null);
        return;
      }
      if (message is! List || message.isEmpty) return;
      if (message[0] is String && message.length == 2 &&
          message[0] != 'error' && message[0] != 'progress') {
        if (!done.isCompleted) done.complete(null);
        return;
      }
      if (message[0] == 'progress') {
        onProgress?.call(message[1] as int, message[2] as int);
      }
      if (message[0] == 'ok' && !done.isCompleted) done.complete(remote);
      if (message[0] == 'error' && !done.isCompleted) done.complete(null);
    });
    final isolate = await Isolate.spawn(
      _upload,
      _Request(
        reply: events.sendPort,
        host: host,
        port: port,
        user: user,
        privateKeyPem: privateKeyPem,
        password: password,
        localPath: file.path,
        remotePath: remote,
      ),
      onError: events.sendPort,
      onExit: events.sendPort,
      errorsAreFatal: true,
    );
    final result = await done.future
        .timeout(const Duration(minutes: 5), onTimeout: () => null);
    isolate.kill(priority: Isolate.immediate);
    events.close();
    return result;
  }

  static Future<String?> _remoteDirectory(SSHClient ssh) async {
    try {
      final out = await ssh
          .run(remoteDirScript)
          .timeout(const Duration(seconds: 15));
      final path = String.fromCharCodes(out).trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }
}

/// TMPDIR is the user's to set, so the path it produces is not trusted input.
String _quote(String s) => "'${s.replaceAll("'", r"'\''")}'";

class _Request {
  final SendPort reply;
  final String host;
  final int port;
  final String user;
  final String? privateKeyPem;
  final String? password;
  final String localPath;
  final String remotePath;

  const _Request({
    required this.reply,
    required this.host,
    required this.port,
    required this.user,
    required this.privateKeyPem,
    required this.password,
    required this.localPath,
    required this.remotePath,
  });
}

Future<void> _upload(_Request request) async {
  SSHClient? ssh;
  try {
    final socket = await SSHSocket.connect(request.host, request.port,
        timeout: const Duration(seconds: 20));
    ssh = SSHClient(
      socket,
      username: request.user,
      identities:
          (request.privateKeyPem == null || request.privateKeyPem!.isEmpty)
              ? null
              : SSHKeyPair.fromPem(request.privateKeyPem!),
      onPasswordRequest: (request.password == null || request.password!.isEmpty)
          ? null
          : () => request.password!,
    );
    await ssh.authenticated.timeout(const Duration(seconds: 20));
    final sftp = await ssh.sftp();
    final handle = await sftp.open(
      request.remotePath,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    // Counted on the way past, so the chip in the composer can fill up.
    // Encrypting and shipping a few megabytes up a phone's uplink is long
    // enough that a control with no sign of life reads as a failure.
    final source = File(request.localPath);
    final total = await source.length();
    var sent = 0;
    await handle.write(source.openRead().map((chunk) {
      sent += chunk.length;
      request.reply.send(['progress', sent, total]);
      return Uint8List.fromList(chunk);
    }));
    await handle.close();
    // The directory is already private; the file should be too.
    await ssh.run('chmod 600 ${_quote(request.remotePath)}');
    request.reply.send(['ok']);
  } catch (e) {
    request.reply.send(['error', e.toString()]);
  } finally {
    ssh?.close();
  }
}
