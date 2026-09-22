import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Ships new builds over SSH, so updating does not require plugging the phone
/// into anything.
///
/// Host side is two files under `~/.shepherd/`: `version.txt` holding the
/// build number, and `shepherd.apk`. `tool/publish.sh` writes both.
class Updater {
  static const remoteDir = '.shepherd';
  static const versionFile = '$remoteDir/version.txt';
  static const apkFile = '$remoteDir/shepherd.apk';

  /// Build number available on the host, or null if nothing is published.
  static Future<int?> availableBuild(SSHClient ssh) async {
    try {
      final out = await ssh.run('cat ~/$versionFile 2>/dev/null');
      final text = String.fromCharCodes(out).trim();
      return text.isEmpty ? null : int.tryParse(text);
    } catch (_) {
      return null;
    }
  }

  static Future<int> currentBuild() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  /// Pulls the APK and hands it to the system installer.
  ///
  /// The transfer runs in its own isolate on its own SSH connection:
  /// decrypting 57MB is seconds of solid CPU, which would starve the UI of
  /// frames, and a stalled poll on the app's connection cannot take the
  /// transfer down with it.
  ///
  /// [onProgress] reports bytes received and the total. Bytes rather than a
  /// percentage because a slow link moves several hundred KB between whole
  /// percents, and a number that has not moved for ten seconds reads as a hang
  /// whether or not it is one.
  static Future<String> install(
    SSHClient ssh, {
    required String host,
    required int port,
    required String user,
    String? privateKeyPem,
    String? password,
    void Function(int received, int total)? onProgress,
  }) async {
    final remote = await _resolveRemote(ssh);
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}/shepherd-update.apk';
    final file = File(path);
    if (file.existsSync()) await file.delete();

    const failed = 'FAILED · TRANSFER STOPPED';
    final events = ReceivePort();
    final done = Completer<String>();
    events.listen((message) {
      // onExit posts null and onError posts [error, stack]; both mean the
      // isolate died, and both end the wait as a failure.
      if (message == null) {
        if (!done.isCompleted) done.complete(failed);
        return;
      }
      if (message is! List || message.isEmpty) return;
      if (message[0] is String && message.length == 2 &&
          message[0] != 'error' && message[0] != 'progress') {
        if (!done.isCompleted) done.complete(failed);
        return;
      }
      switch (message[0]) {
        case 'progress':
          onProgress?.call(message[1] as int, message[2] as int);
        case 'ok':
          if (!done.isCompleted) done.complete('');
        case 'error':
          if (!done.isCompleted) done.complete(message[1] as String);
      }
    });

    final isolate = await Isolate.spawn(
      _download,
      _Request(
        reply: events.sendPort,
        host: host,
        port: port,
        user: user,
        privateKeyPem: privateKeyPem,
        password: password,
        remotePath: remote,
        localPath: path,
      ),
      onError: events.sendPort,
      onExit: events.sendPort,
      errorsAreFatal: true,
    );

    // Bounded: an isolate wedged on a stalled handshake never reports at all.
    final failure = await done.future
        .timeout(const Duration(minutes: 30), onTimeout: () => failed);
    isolate.kill(priority: Isolate.immediate);
    events.close();
    if (failure == failed) return failed;
    if (failure.isNotEmpty) return 'FAILED · ${failure.toUpperCase()}';

    // Android verifies the signature itself; a truncated file fails there
    // rather than installing something broken.
    final result = await OpenFilex.open(
      path,
      type: 'application/vnd.android.package-archive',
    );
    return result.type == ResultType.done
        ? 'INSTALLER OPENED'
        : 'FAILED · ${result.message.toUpperCase()}';
  }

  /// SFTP needs an absolute path; `~` is a shell construct.
  static Future<String> _resolveRemote(SSHClient ssh) async {
    final home =
        String.fromCharCodes(await ssh.run(r'printf %s "$HOME"')).trim();
    return '$home/$apkFile';
  }
}

class _Request {
  final SendPort reply;
  final String host;
  final int port;
  final String user;
  final String? privateKeyPem;
  final String? password;
  final String remotePath;
  final String localPath;

  const _Request({
    required this.reply,
    required this.host,
    required this.port,
    required this.user,
    required this.privateKeyPem,
    required this.password,
    required this.remotePath,
    required this.localPath,
  });
}

/// Runs in the download isolate: its own socket, its own SSH session, no
/// plugins — everything a plugin would answer was resolved before the spawn.
Future<void> _download(_Request request) async {
  SSHClient? ssh;
  IOSink? sink;
  try {
    final socket = await SSHSocket.connect(request.host, request.port,
        timeout: const Duration(seconds: 20));
    ssh = SSHClient(
      socket,
      username: request.user,
      identities: (request.privateKeyPem == null ||
              request.privateKeyPem!.isEmpty)
          ? null
          : SSHKeyPair.fromPem(request.privateKeyPem!),
      onPasswordRequest: (request.password == null || request.password!.isEmpty)
          ? null
          : () => request.password!,
    );
    await ssh.authenticated.timeout(const Duration(seconds: 20));

    final sftp = await ssh.sftp();
    final stat = await sftp.stat(request.remotePath);
    final total = stat.size ?? 0;
    sink = File(request.localPath).openWrite();

    var received = 0;
    final handle = await sftp.open(request.remotePath);
    try {
      // If the connection dies mid-transfer the read simply never yields
      // again, and a progress bar that waits forever is worse than one that
      // admits it stopped.
      await for (final chunk
          in handle.read().timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        request.reply.send(['progress', received, total]);
      }
    } finally {
      await handle.close();
      await sink.close();
      sink = null;
    }

    if (received == 0) {
      request.reply.send(['error', 'empty download']);
    } else if (total <= 0) {
      // Without a size from the host there is nothing to check the transfer
      // against, and publish.sh copies the APK into place non-atomically.
      request.reply.send(['error', 'could not size the download']);
    } else if (received < total) {
      request.reply.send(['error', 'incomplete download']);
    } else {
      request.reply.send(['ok']);
    }
  } catch (e) {
    await sink?.close();
    request.reply.send(['error', e.toString().split('(').first.trim()]);
  } finally {
    ssh?.close();
  }
}
