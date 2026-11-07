import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/core_client.dart';

/// The client against this machine's own herdr-core, through the line the
/// app runs over SSH. Only reads; skipped where there is no core.
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final hasCore = File('$home/.local/bin/hc').existsSync() ||
      Process.runSync('sh', ['-c', 'command -v hc']).exitCode == 0;

  test('the host as this core reports it', () async {
    final process = await Process.start('sh', ['-c', CoreClient.launch]);
    final client = await CoreClient.over(
        process.stdout, process.stdin, () => process.kill());
    expect(client, isNotNull, reason: 'no core answered');
    try {
      expect(client!.home, home);
      expect(await client.ping(), startsWith('HERDR-CORE '));
      final host = await client.snapshot();
      for (final pane in host.panes) {
        expect(host.workspaces.map((w) => w.workspaceId),
            contains(pane.workspaceId));
      }
      // Every Claude the core runs has its session found.
      for (final pane in host.agentPanes.where((p) => p.agent == 'claude')) {
        expect(pane.agentSession?.value, isNotEmpty,
            reason: '${pane.paneId} has no session');
      }
      if (host.panes.isNotEmpty) {
        final screen = await client.readPane(host.panes.first.paneId,
            source: 'visible', lines: 30);
        expect(screen.split('\n').length, lessThanOrEqualTo(30));
      }
    } finally {
      await client?.close();
    }
  }, skip: hasCore ? false : 'no herdr-core on this machine');

  test('no core is no client', () async {
    final process =
        await Process.start('sh', ['-c', 'exit 127']);
    final client = await CoreClient.over(
        process.stdout, process.stdin, () => process.kill());
    expect(client, isNull);
  });
}
