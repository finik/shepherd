import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/ui/design.dart';
import 'package:shepherd/ui/sessions_screen.dart';

void main() {
  Widget host(AppState state) => MaterialApp(
        theme: D.theme(Brightness.light),
        home: SessionsScreen(state: state, onThemeChanged: (_) {}),
      );

  testWidgets('a connected host offers to start an agent', (tester) async {
    final state = AppState()
      ..conn = ConnState.connected
      ..host = HostState(panes: [
        Pane(paneId: 'w1', tabId: 't', workspaceId: 'w', agent: 'pi',
            agentStatus: 'idle', cwd: '/x/work/cart'),
      ]);
    await tester.pumpWidget(host(state));
    await tester.pump();
    expect(find.byKey(const ValueKey('new-agent')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-agent')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('NEW AGENT'), findsOneWidget);
    // Where agents already work is offered without browsing.
    expect(find.text('/x/work/cart'), findsOneWidget);
    expect(find.text('CHOOSE AN AGENT'), findsOneWidget);
    // Both pull-downs are there from the start, waiting on what they need.
    expect(find.byKey(const ValueKey('agent-pulldown')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-pulldown')), findsOneWidget);
    expect(find.text('Choose an agent first'), findsOneWidget);
  });

  testWidgets('with no host there is nothing to start one on', (tester) async {
    final state = AppState()..conn = ConnState.failed;
    await tester.pumpWidget(host(state));
    await tester.pump();
    expect(find.byKey(const ValueKey('new-agent')), findsNothing);
  });

  test("an agent's models are asked for once", () async {
    final state = AppState();
    // No host: nothing is found, and nothing is kept, so the next ask tries
    // again rather than remembering an empty list.
    expect(await state.listModels('claude'), isEmpty);
    expect(await state.listModels('claude'), isEmpty);
  });

  test('the listing script output becomes models', () {
    const out = 'noise from a login shell\n'
        '@@@[{"id": "opus", "label": "opus", "detail": "Latest Opus", '
        '"efforts": ["low", "high"]}, '
        '{"id": "claude-fable-5-1[1m]", "label": "Fable", '
        '"detail": "Fable 5.1 \\u00b7 Most capable"}]\n';
    final models = AppState.parseModels(out);
    expect(models.map((m) => m.id), ['opus', 'claude-fable-5-1[1m]']);
    expect(models.last.detail, 'Fable 5.1 · Most capable');
    expect(models.first.efforts, ['low', 'high']);
    expect(models.last.efforts, isEmpty);
    expect(AppState.parseModels('nothing useful'), isEmpty);
  });

  test('agents already working give their folders once each', () {
    final state = AppState()
      ..host = HostState(panes: [
        Pane(paneId: 'a', tabId: 't', workspaceId: 'w', agent: 'pi', cwd: '/x/a'),
        Pane(paneId: 'b', tabId: 't', workspaceId: 'w', agent: 'claude', cwd: '/x/a'),
        Pane(paneId: 'c', tabId: 't', workspaceId: 'w', agent: 'codex', cwd: '/x/b'),
      ]);
    expect(state.agentFolders, ['/x/a', '/x/b']);
  });
}
