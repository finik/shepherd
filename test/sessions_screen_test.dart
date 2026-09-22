import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/ui/agent_glyph.dart';
import 'package:shepherd/ui/design.dart';
import 'package:shepherd/ui/sessions_screen.dart';

Pane pane(String id, String? status, {String? title, String cwd = '/x/proj'}) =>
    Pane(
      paneId: id,
      tabId: '$id:t',
      workspaceId: id,
      agent: 'claude',
      agentStatus: status,
      cwd: cwd,
      title: title,
    );

Widget host(AppState state, {Size size = const Size(360, 800)}) => MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        theme: D.theme(Brightness.light),
        home: SessionsScreen(state: state, onThemeChanged: (_) {}),
      ),
    );

void main() {
  testWidgets('groups agents by what you would do about them', (tester) async {
    final state = AppState()
      ..conn = ConnState.connected
      ..host = HostState(panes: [
        pane('w1', 'working', title: 'Writing the parser'),
        pane('w2', 'idle', title: 'Quiet one'),
        pane('w3', 'done', title: 'Finished one'),
        pane('w4', 'unknown', title: 'Unknowable'),
      ]);

    await tester.pumpWidget(host(state));
    await tester.pump();

    expect(find.byKey(const ValueKey('group-WORKING')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-FINISHED SINCE YOU LOOKED')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('group-QUIET')), findsOneWidget);
    // Unknown is not activity: it joins Quiet rather than getting a group of
    // its own, while the row itself still reports "not reachable".
    expect(find.byKey(const ValueKey('group-UNKNOWN')), findsNothing);
    expect(find.text('Unknowable'), findsOneWidget);
    expect(find.byType(StatusIcon), findsNWidgets(4));
  });

  testWidgets('with nothing blocked there is no accent field', (tester) async {
    final state = AppState()
      ..conn = ConnState.connected
      ..host = HostState(panes: [pane('w1', 'idle', title: 'Quiet')]);

    await tester.pumpWidget(host(state));
    await tester.pump();

    // The field's absence is itself the answer to "is anything waiting on me".
    expect(find.text('WAITING ON YOU'), findsNothing);
    expect(find.text('ANSWER'), findsNothing);
  });

  testWidgets('a blocked agent is hoisted into the accent field',
      (tester) async {
    final state = AppState()
      ..conn = ConnState.connected
      ..host = HostState(panes: [
        pane('w1', 'idle', title: 'Quiet one'),
        pane('w2', 'blocked', title: 'Needs a decision'),
      ]);

    await tester.pumpWidget(host(state));
    await tester.pump();

    expect(find.text('WAITING ON YOU'), findsOneWidget);
    expect(find.text('Needs a decision'), findsOneWidget);
    expect(find.text('ANSWER'), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);

    // Accent is spent only here; nothing else in the app is filled with it.
    final fields = tester.widgetList<Container>(find.byType(Container)).where(
        (c) => c.color == D.light.accentField);
    expect(fields, isNotEmpty);
  });

  testWidgets('the sole blocked agent is not also listed below the field',
      (tester) async {
    final state = AppState()
      ..conn = ConnState.connected
      ..host = HostState(panes: [pane('w2', 'blocked', title: 'Only one')]);

    await tester.pumpWidget(host(state));
    await tester.pump();

    expect(find.text('Only one'), findsOneWidget);
  });

  testWidgets('narrow screens drop the trailing state word, keep the marker',
      (tester) async {
    final state = AppState()
      ..conn = ConnState.connected
      ..host = HostState(panes: [pane('w1', 'working', title: 'Narrow')]);

    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(state, size: const Size(320, 800)));
    await tester.pump();

    // The header still names the state; the row shows a symbol rather than
    // repeating the word, and the left column identifies the agent.
    expect(find.byKey(const ValueKey('group-WORKING')), findsOneWidget);
    expect(find.text('WORKING'), findsOneWidget);
    expect(find.byType(AgentGlyph), findsWidgets);
    expect(find.byType(StatusIcon), findsWidgets);
  });

  testWidgets('offers to add a machine when there is none', (tester) async {
    final state = AppState();
    await tester.pumpWidget(host(state));
    await tester.pump();

    expect(find.text('NO MACHINE'), findsOneWidget);
    expect(find.text('ADD MACHINE'), findsOneWidget);
  });

  testWidgets('a failed connection offers retry, not a dead end',
      (tester) async {
    final state = AppState()
      ..conn = ConnState.failed
      ..error = 'SSHAuthFailError';

    await tester.pumpWidget(host(state));
    await tester.pump();

    expect(find.text('CONNECTION FAILED'), findsOneWidget);
    expect(find.text('RETRY'), findsOneWidget);
  });

  testWidgets('coming back to the app keeps the agents on screen',
      (tester) async {
    // The agents it last showed stay, and the corner says it is catching up.
    final state = AppState()
      ..conn = ConnState.connecting
      ..host = HostState(panes: [pane('w1', 'idle', title: 'Still here')]);

    await tester.pumpWidget(host(state));
    await tester.pump();

    expect(find.text('Still here'), findsOneWidget);
    expect(find.text('RECONNECTING'), findsOneWidget);
    expect(find.text('CONNECTING'), findsNothing);
  });

  testWidgets('a connection that is truly gone says so over the list',
      (tester) async {
    final state = AppState()
      ..conn = ConnState.failed
      ..host = HostState(panes: [pane('w1', 'idle', title: 'Last seen')]);

    await tester.pumpWidget(host(state));
    await tester.pump();

    expect(find.text('Last seen'), findsOneWidget);
    expect(find.text('CONNECTION LOST · TAP TO RETRY'), findsOneWidget);
  });

  testWidgets('with nothing to show, connecting is the screen', (tester) async {
    final state = AppState()..conn = ConnState.connecting;
    await tester.pumpWidget(host(state));
    await tester.pump();
    expect(find.text('CONNECTING'), findsOneWidget);
  });
}
