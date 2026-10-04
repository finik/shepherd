import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/transcript/turn.dart';

/// The phone holds the recent end of a conversation, and of a long turn.
void main() {
  test("a long turn keeps its last steps and everything it said", () {
    final turn = Turn(id: 'c0', userText: 'go')
      ..steps.addAll([
        for (var i = 0; i < 5; i++) ToolCall(id: 't$i', name: 'Bash'),
        const Reply('halfway'),
        for (var i = 5; i < 10; i++) ToolCall(id: 't$i', name: 'Bash'),
        const Reply('done'),
      ]);
    turn.trimSteps(4);
    expect(turn.earlierSteps, 6);
    expect(turn.tools.map((t) => t.id), ['t6', 't7', 't8', 't9']);
    // What the agent said stays, however early.
    expect(turn.assistantTexts, ['halfway', 'done']);
  });

  test('a short turn is left alone', () {
    final turn = Turn(id: 'c0', userText: 'go')
      ..steps.add(ToolCall(id: 't0', name: 'Read'));
    turn.trimSteps(4);
    expect(turn.earlierSteps, 0);
    expect(turn.tools.length, 1);
  });
}
