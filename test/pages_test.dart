import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/transcript/turn.dart';
import 'package:shepherd/ui/chat_screen.dart';

/// Web pages served on the host, opened on the phone through the SSH
/// connection.
void main() {
  test('what an agent prints for its own server is a page on the host', () {
    for (final url in [
      'http://localhost:8787',
      'http://127.0.0.1:5173/app.html',
      'http://0.0.0.0:8000/',
      'https://localhost:8443/',
    ]) {
      expect(AppState.isHostLocal(Uri.parse(url)), isTrue, reason: url);
    }
    for (final url in [
      'https://github.com/x',
      'http://example.com:8787',
      'file:///tmp/x',
    ]) {
      expect(AppState.isHostLocal(Uri.parse(url)), isFalse, reason: url);
    }
  });

  test('the listing script finds a server and the folder it runs in',
      () async {
    final dir = Directory.systemTemp.createTempSync('pages');
    addTearDown(() => dir.deleteSync(recursive: true));
    final server = await Process.start(
        'python3', ['-u', '-m', 'http.server', '0', '--bind', '127.0.0.1'],
        workingDirectory: dir.path);
    addTearDown(server.kill);
    // http.server prints its port once it is listening.
    final line = await server.stdout
        .transform(utf8.decoder)
        .firstWhere((l) => l.contains('port'));
    final port = int.parse(RegExp(r'port (\d+)').firstMatch(line)!.group(1)!);
    final out = await Process.run(
        'python3', ['-c', AppState.portsScriptForTest, dir.path],
        environment: {'HOME': dir.parent.path});
    final found = HostPort.fromList(jsonDecode(
        (out.stdout as String).split('\n').lastWhere((l) => l.startsWith('@@@'))
            .substring(3)) as List);
    final ours = found.firstWhere((p) => p.port == port);
    expect(ours.here, isTrue);
    expect(ours.command, contains('http.server'));
    // The pane's own servers come first.
    expect(found.first.here, isTrue);
  }, skip: Platform.isMacOS || Platform.isLinux ? false : 'needs lsof');

  test('a page stays open when put away, until it is closed', () {
    final state = AppState();
    final url = Uri.parse('http://localhost:8787/');
    state.openPage(url);
    expect((state.pageUrl, state.pageShown), (url, true));
    state.showPage(false);
    expect((state.pageUrl, state.pageShown), (url, false));
    state.showPage(true);
    expect(state.pageShown, isTrue);
    state.closePage();
    expect((state.pageUrl, state.pageShown), (null, false));
    // Nothing to show once closed.
    state.showPage(true);
    expect(state.pageShown, isFalse);
  });

  testWidgets('the menu offers the host\'s pages', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final state = AppState()
      ..host = HostState.fromSnapshot({
        'panes': [
          {'pane_id': 'p', 'agent': 'pi', 'agent_status': 'idle', 'cwd': '/x/retirement'}
        ],
        'agents': [
          {'pane_id': 'p', 'agent': 'pi', 'agent_status': 'idle', 'cwd': '/x/retirement'}
        ],
      })
      ..selectedPaneId = 'p'
      ..transcriptLoading = false
      ..conn = ConnState.connected
      ..turns = [Turn(id: 't', userText: 'hi')];
    await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('chat-menu')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('menu-pages')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Web pages on the host'), findsOneWidget);
    // No connection in a test: the host is not asked.
    expect(find.text('The host did not answer.'), findsOneWidget);
    expect(find.byKey(const ValueKey('port-typed')), findsOneWidget);
  });
}
