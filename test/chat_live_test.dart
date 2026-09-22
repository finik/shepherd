import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/transcript/turn.dart';
import 'package:shepherd/ui/chat_screen.dart';

/// An open chat shows a reply as it arrives.
///
/// The chat only repaints when something it watches changes. The turn count
/// is not enough — an agent that answers and keeps going appends every
/// further sentence to the same turn — and the activity line goes null the
/// moment a reply arrives.
void main() {
  /// Show the chat and let it settle, including one notification, so the
  /// screen has cached what it is looking at. Without this the first
  /// notification always repaints — the cache starts empty — and a test that
  /// sends only one proves nothing.
  Future<void> show(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
    await tester.pump();
    state.notifyForTest();
    await tester.pump();
  }

  AppState working() {
    final state = AppState();
    state.host = HostState.fromSnapshot({
      'panes': [
        {'pane_id': 'w1:p1', 'agent': 'claude', 'agent_status': 'working',
            'cwd': '/x'}
      ],
      'agents': [
        {'pane_id': 'w1:p1', 'agent': 'claude', 'agent_status': 'working',
            'cwd': '/x'}
      ],
    });
    state.selectedPaneId = 'w1:p1';
    state.transcriptLoading = false;
    state.conn = ConnState.connected;
    return state;
  }

  testWidgets('a reply landing in the open turn appears without leaving',
      (tester) async {
    final state = working();
    // Already answering: the activity line is null before and after, so the
    // screen has nothing to notice except the content itself.
    final turn = Turn(id: 'c0', userText: 'what changed?')
      ..steps.add(const Reply('Looking now.'));
    state.turns = [turn];
    await show(tester, state);
    expect(find.textContaining('Two files', findRichText: true), findsNothing);

    // The agent answers. Same turn, same count, still working.
    turn.steps.add(const Reply('Two files changed.'));
    state.notifyForTest();
    await tester.pump();

    expect(find.textContaining('Two files', findRichText: true),
        findsOneWidget);
  });

  testWidgets('a reply that grows appears as it grows', (tester) async {
    final state = working();
    final turn = Turn(id: 'c0', userText: 'explain')
      ..steps.add(const Reply('One moment'));
    state.turns = [turn];
    await show(tester, state);

    turn.steps
      ..clear()
      ..add(const Reply('One moment — here is the whole story.'));
    state.notifyForTest();
    await tester.pump();

    expect(find.textContaining('whole story', findRichText: true),
        findsOneWidget);
  });

  testWidgets('reconnecting is a wait, not an error', (tester) async {
    final state = working()..conn = ConnState.connecting;
    await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
    await tester.pump();
    expect(find.text('CONNECTING'), findsOneWidget);
    expect(find.text('NOT CONNECTED'), findsNothing);

    state.conn = ConnState.connected;
    state.transcriptLoading = true;
    state.notifyForTest();
    await tester.pump();
    expect(find.text('READING TRANSCRIPT'), findsOneWidget);
    expect(find.text('NO TRANSCRIPT YET'), findsNothing);
  });

  testWidgets('only a failed connection is shown as one', (tester) async {
    final state = working()..conn = ConnState.failed;
    await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
    await tester.pump();
    expect(find.text('NOT CONNECTED'), findsOneWidget);
  });
}
