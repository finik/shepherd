import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/transcript/adapters.dart';
import 'package:shepherd/transcript/codex.dart';
import 'package:shepherd/transcript/muse.dart';
import 'package:shepherd/transcript/turn.dart';
import 'package:shepherd/ui/chat_screen.dart';
import 'package:shepherd/ui/context_pie.dart';

/// How full an agent's context is, read from the usage each agent records.
void main() {
  group('the latest call is the context in use', () {
    test('Claude: input and both cache counts, not the output', () {
      final a = ClaudeAdapter()
        ..addRecord({'type': 'user', 'message': {'role': 'user', 'content': 'go'}})
        ..addRecord({
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'model': 'claude-opus-5',
            'content': [{'type': 'text', 'text': 'ok'}],
            'usage': {
              'input_tokens': 2,
              'cache_creation_input_tokens': 556,
              'cache_read_input_tokens': 208699,
              'output_tokens': 479,
            },
          },
        });
      expect(a.usage!.used, 209257);
      expect(a.usage!.model, 'claude-opus-5');
    });

    test("a Claude subagent's calls do not count", () {
      final a = ClaudeAdapter()
        ..addRecord({
          'type': 'assistant',
          'isSidechain': true,
          'message': {
            'role': 'assistant',
            'content': [],
            'usage': {'input_tokens': 9000},
          },
        });
      expect(a.usage, isNull);
    });

    test('Codex writes the window beside the count', () {
      final a = CodexAdapter()
        ..addRecord({'type': 'turn_context', 'payload': {'model': 'gpt-6-luna'}})
        ..addRecord({
          'type': 'event_msg',
          'payload': {
            'type': 'token_count',
            'info': {
              'total_token_usage': {'input_tokens': 999999},
              'last_token_usage': {'input_tokens': 13847},
              'model_context_window': 258400,
            },
          },
        });
      expect(a.usage!.used, 13847);
      expect(a.usage!.window, 258400);
      expect(a.usage!.model, 'gpt-6-luna');
    });

    test('Pi: a failed call records zeros and says nothing', () {
      final a = PiAdapter()
        ..addRecord({
          'type': 'message',
          'message': {'role': 'user', 'content': [{'type': 'text', 'text': 'go'}]},
        })
        ..addRecord({
          'type': 'message',
          'message': {
            'role': 'assistant',
            'model': 'grok-4.6',
            'content': [],
            'usage': {'input': 1200, 'cacheRead': 30000, 'cacheWrite': 0},
          },
        })
        ..addRecord({
          'type': 'message',
          'message': {
            'role': 'assistant',
            'model': 'grok-4.6',
            'content': [],
            'usage': {'input': 0, 'cacheRead': 0, 'cacheWrite': 0},
          },
        });
      expect(a.usage!.used, 31200);
    });

    test('muse: the input of its latest model call', () {
      final a = MuseAdapter()
        ..addRecord({
          'payload_type': 'runtime.session',
          'payload': {
            'kind': 'run',
            'event': {
              'kind': 'model_completed',
              'model': 'muse-spark-1.3',
              'usage': {'input_tokens': 26479, 'cached_tokens': 25969},
            },
          },
        });
      expect(a.usage!.used, 26479);
    });

    test('Claude writes the effort on each call', () {
      final a = ClaudeAdapter()
        ..addRecord({
          'type': 'assistant',
          'effort': 'high',
          'message': {
            'role': 'assistant',
            'model': 'claude-opus-5',
            'content': [],
            'usage': {'input_tokens': 100},
          },
        });
      expect(a.usage!.effort, 'high');
    });

    test('Codex: the effort set for the turn, none when left to the model',
        () {
      Map<String, dynamic> count() => {
            'type': 'event_msg',
            'payload': {
              'type': 'token_count',
              'info': {'last_token_usage': {'input_tokens': 10}},
            },
          };
      final a = CodexAdapter()
        ..addRecord({
          'type': 'turn_context',
          'payload': {
            'model': 'gpt-6-luna',
            'collaboration_mode': {
              'settings': {'reasoning_effort': 'xhigh'}
            },
          },
        })
        ..addRecord(count());
      expect(a.usage!.effort, 'xhigh');
      a
        ..addRecord({
          'type': 'turn_context',
          'payload': {
            'model': 'gpt-6-luna',
            'collaboration_mode': {
              'settings': {'reasoning_effort': null}
            },
          },
        })
        ..addRecord(count());
      expect(a.usage!.effort, isNull);
    });

    test('Pi: the thinking level holds until changed, across a follow', () {
      Map<String, dynamic> call() => {
            'type': 'message',
            'message': {
              'role': 'assistant',
              'model': 'grok-4.6',
              'content': [],
              'usage': {'input': 100},
            },
          };
      final a = PiAdapter()
        ..addRecord({'type': 'thinking_level_change', 'thinkingLevel': 'medium'})
        ..addRecord(call());
      expect(a.usage!.effort, 'medium');
      a.addRecord({'type': 'thinking_level_change', 'thinkingLevel': 'high'});
      expect(a.usage!.effort, 'high');

      // The live follow starts on a fresh adapter given what the window saw.
      final live = PiAdapter()..usage = a.usage;
      live.addRecord(call());
      expect(live.usage!.effort, 'high');
    });

    test('it comes back from the parse isolate with the turns', () {
      const text = '{"type":"user","message":{"role":"user","content":"go"}}\n'
          '{"type":"assistant","message":{"role":"assistant","model":"m",'
          '"content":[{"type":"text","text":"ok"}],'
          '"usage":{"input_tokens":500}}}\n';
      final maps = parseTranscript({'agent': 'claude', 'text': text});
      expect(turnsFromMaps(maps).length, 1);
      expect(usageFromMaps(maps)!.used, 500);
      final back = ContextUsage.fromMap(const ContextUsage(
              used: 1, model: 'm', window: 2, effort: 'low')
          .toMap())!;
      expect(back.effort, 'low');
    });
  });

  group('what a session has cost', () {
    test("the script's last line is the answer", () {
      final c = SessionCost.parse(
          'a login warning\n{"usd": 982.63, "estimated": true, "unpriced": []}\n')!;
      expect(c.usd, 982.63);
      expect(c.estimated, isTrue);
      expect(SessionCost.parse('Traceback…'), isNull);
    });

    test('reads as money, marked when estimated or incomplete', () {
      expect(SessionCost(usd: 12.345).label, r'$12.35');
      expect(SessionCost(usd: 982.6, estimated: true).label, r'≈ $983');
      expect(SessionCost(usd: 0.004).label, r'<$0.01');
      expect(SessionCost(usd: 0).label, r'$0');
      expect(SessionCost(usd: 3, unpriced: ['x']).label, r'$3.00+');
      expect(SessionCost(usd: 0, unpriced: ['x']).label, 'cost unknown');
    });
  });

  group('the pie', () {
    test('turns red past 80%', () {
      expect(ContextPie.isHigh(0.79), isFalse);
      expect(ContextPie.isHigh(0.8), isTrue);
    });

    test('tokens read as a person counts them', () {
      expect(tokenCount(258400), '258K');
      expect(tokenCount(1000000), '1M');
      expect(tokenCount(1007997), '1.0M');
    });

    AppState working() => AppState()
      ..host = HostState.fromSnapshot({
        'panes': [
          {'pane_id': 'w1:p1', 'agent': 'codex', 'agent_status': 'idle', 'cwd': '/x'}
        ],
        'agents': [
          {'pane_id': 'w1:p1', 'agent': 'codex', 'agent_status': 'idle', 'cwd': '/x'}
        ],
      })
      ..selectedPaneId = 'w1:p1'
      ..transcriptLoading = false
      ..conn = ConnState.connected
      ..turns = [Turn(id: 'c0', userText: 'hi')];

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('shows in the header, opens its details, compacts on confirm',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final state = working()
        ..setContextForTest(
            const ContextUsage(used: 210000, model: 'gpt-6-luna'), 258400);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
      await settle(tester);
      expect(find.byKey(const ValueKey('context-pie')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('context-pie')));
      await settle(tester);
      expect(find.text('Context 81% full'), findsOneWidget);
      expect(find.textContaining('210K of 258K'), findsOneWidget);
      state.setCostForTest(SessionCost(usd: 12.5, estimated: true));
      await settle(tester);
      expect(find.text(r'≈ $12.50 at API rates'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('context-compact')));
      await settle(tester);
      // Asked first, like every compact and clear.
      expect(find.textContaining('replaces the conversation'), findsOneWidget);
      await tester.tap(find.text('CANCEL'));
      await settle(tester);
      expect(find.textContaining('replaces the conversation'), findsNothing);
    });

    testWidgets('the model and effort sit under the pie; the folder is its name',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final state = working()
        ..host = HostState.fromSnapshot({
          'panes': [
            {'pane_id': 'w1:p1', 'agent': 'claude', 'agent_status': 'idle',
             'cwd': '/home/x/work/cart'}
          ],
          'agents': [
            {'pane_id': 'w1:p1', 'agent': 'claude', 'agent_status': 'idle',
             'cwd': '/home/x/work/cart'}
          ],
        })
        ..setContextForTest(
            const ContextUsage(
                used: 50000, model: 'claude-opus-5', effort: 'high'),
            200000);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
      await settle(tester);
      expect(find.text('opus-5 · high'), findsOneWidget);
      expect(find.text('cart'), findsWidgets);
      expect(find.textContaining('~/'), findsNothing);
    });

    testWidgets('clearing is offered beside compacting, and asks first',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final state = working()
        ..setContextForTest(
            const ContextUsage(used: 1000, model: 'gpt-6-luna'), 258400);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('context-pie')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('context-clear')));
      await settle(tester);
      expect(find.text('CANCEL'), findsOneWidget);
      await tester.tap(find.text('CANCEL'));
      await settle(tester);
    });

    testWidgets('the menu holds neither the model nor the context',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final state = working()
        ..setContextForTest(
            const ContextUsage(used: 1000, model: 'gpt-6-luna'), 258400);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('chat-menu')));
      await settle(tester);
      expect(find.text('Close agent'), findsOneWidget);
      expect(find.text('Model'), findsNothing);
      expect(find.text('Compact context'), findsNothing);
      expect(find.text('Clear context'), findsNothing);
      // The pie and its details carry both already.
      state.setCostForTest(SessionCost(usd: 3));
      await settle(tester);
      expect(find.textContaining('API rates'), findsNothing);
      expect(find.textContaining('% of'), findsNothing);
    });

    testWidgets('the model line opens model and effort, kept until changed',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final state = working()
        ..setContextForTest(
            const ContextUsage(
                used: 1000, model: 'gpt-6-luna', effort: 'medium'),
            258400);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('model-line')));
      await settle(tester);
      expect(find.text('Agent, model and effort'), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-choice')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-choice')), findsOneWidget);
      expect(find.byKey(const ValueKey('effort-choice')), findsOneWidget);
      expect(find.text('Keep gpt-6-luna'), findsOneWidget);
      // Nothing chosen yet: nothing to switch to.
      final button = tester.widget<TextButton>(
          find.byKey(const ValueKey('model-switch')));
      expect(button.onPressed, isNull);
    });

    testWidgets('no usage yet, no pie', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ChatScreen(state: working())));
      await settle(tester);
      expect(find.byKey(const ValueKey('context-pie')), findsNothing);
    });
  });
}
