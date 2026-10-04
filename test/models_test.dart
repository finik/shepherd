import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';

/// Model pickers as the agents draw them, read to find the way to a model.
void main() {
  String screen(String name) =>
      File('test/fixtures/$name.txt').readAsStringSync();

  const codex = ['GPT-6-Luna', 'GPT-5.6-Terra', 'GPT-5.6-Luna', 'GPT-5.5'];
  const muse = [
    'muse-spark-1.3',
    'muse-spark-1.3-contributor',
    'muse-spark-1.2',
    'muse-spark-1.2-contributor',
  ];

  test("Codex's list is moved from the current model", () {
    // The cursor is on GPT-5.6-Luna, the third row.
    expect(AppState.pickerKeys(screen('codex_picker'), codex, 'GPT-6-Luna'),
        ['up', 'up', 'enter']);
    expect(AppState.pickerKeys(screen('codex_picker'), codex, 'GPT-5.5'),
        ['down', 'enter']);
  });

  test("a model whose name starts another's is not taken for it", () {
    // The cursor is on muse-spark-1.3-contributor, the second row.
    expect(AppState.pickerKeys(screen('muse_picker'), muse, 'muse-spark-1.3'),
        ['up', 'enter']);
    expect(
        AppState.pickerKeys(
            screen('muse_picker'), muse, 'muse-spark-1.2-contributor'),
        ['down', 'down', 'enter']);
  });

  test("Codex's reasoning level is kept to the session with s", () {
    const levels = [
      'None', 'Minimal', 'Low', 'Medium', 'High', 'Extra high',
      'More reasoning…'
    ];
    // The cursor is on Medium. High is not taken for Extra high.
    expect(
        AppState.pickerKeys(screen('codex_effort'), levels, 'High',
            confirm: 's'),
        ['down', 's']);
    expect(
        AppState.pickerKeys(screen('codex_effort'), levels, 'Extra high',
            confirm: 's'),
        ['down', 'down', 's']);
    // Max is a level down.
    expect(AppState.pickerKeys(screen('codex_effort'), levels, 'More reasoning…'),
        ['down', 'down', 'down', 'enter']);
    expect(
        AppState.pickerKeys(screen('codex_effort_more'), const ['Max', 'Ultra'],
            'Max', confirm: 's'),
        ['s']);
  });

  test("muse's effort list: high is not taken for xhigh", () {
    const levels = [
      'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'
    ];
    expect(AppState.pickerKeys(screen('muse_effort'), levels, 'high'),
        ['up', 'up', 'enter']);
  });

  test('without a model chosen, the efforts are the agent\'s own', () {
    expect(AppState.effortsFor('claude', const []), contains('xhigh'));
    expect(AppState.effortsFor('pi', const []).first, 'off');
    expect(
        AppState.effortsFor('codex', const [
          ModelOption(id: 'a', label: 'A', efforts: ['low', 'high']),
          ModelOption(id: 'b', label: 'B', efforts: ['high', 'ultra']),
        ]),
        ['low', 'high', 'ultra']);
  });

  test('a model the list does not show is not guessed at', () {
    expect(AppState.pickerKeys(screen('codex_picker'), codex, 'gpt-7'), isNull);
    expect(AppState.pickerKeys('no list here', codex, 'GPT-5.5'), isNull);
  });

  test('every agent has a flag for its model at start', () {
    for (final h in AppState.harnesses.keys) {
      expect(AppState.modelFlags[h], isNotNull, reason: h);
    }
  });
}
