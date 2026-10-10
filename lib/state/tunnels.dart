import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

/// Ports on the host, opened on the phone: `ssh -L` over the connection the
/// app already holds.
///
/// Each tunnel listens on the phone's loopback address only, on the host's
/// own port number when it is free, so a page that builds links, cookies or
/// callbacks for `localhost:8787` still finds them. Every connection is
/// carried to the host over whichever SSH connection is current, so a tunnel
/// outlives a reconnect.
class Tunnels {
  /// The connection to carry connections over; null while there is none.
  final SSHClient? Function() client;

  Tunnels(this.client);

  final Map<int, ServerSocket> _servers = {};
  final Set<Socket> _open = {};

  /// The port on the phone that reaches [hostPort] on the host, opening the
  /// tunnel the first time it is asked for.
  Future<int> open(int hostPort) async {
    final existing = _servers[hostPort];
    if (existing != null) return existing.port;
    ServerSocket server;
    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, hostPort);
    } on SocketException {
      // Taken on the phone; any free port still works for most pages.
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    _servers[hostPort] = server;
    server.listen((socket) => unawaited(_carry(socket, hostPort)));
    return server.port;
  }

  /// The host ports with a tunnel open.
  Iterable<int> get ports => _servers.keys;

  Future<void> _carry(Socket socket, int hostPort) async {
    final ssh = client();
    if (ssh == null) {
      socket.destroy();
      return;
    }
    _open.add(socket);
    SSHForwardChannel channel;
    try {
      channel = await ssh.forwardLocal('127.0.0.1', hostPort);
    } catch (_) {
      // Nothing listening on the host, or the connection went.
      _open.remove(socket);
      socket.destroy();
      return;
    }
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      _open.remove(socket);
      socket.destroy();
      channel.sink.close().ignore();
    }

    channel.stream.listen(socket.add, onDone: close, onError: (_) => close());
    socket.listen(channel.sink.add, onDone: close, onError: (_) => close());
  }

  /// Close every tunnel and every connection through them.
  Future<void> closeAll() async {
    for (final s in _open.toList()) {
      s.destroy();
    }
    _open.clear();
    for (final server in _servers.values) {
      await server.close();
    }
    _servers.clear();
  }
}
