import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/transcript/adapters.dart';
import 'package:shepherd/transcript/codex.dart';
import 'package:shepherd/transcript/turn.dart';
import 'package:shepherd/ui/chat_screen.dart';

/// Where an agent compacted its context: a mark in the thread, with the
/// summary it carried forward — never a message from you.
void main() {
  const summary = '<artifact-content-authored-by-others/>\n'
      'The summarized conversation included Artifact content written by '
      'people other than you.\n'
      'This session is being continued from a previous conversation that ran '
      'out of context. The summary below covers the earlier portion of the '
      'conversation.\n\n'
      'Summary:\n1. Primary Request and Intent:\n   Build a retirement planner.';

  test("Claude's summary marks a compaction, not a turn you typed", () {
    final a = ClaudeAdapter()
      ..addRecord({
        'type': 'user',
        'message': {'role': 'user', 'content': 'plan my retirement'},
      })
      ..addRecord({
        'type': 'user',
        'isCompactSummary': true,
        'isVisibleInTranscriptOnly': true,
        'message': {'role': 'user', 'content': summary},
      })
      ..addRecord({
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'Carrying on with the planner.'}
          ],
        },
      });
    expect(a.turns.map((t) => t.compaction), [false, true]);
    final marked = a.turns.last;
    // The summary itself, without what Claude wrote around it.
    expect(marked.userText, startsWith('1. Primary Request and Intent:'));
    expect(marked.userText, isNot(contains('artifact-content')));
    expect(marked.userText, isNot(contains('being continued')));
    // What the agent does next follows the mark.
    expect(marked.assistantTexts, ['Carrying on with the planner.']);
  });

  test('Pi and Codex mark theirs the same way', () {
    final pi = PiAdapter()
      ..addRecord({'type': 'compaction', 'summary': '## Goal\n- Cards'});
    expect(pi.turns.single.compaction, isTrue);
    expect(pi.turns.single.userText, '## Goal\n- Cards');
    final codex = CodexAdapter()
      ..addRecord({
        'type': 'compacted',
        'payload': {'message': '', 'replacement_history': []},
      });
    expect(codex.turns.single.compaction, isTrue);
  });

  test('the mark survives the trip from the parse isolate', () {
    final turns = turnsFromMaps(parseTranscript({
      'agent': 'claude',
      'text': '{"type":"user","isCompactSummary":true,'
          '"message":{"role":"user","content":"Summary:\\nkept"}}\n',
    }));
    expect(turns.single.compaction, isTrue);
    expect(turns.single.userText, 'kept');
  });

  testWidgets('drawn as a rule, the summary a tap away', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final state = AppState()
      ..host = HostState.fromSnapshot({
        'panes': [
          {'pane_id': 'p', 'agent': 'claude', 'agent_status': 'idle', 'cwd': '/x'}
        ],
        'agents': [
          {'pane_id': 'p', 'agent': 'claude', 'agent_status': 'idle', 'cwd': '/x'}
        ],
      })
      ..selectedPaneId = 'p'
      ..transcriptLoading = false
      ..conn = ConnState.connected
      ..turns = [
        Turn(id: 'c0', userText: 'Build a retirement planner.',
            compaction: true),
      ];
    await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('YOU'), findsNothing);
    expect(find.text('CONTEXT COMPACTED · SUMMARY'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('compacted-c0')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('What the agent carried forward'), findsOneWidget);
    expect(find.text('Build a retirement planner.'), findsOneWidget);
  });
}
