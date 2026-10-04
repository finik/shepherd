import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/transcript/turn.dart';
import 'package:shepherd/ui/chat_screen.dart';
import 'package:shepherd/ui/quotas_screen.dart';

/// What is left of each subscription: read on the host from the
/// herdr-agent-usage plugin and CodexBar, whichever it has.
void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('plans'));
  tearDown(() => home.deleteSync(recursive: true));

  /// The host script, run against [home]: its folders are where the plugin
  /// and CodexBar would be.
  Object? run([String mode = '']) {
    final script = File('${home.path}/plans.py')
      ..writeAsStringSync(AppState.plansScript);
    final out = Process.runSync('python3', [script.path, if (mode.isNotEmpty) mode],
        environment: {
          'HOME': home.path,
          'PATH': '${home.path}/bin:/usr/bin:/bin',
          'XDG_STATE_HOME': '${home.path}/state',
        },
        includeParentEnvironment: false);
    final line = (out.stdout as String)
        .split('\n')
        .lastWhere((l) => l.startsWith('@@@'));
    return jsonDecode(line.substring(3));
  }

  void plugin(String name, Map<String, dynamic> snapshot) {
    final dir = Directory('${home.path}/state/herdr/plugins/herdr-agent-usage')
      ..createSync(recursive: true);
    File('${dir.path}/$name.json').writeAsStringSync(jsonEncode(snapshot));
  }

  /// A stand-in CodexBar ahead of any real one, answering with the fixture
  /// or, [silent], with nothing.
  void codexbar({bool silent = false}) {
    final dir = Directory('${home.path}/bin')..createSync();
    File('${home.path}/codexbar.json').writeAsStringSync(silent
        ? '[]'
        : File('test/fixtures/codexbar_usage.json').readAsStringSync());
    final bin = File('${dir.path}/codexbar')
      ..writeAsStringSync('#!/bin/sh\ncat "\$HOME/codexbar.json"\n');
    Process.runSync('chmod', ['+x', bin.path]);
  }

  final claudeSnapshot = {
    'snapshot': {
      'provider': 'claude',
      'source': 'claude-statusline',
      'fetched_at_unix': 1790874304,
      'windows': [
        {'kind': 'five_hour', 'used_percent': 9.0, 'remaining_percent': 91.0,
         'resets_at': 1790888400},
        {'kind': 'weekly', 'used_percent': 87.0, 'remaining_percent': 13.0,
         'resets_at': 1791046800},
      ],
    },
    'payload': {},
  };

  test('the plugin is read when it is there', () {
    plugin('claude-statusline.observation', claudeSnapshot);
    codexbar(silent: true);
    // Its own settings files are not snapshots.
    File('${home.path}/state/herdr/plugins/herdr-agent-usage/fields')
        .writeAsStringSync('provider');
    expect(run('check'), isTrue);
    final plans = PlanUsage.fromList(run() as List);
    expect(plans.single.provider, 'claude');
    expect(plans.single.windows.map((w) => w.minutes), [300, 10080]);
    expect(plans.single.windows.last.usedPercent, 87);
    expect(plans.single.windows.first.resetsAt,
        DateTime.fromMillisecondsSinceEpoch(1790888400000, isUtc: true));
  });

  test('CodexBar fills in what the plugin has not read', () {
    plugin('claude-statusline.observation', claudeSnapshot);
    codexbar();
    final plans = PlanUsage.fromList(run() as List);
    expect(plans.map((p) => p.provider), ['claude', 'codex', 'xai']);
    // The plugin's numbers stand; CodexBar names the plan.
    expect(plans.first.windows.last.usedPercent, 87);
    expect(plans.first.plan, 'Claude Max 5x');
    expect(plans[1].windows.single.minutes, 43200);
    expect(plans.last.error, contains('No available fetch strategy'));
  });

  test("one session's file without the five hours does not hide them", () {
    plugin('claude-statusline.observation', claudeSnapshot);
    // Newer, from a session that reported only the week.
    plugin('claude-statusline', {
      'snapshot': {
        'provider': 'claude',
        'fetched_at_unix': 1790874999,
        'windows': [
          {'kind': 'weekly', 'used_percent': 88.0, 'resets_at': 1791046800},
        ],
      },
    });
    codexbar(silent: true);
    final claude = PlanUsage.fromList(run() as List).single;
    expect(claude.windows.map((w) => w.minutes), [300, 10080]);
    expect(claude.windows.map((w) => w.usedPercent), [9, 88]);
  });

  test('CodexBar gives a window the plugin has not seen', () {
    plugin('claude-statusline', {
      'snapshot': {
        'provider': 'claude',
        'fetched_at_unix': 1790874999,
        'windows': [
          {'kind': 'weekly', 'used_percent': 88.0, 'resets_at': 1791046800},
        ],
      },
    });
    codexbar();
    final claude = PlanUsage.fromList(run() as List)
        .firstWhere((p) => p.provider == 'claude');
    expect(claude.windows.map((w) => w.minutes), [300, 10080]);
    // The plugin's week stands; the five hours are CodexBar's.
    expect(claude.windows.last.usedPercent, 88);
    expect(claude.windows.first.usedPercent, 39);
  });

  test('CodexBar alone', () {
    codexbar();
    expect(run('check'), isTrue);
    final claude = PlanUsage.fromList(run() as List)
        .firstWhere((p) => p.provider == 'claude');
    expect(claude.windows.map((w) => w.label), ['Session', 'Weekly']);
    expect(claude.windows.last.pace, contains('Runs out in'));
  });

  test('windows, resets and old readings read as a person says them', () {
    expect(windowSpan(300), '5 hours');
    expect(windowSpan(10080), 'week');
    expect(windowSpan(43200), '30 days');
    expect(windowSpan(null), isNull);
    final now = DateTime.utc(2026, 9, 30, 6);
    expect(resetsIn(DateTime.utc(2026, 9, 30, 7, 9), now), 'resets in 1h 9m');
    expect(resetsIn(DateTime.utc(2026, 9, 30, 6, 20), now), 'resets in 20m');
    expect(resetsIn(DateTime.utc(2026, 10, 3, 17), now), 'resets in 3 days');
    expect(resetsIn(DateTime.utc(2026, 9, 29), now), 'resetting');
    expect(asOf(DateTime.utc(2026, 9, 30, 5, 55), now), isNull);
    expect(asOf(DateTime.utc(2026, 9, 30, 3), now), 'as of 3h ago');
    expect(providerName('claude'), 'Claude');
    expect(hoursLeft(DateTime.utc(2026, 10, 2, 9), now), '2d');
    expect(hoursLeft(DateTime.utc(2026, 10, 1, 2), now), '20h');
    expect(hoursLeft(DateTime.utc(2026, 9, 30, 6, 40), now), '40m');
  });

  group('in the chat', () {
    AppState working(String agent, String model) => AppState()
      ..host = HostState.fromSnapshot({
        'panes': [
          {'pane_id': 'w1:p1', 'agent': agent, 'agent_status': 'idle', 'cwd': '/x'}
        ],
        'agents': [
          {'pane_id': 'w1:p1', 'agent': agent, 'agent_status': 'idle', 'cwd': '/x'}
        ],
      })
      ..selectedPaneId = 'w1:p1'
      ..transcriptLoading = false
      ..conn = ConnState.connected
      ..turns = [Turn(id: 'c0', userText: 'hi')]
      ..setContextForTest(ContextUsage(used: 1000, model: model), 258400);

    final readings = PlanUsage.fromList([
      {
        'provider': 'claude',
        'plan': 'Claude Max 5x',
        'windows': [
          {'usedPercent': 9, 'minutes': 300},
          {'label': 'Weekly', 'usedPercent': 79, 'minutes': 10080},
        ],
      },
      {
        'provider': 'codex',
        'plan': 'free',
        'windows': [
          {'usedPercent': 50, 'minutes': 43200}
        ],
      },
      {'provider': 'xai', 'error': 'No available fetch strategy for xai.'},
    ]);

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> open(WidgetTester tester, AppState state) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(state: state)));
      await settle(tester);
    }

    test("the agent's own subscription, told by its model", () {
      expect(working('claude', 'claude-opus-5').planFor(null), isNull);
      for (final (agent, model, provider) in [
        ('claude', 'claude-opus-5', 'claude'),
        ('pi', 'claude-sonnet-5', 'claude'),
        ('codex', 'gpt-6-luna', 'codex'),
        ('pi', 'grok-4.6', null),
      ]) {
        final state = working(agent, model)..setPlansForTest(readings);
        expect(state.planFor(state.selectedPane)?.provider, provider,
            reason: '$agent $model');
      }
    });

    test('a pane keeps its subscription while its model is not known', () {
      final state = working('pi', 'claude-sonnet-5')..setPlansForTest(readings);
      expect(state.planFor(state.selectedPane)?.provider, 'claude');
      // Reloading: the transcript has not said which model yet.
      state.setContextForTest(const ContextUsage(used: 0, model: ''), 258400);
      expect(state.planFor(state.selectedPane)?.provider, 'claude');
    });

    testWidgets('bars in the header open every subscription', (tester) async {
      final state = working('claude', 'claude-opus-5')
        ..setPlansForTest(readings);
      await open(tester, state);
      expect(find.byKey(const ValueKey('quota-bars')), findsOneWidget);
      // The pie carries no percentage.
      expect(find.text('0%'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('quota-bars')));
      await settle(tester);
      expect(find.text('Subscriptions'), findsOneWidget);
      expect(find.text('Claude · Claude Max 5x'), findsOneWidget);
      expect(find.text('Codex · free'), findsOneWidget);
      expect(find.text('79%'), findsOneWidget);
      expect(find.textContaining('No available fetch strategy'), findsOneWidget);
    });

    testWidgets('the cost goes there too', (tester) async {
      final state = working('codex', 'gpt-6-luna')
        ..setCostForTest(SessionCost(usd: 3))
        ..setPlansForTest(readings);
      await open(tester, state);
      await tester.tap(find.byKey(const ValueKey('context-pie')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('cost-plans')));
      await settle(tester);
      expect(find.text('Subscriptions'), findsOneWidget);
    });

    testWidgets('nothing read, no bars and the cost is only a cost',
        (tester) async {
      final state = working('codex', 'gpt-6-luna')
        ..setCostForTest(SessionCost(usd: 3));
      await open(tester, state);
      expect(find.byKey(const ValueKey('quota-bars')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('context-pie')));
      await settle(tester);
      expect(find.byKey(const ValueKey('context-cost')), findsOneWidget);
      expect(find.byKey(const ValueKey('cost-plans')), findsNothing);
    });
  });
}
