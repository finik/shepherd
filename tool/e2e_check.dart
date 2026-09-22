// End-to-end: SSH -> forwarded unix socket -> Herdr NDJSON -> snapshot.
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:shepherd/herdr/client.dart';

void main(List<String> args) async {
  final host = args[0], user = args[1], keyPath = args[2], sock = args[3];
  final socket = await SSHSocket.connect(host, 22,
      timeout: const Duration(seconds: 10));
  final ssh = SSHClient(socket,
      username: user,
      identities: SSHKeyPair.fromPem(File(keyPath).readAsStringSync()));
  await ssh.authenticated;
  print('AUTH ok');

  final rpc = HerdrClient(ssh, sock);
  final pong = await rpc.call('ping');
  print('PING ${pong['type']} protocol=${pong['protocol']} v=${pong['version']}');

  final snap = await rpc.snapshot();
  print('SNAPSHOT workspaces=${snap.workspaces.length} panes=${snap.panes.length} '
      'focused=${snap.focusedPaneId}');
  for (final p in snap.agentPanes) {
    print('  ${p.paneId} ${p.agent} ${p.agentStatus} cwd=${p.shortCwd} '
        'session=${p.agentSession?.kind}:${(p.agentSession?.value ?? '').split('/').last}');
  }

  final events = await rpc.subscribe();
  print('SUBSCRIBE ok (connection held open)');

  final focused = snap.focusedPane ?? (snap.agentPanes.isNotEmpty ? snap.agentPanes.first : null);
  if (focused != null) {
    final text = await rpc.readPane(focused.paneId, lines: 6);
    print('PANE.READ ${focused.paneId} -> ${text.trim().split('\n').length} lines');
  }
  await events.close();
  ssh.close();
  print('ALL OK');
  exit(0);
}
