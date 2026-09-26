import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/transcript/adapters.dart';

/// OpenCode's question panel, as `pane.read` returns it with colours kept.
///
/// The panel sits behind a `┃` gutter, the sidebar shares its lines, and the
/// selected option is marked by colour alone. `_0` has the cursor on the
/// first option, `_1` on the second.
void main() {
  String screen(int n) =>
      File('test/fixtures/opencode_question_$n.ansi').readAsStringSync();

  test('the question and its options are read out of the panel', () {
    final asked = AppState.parsePrompt(screen(0));
    expect(asked.question, 'How should the discount parameter be interpreted?');
    expect(asked.choices.map((c) => c.label), [
      'Fixed amount (Recommended)',
      'Percentage (0-1 or 0-100)',
      'Type your own answer',
    ]);
  });

  test('the sidebar is not part of any option', () {
    final asked = AppState.parsePrompt(screen(0));
    expect(asked.choices[1].detail,
        'total(prices, discount=0) -> sum(prices) * (1 - discount)');
  });

  test('the highlighted option is the selected one', () {
    expect(AppState.parsePrompt(screen(0)).choices.map((c) => c.selected),
        [true, false, false]);
    expect(AppState.parsePrompt(screen(1)).choices.map((c) => c.selected),
        [false, true, false]);
  });

  test('answering counts from wherever the cursor is', () {
    expect(AppState.menuKeys(AppState.parsePrompt(screen(1)), 1),
        ['up', 'enter']);
  });

  String permission(int n) =>
      File('test/fixtures/opencode_permission_$n.ansi').readAsStringSync();

  test('a permission prompt offers its buttons', () {
    final asked = AppState.parsePrompt(permission(0));
    expect(asked.choices.map((c) => c.label),
        ['Allow once', 'Allow always', 'Reject']);
    expect(asked.question, contains('Access external directory /etc'));
    expect(asked.question, contains('/etc/*'));
    // The sidebar shares the panel's lines, and none of it is the question.
    expect(asked.question, isNot(contains('Connect provider')));
    expect(asked.question, isNot(contains('Gemini')));
  });

  test('the highlighted button is the selected one', () {
    expect(AppState.parsePrompt(permission(0)).choices.map((c) => c.selected),
        [true, false, false]);
    expect(AppState.parsePrompt(permission(1)).choices.map((c) => c.selected),
        [false, true, false]);
  });

  test('a row of buttons is answered with left and right', () {
    expect(AppState.menuKeys(AppState.parsePrompt(permission(0)), 3),
        ['right', 'right', 'enter']);
    expect(AppState.menuKeys(AppState.parsePrompt(permission(1)), 1),
        ['left', 'enter']);
  });

  test("Pi's question tool is read like any other menu", () {
    final asked = AppState.parsePrompt(
        File('test/fixtures/pi_question.ansi').readAsStringSync());
    expect(asked.question, 'Should total() in cart.py round to cents?');
    expect(asked.choices.map((c) => c.label), [
      'Yes, round to cents',
      'No, keep full precision',
      'Type something.',
    ]);
    expect(asked.choices.first.selected, isTrue);
    expect(asked.choices[1].detail, startsWith('Return the unrounded sum'));
  });

  test("omp's ask menu is read out of its box", () {
    final asked = AppState.parsePrompt(
        File('test/fixtures/omp_question.ansi').readAsStringSync());
    expect(asked.question, 'Should cart_total round to cents?');
    expect(asked.choices.map((c) => c.label),
        ['Round to cents', 'Leave unrounded', 'Other (type your own)']);
    expect(asked.choices.map((c) => c.selected), [true, false, false]);
    expect(asked.choices[1].detail, startsWith('Return the raw sum'));
    expect(AppState.menuKeys(asked, 2), ['down', 'enter']);
  });

  test("omp's approval is read as a menu with its command", () {
    final asked = AppState.parsePrompt(
        File('test/fixtures/omp_permission.ansi').readAsStringSync());
    expect(asked.choices.map((c) => c.label), ['Approve', 'Deny']);
    expect(asked.choices.map((c) => c.selected), [true, false]);
    expect(asked.question, 'Allow tool: bash\nCommand: wc -l cart.py');
    expect(AppState.menuKeys(asked, 2), ['down', 'enter']);
  });

  test('an opencode pane is read with the Pi parser', () {
    expect(TranscriptAdapter.forAgent('opencode'), isA<PiAdapter>());
  });
}
