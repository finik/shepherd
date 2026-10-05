import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/ui/blocked_prompt.dart';

/// Claude's question that takes several answers: boxes to tick, "Next" to
/// move on to the following question, and a review before submitting.
void main() {
  String screen(String name) =>
      File('test/fixtures/$name.ansi').readAsStringSync();

  test('the boxes are read as boxes, and Next as a control', () {
    final asked = AppState.parsePrompt(screen('claude_multiselect'));
    expect(asked.question, 'Which fruits?');
    expect(asked.choices.map((c) => c.label).take(4),
        ['Apple', 'Banana', 'Cherry', 'Type something']);
    expect(asked.choices.take(4).map((c) => c.checked),
        [false, false, false, false]);
    expect(asked.choices.first.detail, 'A crisp red or green fruit');
    // Not the description of the option above it.
    expect(asked.choices[3].detail, isEmpty);
    expect(asked.choices[3].typed, isTrue);
    // "Chat about this" is a plain option, below the boxes.
    expect(asked.choices.last.checked, isNull);
  });

  test('only the boxes that differ are visited, then Next', () {
    final asked = AppState.parsePrompt(screen('claude_multiselect'));
    // The cursor is on Apple. Tick Apple and Cherry; Next is below
    // "Type something".
    expect(AppState.checkKeys(asked, {1, 3}),
        ['enter', 'down', 'down', 'enter', 'down', 'down', 'enter']);
    // Nothing ticked: straight to Next.
    expect(AppState.checkKeys(asked, {}),
        ['down', 'down', 'down', 'down', 'enter']);
  });

  test('a box already ticked is left alone, or unticked', () {
    const asked = (
      question: 'Which?',
      choices: [
        Choice(label: 'A', checked: true, selected: true),
        Choice(label: 'B', checked: false),
        Choice(label: 'Type something', checked: false),
      ],
    );
    expect(AppState.checkKeys(asked, {1}), ['down', 'down', 'down', 'enter']);
    expect(AppState.checkKeys(asked, {2}),
        ['enter', 'down', 'enter', 'down', 'down', 'enter']);
  });

  test('the review shows what is being submitted', () {
    final asked = AppState.parsePrompt(screen('claude_review'));
    expect(asked.question, contains('Ready to submit your answers?'));
    expect(asked.question, contains('Which fruits?'));
    expect(asked.choices.map((c) => c.label), ['Submit answers', 'Cancel']);
  });

  testWidgets('ticked on the phone, sent with Next', (tester) async {
    final asked = AppState.parsePrompt(screen('claude_multiselect'));
    Set<int>? sent;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: BlockedPrompt(
            asked: asked,
            onAnswer: (_) {},
            onChecks: (ticked) => sent = ticked,
          ),
        ),
      ),
    ));
    expect(find.text('Apple'), findsOneWidget);
    // Written answers cannot be given here.
    expect(find.text('Type something'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('check-1')));
    await tester.tap(find.byKey(const ValueKey('check-3')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('checks-next')));
    expect(sent, {1, 3});
  });
}
