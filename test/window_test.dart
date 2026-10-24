import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/transcript/adapters.dart';
import 'package:shepherd/transcript/turn.dart';

/// The window of a transcript the host sends when a chat opens: it reaches
/// back far enough to hold a few things you said, and the phone makes the
/// conversation out of it.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('window'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// The conversation the phone shows from the window over [records].
  List<Turn> opened(List<Map<String, dynamic>> records, {int wanted = 2}) {
    final transcript = File('${dir.path}/session.jsonl')
      ..writeAsStringSync('${records.map(jsonEncode).join('\n')}\n');
    final script = File('${dir.path}/window.py')
      ..writeAsStringSync(AppState.windowScriptForTest);
    // A window too small for even one record, so it has to widen.
    final out = Process.runSync(
        'python3', [script.path, transcript.path, '64', '$wanted']);
    expect(out.exitCode, 0, reason: out.stderr as String);
    final lines = (out.stdout as String).split('\n');
    expect(lines[0], startsWith('SZ '));
    expect(lines[1], startsWith('ST '));
    return turnsFromMaps(parseTranscript(
        {'text': lines.skip(2).join('\n'), 'agent': 'claude', 'base': '0'}));
  }

  Map<String, dynamic> typed(String text) => {
        'type': 'user',
        'promptSource': 'typed',
        'message': {'role': 'user', 'content': text},
      };

  Map<String, dynamic> reply(String text) => {
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': text}
          ],
        },
      };

  test('what you said is counted, not what was said to the agent for you', () {
    final turns = opened([
      typed('first question'),
      reply('first answer'),
      typed('second question'),
      reply('second answer'),
      // A background task, another session and Claude's own note, then the
      // copy of a request Claude keeps: none of them starts a turn.
      {
        'type': 'user',
        'promptSource': 'system',
        'message': {'role': 'user', 'content': '<task-notification>done</task-notification>'},
      },
      reply('the task finished'),
      {
        'type': 'user',
        'isMeta': true,
        'message': {
          'role': 'user',
          'content': 'Another Claude session sent a message: hello'
        },
      },
      reply('answered the other session'),
      {
        'type': 'api-request-blob',
        'message': {'role': 'user', 'content': 'the whole request again'},
      },
      {
        'type': 'user',
        'isMeta': true,
        'message': {'role': 'user', 'content': 'Tool loaded.'},
      },
    ]);
    expect(turns.map((t) => t.userText), ['first question', 'second question']);
    // What the agent did after them stays with the last thing you said.
    expect(turns.last.steps.whereType<Reply>().map((r) => r.text), [
      'second answer',
      'the task finished',
      'answered the other session',
    ]);
  });
}
