import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/ui/blocked_prompt.dart';
import 'package:shepherd/ui/design.dart';

/// The one control in the app that agrees to something on your behalf.
void main() {
  const asked = (
    question: 'Do you want to make this edit to notes.md?',
    choices: [
      Choice(label: 'Yes'),
      Choice(
        label: 'Yes, and switch to accept edits',
        detail: 'Auto-approve file edits and common file commands for the '
            'rest of this session.',
      ),
      Choice(label: 'No, and tell Claude what to do differently'),
    ],
  );

  Future<int?> pump(WidgetTester tester) async {
    int? answered;
    await tester.pumpWidget(MaterialApp(
      theme: D.theme(Brightness.light),
      home: Scaffold(
        body: BlockedPrompt(
          asked: asked,
          onAnswer: (choice) => answered = choice,
        ),
      ),
    ));
    return answered;
  }

  testWidgets('one answer is shown, not three', (tester) async {
    await pump(tester);
    expect(find.text('Yes'), findsOneWidget);
    expect(find.textContaining('tell Claude'), findsNothing);
  });

  testWidgets('an answer is shown in full, never cropped', (tester) async {
    // The whole point: a consent button that has been cut short can read as a
    // different answer than the one it sends.
    await pump(tester);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    final text = tester.widget<Text>(find.textContaining('accept edits'));
    expect(text.data, asked.choices[1].label);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    // And the small print rides along with it, which is the point of showing
    // one answer at a time.
    expect(find.textContaining('rest of this session'), findsOneWidget);
  });

  testWidgets('OK sends the number of the answer on screen', (tester) async {
    int? answered;
    await tester.pumpWidget(MaterialApp(
      theme: D.theme(Brightness.light),
      home: Scaffold(
        body: BlockedPrompt(
          asked: asked,
          onAnswer: (choice) => answered = choice,
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    await tester.tap(find.text('OK'));
    expect(answered, 3);
  });

  testWidgets('the ends wrap rather than dead-ending', (tester) async {
    await pump(tester);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    expect(find.textContaining('tell Claude'), findsOneWidget);
  });

  testWidgets('a question with no menu has nothing to press', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: D.theme(Brightness.light),
      home: const Scaffold(
        body: BlockedPrompt(
          asked: (question: 'What should I call it?', choices: <Choice>[]),
          onAnswer: _ignore,
        ),
      ),
    ));
    expect(find.text('What should I call it?'), findsOneWidget);
    expect(find.text('OK'), findsNothing);
  });
}

void _ignore(int _) {}
