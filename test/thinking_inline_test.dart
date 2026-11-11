import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/transcript/turn.dart';
import 'package:shepherd/ui/chat_screen.dart';

void main() {
  AppState chat() {
    final turn = Turn(id: 'c0', userText: 'look into it');
    turn.steps
      ..add(const Reasoning('Checking the transcript first.'))
      ..add(const Reply('Here is what I found.'));
    return AppState()
      ..host = HostState.fromSnapshot({
        'panes': [
          {'pane_id': 'w1:p1', 'agent': 'claude', 'agent_status': 'idle', 'cwd': '/x'}
        ],
        'agents': [
          {'pane_id': 'w1:p1', 'agent': 'claude', 'agent_status': 'idle', 'cwd': '/x'}
        ],
      })
      ..selectedPaneId = 'w1:p1'
      ..transcriptLoading = false
      ..conn = ConnState.connected
      ..turns = [turn];
  }

  Future<void> open(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  test('inline thinking is off until asked for', () {
    expect(AppState().showThinkingInline, isFalse);
  });

  testWidgets('by default a thinking block is only counted', (tester) async {
    await open(tester, chat());
    expect(find.text('Checking the transcript first.'), findsNothing);
    expect(find.textContaining('1 STEP'), findsOneWidget);
    expect(find.textContaining('Here is what I found.'), findsOneWidget);
  });

  testWidgets('opted in, it is printed in the thread', (tester) async {
    final state = chat()..showThinkingInline = true;
    await open(tester, state);
    expect(find.textContaining('Checking the transcript first.'), findsOneWidget);
    expect(find.textContaining('1 STEP'), findsNothing);
    expect(find.textContaining('Here is what I found.'), findsOneWidget);
  });

  testWidgets('with chain of thought off, nothing is printed', (tester) async {
    final state = chat()
      ..showThinking = false
      ..showThinkingInline = true;
    await open(tester, state);
    expect(find.textContaining('Checking the transcript first.'), findsNothing);
  });
}
