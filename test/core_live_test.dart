import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/core_client.dart';

/// The client against this machine's own herdr-core, through the line the
/// app runs over SSH. Only reads; skipped where there is no core.
void main() {
  final home = Platform.environment['HOME'] ?? '';
  final hasCore = File('$home/.local/bin/hc').existsSync() ||
      Process.runSync('sh', ['-c', 'command -v hc']).exitCode == 0;

  Future<CoreClient?> open() async {
    final process = await Process.start('sh', ['-c', CoreClient.launch]);
    return CoreClient.over(process.stdout, process.stdin, () => process.kill(),
        another: open);
  }

  test('the host as this core reports it', () async {
    final client = await open();
    expect(client, isNotNull, reason: 'no core answered');
    try {
      expect(client!.home, home);
      expect(await client.ping(), startsWith('HERDR-CORE '));
      // Subscribed first, as the app is: what it asks afterwards is still
      // answered.
      final events = await client.subscribe();
      final host = await client.snapshot();
      await events.close();
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

  test('what is submitted reaches the terminal', () async {
    final client = await open();
    expect(client, isNotNull, reason: 'no core answered');
    // A shell of the test's own, outside the app (no space or tab labels)
    // and nobody's child, so its end is not typed into the terminal that
    // runs the tests.
    final run = Process.runSync(
        'sh', ['-c', r'PATH="$HOME/.local/bin:$PATH"; hc run --bg --json --no-parent sh']);
    final address =
        RegExp(r'"address":"([^"]+)"').firstMatch(run.stdout as String)?[1];
    expect(address, isNotNull, reason: '${run.stdout}${run.stderr}');
    try {
      await client!.submit(address!, 'echo shepherd-$address');
      var screen = '';
      for (var i = 0; i < 20 && !screen.contains('\nshepherd-$address'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        screen = await client.readPane(address, source: 'visible', lines: 30);
      }
      expect(screen, contains('\nshepherd-$address'));
      expect(await client.paneAgent(address), isNull);
    } finally {
      await client?.closePane(address!);
      Process.runSync(
          'sh', ['-c', 'PATH="\$HOME/.local/bin:\$PATH"; hc rm $address']);
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
