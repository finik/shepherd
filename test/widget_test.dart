import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/watcher.dart';
import 'package:shepherd/transcript/adapters.dart';
import 'package:shepherd/transcript/turn.dart';

void main() {
  _watcherTests();
  group('JsonlFramer', () {
    test('emits complete records and holds partial lines', () {
      final framer = JsonlFramer();
      final first = framer.add('{"a":1}\n{"b":2}\n{"c"').toList();
      expect(first.length, 2);
      final second = framer.add(':3}\n').toList();
      expect(second.single['c'], 3);
    });

    test('skips an oversized line without losing the next record', () {
      final framer = JsonlFramer();
      final huge = '{"big":"${'x' * (JsonlFramer.maxLine + 10)}"}';
      final out = framer.add('$huge\n{"ok":1}\n').toList();
      expect(out.length, 1);
      expect(out.single['ok'], 1);
    });

    test('malformed json does not throw', () {
      final framer = JsonlFramer();
      expect(framer.add('not json\n{"ok":1}\n').toList().length, 1);
    });
  });

  group('ClaudeAdapter', () {
    test('bare-string user content starts a turn', () {
      final a = ClaudeAdapter();
      expect(
        a.addRecord({
          'type': 'user',
          'message': {'role': 'user', 'content': 'hello'},
        }),
        isTrue,
      );
      expect(a.turns.single.userText, 'hello');
    });

    test('tool_result user messages continue the turn, not start one', () {
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {'role': 'user', 'content': 'do it'},
      });
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'content': 'output'}
          ],
        },
      });
      expect(a.turns.length, 1);
    });

    test('assistant blocks attach to the open turn', () {
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {'role': 'user', 'content': 'q'},
      });
      a.addRecord({
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': 'hmm'},
            {'type': 'text', 'text': 'answer'},
            {'type': 'tool_use', 'name': 'Bash'},
          ],
        },
      });
      final turn = a.turns.single;
      expect(turn.assistantText, 'answer');
      expect(turn.thinkingCount, 1);
      expect(turn.toolCount, 1);
    });

    test('a tool call keeps its target, arguments and result', () {
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {'role': 'user', 'content': 'q'},
      });
      a.addRecord({
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'Bash',
              'input': {'command': 'ls -la', 'description': 'List files'},
            },
            {
              'type': 'tool_use',
              'id': 'toolu_2',
              'name': 'Read',
              'input': {'file_path': '/a/b/app_state.dart'},
            },
          ],
        },
      });
      // Results come back in whatever order they finish, so they are matched
      // by id, not by position.
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 'toolu_2', 'content': 'file body'},
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_1',
              'content': 'total 0',
              'is_error': true,
            },
          ],
        },
      });
      final turn = a.turns.single;
      expect(turn.toolCount, 2);
      expect(turn.tools.first.label, 'Bash · List files');
      expect(turn.tools.first.input, contains('ls -la'));
      expect(turn.tools.first.result, 'total 0');
      expect(turn.tools.first.isError, isTrue);
      expect(turn.tools.last.label, 'Read · app_state.dart');
      expect(turn.tools.last.result, 'file body');
      expect(turn.lastActivity, 'Read · app_state.dart');
    });

    test('an attachment note joins the message it came with', () {
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {'role': 'user', 'content': '[Image #5]look at this'},
      });
      // Claude writes the file itself as a second user message.
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': '[Image: source: /tmp/herdr-clipboard-images-501/a.jpg]',
        },
      });
      a.addRecord({
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'I see it.'}
          ],
        },
      });
      // One exchange, and the reply belongs to it.
      expect(a.turns.length, 1);
      expect(a.turns.single.assistantText, 'I see it.');
    });

    test('a tool result alone does not open a turn', () {
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 'x', 'content': 'out'}
          ],
        },
      });
      expect(a.turns, isEmpty);
    });

    test('reasoning and calls keep the order they happened in', () {
      final records = [
        {
          'type': 'user',
          'message': {'role': 'user', 'content': 'q'},
        },
        {
          'type': 'assistant',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'thinking', 'thinking': 'first thought'},
              {'type': 'tool_use', 'id': 't1', 'name': 'Read', 'input': {}},
              // Prose in the middle of the turn, not at the end of it.
              {'type': 'text', 'text': 'Checked the file.'},
              {'type': 'thinking', 'thinking': 'second thought'},
              {'type': 'tool_use', 'id': 't2', 'name': 'Edit', 'input': {}},
              {'type': 'text', 'text': 'Fixed it.'},
            ],
          },
        },
      ];
      final a = ClaudeAdapter();
      for (final r in records) {
        a.addRecord(r);
      }
      List<String> shape(Turn t) => [
            for (final step in t.steps)
              switch (step) {
                ToolCall() => step.name,
                Reasoning() => step.text,
                Reply() => step.text,
                Failure() => 'failure',
                ImageRef() => 'image',
              }
          ];
      const expected = [
        'first thought',
        'Read',
        'Checked the file.',
        'second thought',
        'Edit',
        'Fixed it.',
      ];
      expect(shape(a.turns.single), expected);

      // Parsing happens in an isolate, so the order has to survive being
      // flattened to maps and rebuilt.
      final roundTrip = turnsFromMaps(parseTranscript({
        'agent': 'claude',
        'text': records.map(jsonEncode).join('\n') + '\n',
      }));
      expect(shape(roundTrip.single), expected);
    });

    test('bookkeeping record types are ignored', () {
      final a = ClaudeAdapter();
      for (final t in ['queue-operation', 'attachment', 'atis-latch', 'mode']) {
        expect(a.addRecord({'type': t}), isFalse);
      }
      expect(a.turns, isEmpty);
    });
  });

  group('PiAdapter', () {
    test('block-array content and toolResult role', () {
      final a = PiAdapter();
      a.addRecord({
        'type': 'message',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi'}
          ],
        },
      });
      a.addRecord({
        'type': 'message',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'toolCall', 'name': 'read'},
            {'type': 'text', 'text': 'done'},
          ],
        },
      });
      a.addRecord({
        'type': 'message',
        'message': {'role': 'toolResult', 'toolName': 'read', 'content': []},
      });
      final turn = a.turns.single;
      expect(turn.userText, 'hi');
      expect(turn.assistantText, 'done');
      // One call, one result — not a second call standing in for the result.
      expect(turn.toolCount, 1);
    });

    test('Pi results attach to the call they answer', () {
      final a = PiAdapter();
      a.addRecord({
        'type': 'message',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi'}
          ],
        },
      });
      a.addRecord({
        'type': 'message',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'toolCall',
              'id': 'call-1',
              'name': 'read',
              // Some Pi builds write the arguments as a JSON string.
              'arguments': '{"path": "/x/y/notes.md"}',
            },
          ],
        },
      });
      a.addRecord({
        'type': 'message',
        'message': {
          'role': 'toolResult',
          'toolCallId': 'call-1',
          'toolName': 'read',
          'content': [
            {'type': 'text', 'text': 'note body'}
          ],
        },
      });
      final turn = a.turns.single;
      expect(turn.toolCount, 1);
      expect(turn.tools.single.label, 'read · notes.md');
      expect(turn.tools.single.result, 'note body');
    });

    test('an errored turn shows why instead of nothing', () {
      final a = PiAdapter();
      a.addRecord({
        'type': 'message',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'add a zoom control'}
          ],
        },
      });
      // What an expired token actually writes: an assistant message with no
      // content at all, and the reason alongside it.
      expect(
        a.addRecord({
          'type': 'message',
          'message': {
            'role': 'assistant',
            'content': [],
            'stopReason': 'error',
            'errorMessage': 'OAuth refresh failed for xai: invalid_grant',
          },
        }),
        isTrue,
      );
      expect(a.turns.single.errors.single, contains('invalid_grant'));
      expect(a.turns.single.hasContent, isTrue);
    });

    test('non-message records ignored', () {
      final a = PiAdapter();
      expect(a.addRecord({'type': 'model_change'}), isFalse);
      expect(a.addRecord({'type': 'session'}), isFalse);
    });
  });

  group('framing', () {
    test('a chunk without a trailing newline still yields its last record',
        () {
      // Preview chunks end where the next pane's marker begins, so the last
      // record arrives unterminated.
      const record = '{"type":"message","message":{"role":"assistant",'
          '"content":[{"type":"text","text":"last"}]}}';
      expect(JsonlFramer().add(record).length, 0);
      expect(JsonlFramer().add('$record\n').length, 1);
    });
  });

  group('attachment markers', () {
    test('a staged path becomes the file it is', () {
      const path = '/var/folders/c1/x/T/shepherd-uploads-501/'
          'mf3k2-fares.csv';
      final result = withoutStagedPaths('does this match $path ?');
      expect(result.text, 'does this match [fares.csv] ?');
      expect(result.files, ['fares.csv']);
    });

    test('a picture pasted into Herdr is recognised too', () {
      const path = '/var/folders/c1/x/T/herdr-clipboard-images-501/'
          'shepherd-1790027268032.jpg';
      final result = withoutStagedPaths('why is the crop off in $path ?');
      expect(result.files.single, endsWith('.jpg'));
    });

    test('a message with no attachment is untouched', () {
      final result = withoutStagedPaths('read README.md');
      expect(result.text, 'read README.md');
      expect(result.files, isEmpty);
    });
  });

  group('session naming', () {
    test('a codex pane waiting on you keeps its name', () {
      // While it waits Codex retitles itself "[ . ] Action Required | …".
      final pane = Pane(
        paneId: 'wD:p2',
        tabId: 'wD:t1',
        workspaceId: 'wD',
        agent: 'codex',
        cwd: '/Users/x/work/shepherd',
        title: '[ . ] Action Required | Describe tool/publish.sh | shepherd',
      );
      expect(pane.sessionName, 'Describe tool/publish.sh');
    });

    test('a codex pane is named by what it is doing', () {
      // Codex writes "<thread name> | <folder>"; the folder is already the
      // row's location, so only the thread name is worth the space.
      final pane = Pane(
        paneId: 'wD:p2',
        tabId: 'wD:t1',
        workspaceId: 'wD',
        agent: 'codex',
        cwd: '/Users/x/work/shepherd',
        title: 'Describe tool/publish.sh | shepherd',
      );
      expect(pane.sessionName, 'Describe tool/publish.sh');
    });


    test('an opencode pane is named by its session, not its initials', () {
      final pane = Pane(
        paneId: 'w11:p1',
        tabId: 'w11:t1',
        workspaceId: 'w11',
        agent: 'opencode',
        cwd: '/Users/x/work/cart',
        title: 'OC | flag.png description and cart discoun…',
      );
      expect(pane.sessionName, 'flag.png description and cart discoun…');
    });

    test('an omp pane is named by its session, not its prompt glyph', () {
      final pane = Pane(
        paneId: 'w16:p1',
        tabId: 'w16:t1',
        workspaceId: 'w16',
        agent: 'omp',
        cwd: '/Users/x/work/cart',
        title: 'π > Describe picture and add discount',
      );
      expect(pane.sessionName, 'Describe picture and add discount');
    });

    test('an omp pane waiting on you keeps its name', () {
      final pane = Pane(
        paneId: 'w16:p1',
        tabId: 'w16:t1',
        workspaceId: 'w16',
        agent: 'omp',
        cwd: '/Users/x/work/cart',
        title: 'π ! Describe picture and add discount',
      );
      expect(pane.sessionName, 'Describe picture and add discount');
    });

    test('a name you set outranks whatever the program writes', () {
      final pane = Pane(
        paneId: 'w6:p1',
        tabId: 'w6:t1',
        workspaceId: 'w6',
        agent: 'pi',
        cwd: '/Users/x/work/ledger',
        // Pi rewrites the terminal title as the session goes on.
        title: 'Downloads,-read-it · Off',
        label: 'ledger',
      );
      expect(pane.sessionName, 'ledger');
    });

    Pane withTitle(String? title, String cwd) => Pane(
          paneId: 'w1:p1',
          tabId: 'w1:t1',
          workspaceId: 'w1',
          agent: 'pi',
          cwd: cwd,
          title: title,
        );

    test('a title that just restates the folder is not shown twice', () {
      final p = withTitle('π - atlas', '/Users/x/work/atlas');
      expect(p.hasMeaningfulTitle, isFalse);
      expect(p.sessionName, 'atlas');
    });

    test('a folder repeated in the title is dropped entirely', () {
      // Pi emits this shape verbatim.
      final p = withTitle('π - ledger - ledger', '/Users/x/ledger');
      expect(p.hasMeaningfulTitle, isFalse);
      expect(p.sessionName, 'ledger');
    });

    test('the agent name in the title is not repeated back', () {
      expect(withTitle('pi - almanac', '/x/almanac').sessionName, 'almanac');
    });

    test('a real name survives alongside noise', () {
      final p = withTitle('π - atlas - refactor the framer', '/x/atlas');
      expect(p.sessionName, 'refactor the framer');
    });

    test('punctuation and case do not rescue a duplicate title', () {
      expect(withTitle('HA-Dashboard', '/x/ha-dashboard').hasMeaningfulTitle,
          isFalse);
    });

    test('a title about the work is kept', () {
      final p = withTitle('Read current folder files', '/Users/x/shepherd');
      expect(p.hasMeaningfulTitle, isTrue);
      expect(p.sessionName, 'Read current folder files');
    });

    test('no title falls back to the folder', () {
      expect(withTitle(null, '/Users/x/almanac').sessionName, 'almanac');
      expect(withTitle('   ', '/Users/x/almanac').sessionName, 'almanac');
    });
  });
}

void _watcherTests() {
  group('watcher', () {
    test('a first sighting is never news', () {
      expect(worthSaying(null, 'done'), isNull);
      expect(worthSaying(null, 'blocked'), isNull);
    });

    test('finishing counts only if we watched it work', () {
      expect(worthSaying('working', 'done'), 'Finished');
      expect(worthSaying('working', 'idle'), 'Finished');
      expect(worthSaying('idle', 'done'), isNull);
      expect(worthSaying('done', 'done'), isNull);
    });

    test('blocked is worth saying however it was reached', () {
      expect(worthSaying('working', 'blocked'), 'Waiting for your answer');
      expect(worthSaying('idle', 'blocked'), 'Waiting for your answer');
    });
  });
}
