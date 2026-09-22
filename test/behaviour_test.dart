import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/transcript/adapters.dart';
import 'package:shepherd/herdr/models.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/state/transcript_cache.dart';
import 'package:shepherd/state/uploads.dart';
import 'package:shepherd/transcript/turn.dart';

/// Behaviour seen from the phone, grouped by what the user sees rather than
/// by the unit that implements it.
void main() {
  group('pictures in the conversation', () {
    test('an image in a message becomes a reference, not its bytes', () {
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look at this'},
            {
              'type': 'image',
              'source': {'type': 'base64', 'media_type': 'image/jpeg',
                  'data': 'AAAA'},
            },
          ],
        },
      });
      final step = a.turns.single.steps.single as ImageRef;
      expect(step.mediaType, 'image/jpeg');
    });

    test('a picture says how big it is before you fetch it', () {
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look'},
            {
              'type': 'image',
              // 200,000 characters of base64 is about 150KB of picture.
              'source': {'media_type': 'image/jpeg', 'data': 'A' * 200000},
            },
          ],
        },
      });
      final picture = a.turns.single.images.single;
      expect(picture.bytes, closeTo(150000, 1000));
    });

    test('a size reported by the host is used as given', () {
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look'},
            {
              'type': 'image',
              // The backfill arrives with payloads stripped and sizes stated.
              'source': {'media_type': 'image/png', 'data': '', '__bytes': 4242},
            },
          ],
        },
      });
      expect(a.turns.single.images.single.bytes, 4242);
    });

    test('a thumbnail made on the host reaches the reference', () {
      // The host sends a few kilobytes of picture with the window so the row
      // is a picture from the start.
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {'role': 'user', 'content': 'take a look'},
      });
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 't1',
              'content': [
                {
                  'type': 'image',
                  'source': {
                    'media_type': 'image/png',
                    'data': '',
                    '__bytes': 293000,
                    '__thumb': 'c21hbGw=',
                  },
                }
              ],
            }
          ],
        },
      });
      expect(a.turns.single.images.single.thumb, 'c21hbGw=');
    });

    test('a picture returned by a tool is shown', () {
      // Screenshots and vision results arrive nested inside the tool result.
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {'role': 'user', 'content': 'take a look'},
      });
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 't1',
              'content': [
                {
                  'type': 'image',
                  'source': {'media_type': 'image/png', '__bytes': 293000},
                }
              ],
            }
          ],
        },
      });
      final picture = a.turns.single.images.single;
      expect(picture.mediaType, 'image/png');
      expect(picture.bytes, 293000);
    });

    test('an attachment note keeps its picture', () {
      // The note joins the message it came with, and the image inside it is
      // the attachment.
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {'role': 'user', 'content': '[Image #5]look at this'},
      });
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '[Image: original 1080x2410]'},
            {'type': 'image', 'source': {'media_type': 'image/png', 'data': 'AA'}},
          ],
        },
      });
      expect(a.turns.length, 1);
      expect(a.turns.single.images.length, 1);
    });

    test('a record too big to parse still shows as a picture', () {
      // Pi images run to tens of megabytes; the framer drops the line but
      // still reports that a picture was there.
      final a = PiAdapter();
      a.addRecord({
        'type': 'message',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'scan this'}
          ],
        },
      });
      expect(a.addRecord(const {'__dropped': 'image'}), isTrue);
      expect(a.turns.single.images.length, 1);
    });

    test('a dropped picture still moves the count past itself', () {
      // A record too big to hold is skipped, but its bytes are still in the
      // file and still count towards every later offset.
      final framer = JsonlFramer();
      final huge = jsonEncode({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'image', 'source': {'type': 'base64', 'data': 'A' * 300000}}
          ],
        },
      });
      final after = jsonEncode({'type': 'user', 'message': 'after'});
      final records = <Map<String, dynamic>>[];
      // Fed in pieces, the way a tail delivers it.
      for (var i = 0; i < huge.length; i += 8192) {
        records.addAll(framer
            .add(huge.substring(i, math.min(i + 8192, huge.length))));
      }
      records.addAll(framer.add('\n$after\n'));
      expect(records.first['__dropped'], 'image');
      expect(records.first['__offset'], 0);
      expect(records.last['__offset'], huge.length + 1);
    });

    test('a reference points at the record, so growth cannot move it', () {
      final maps = parseTranscript({
        'agent': 'claude',
        'text': [
          jsonEncode({
            'type': 'user',
            'message': {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'first'},
                {'type': 'image', 'source': {'media_type': 'image/png'}},
              ],
            },
          }),
          jsonEncode({
            'type': 'user',
            'message': {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'second'},
                {'type': 'image', 'source': {'media_type': 'image/png'}},
              ],
            },
          }),
        ].join('\n') + '\n',
      });
      final turns = turnsFromMaps(maps);
      // The second record starts where the first one ended.
      final first = turns.first.images.single.offset;
      final second = turns.last.images.single.offset;
      expect(first, 0);
      expect(second, greaterThan(first));
    });
  });

  group('answering a menu', () {
    // Claude's question with a preview beside its options ignores a digit —
    // its footer says "Enter to select · ↑/↓ to navigate". Every menu
    // answers to the arrow keys and Enter.
    ({String question, List<Choice> choices}) menu(int cursor) => (
          question: 'Pick one?',
          choices: [
            for (var i = 0; i < 3; i++)
              Choice(label: 'option ${i + 1}', selected: i == cursor),
          ],
        );

    test('the option under the cursor is one Enter', () {
      expect(AppState.menuKeys(menu(0), 1), ['enter']);
    });

    test('further down is that many downs, then Enter', () {
      expect(AppState.menuKeys(menu(0), 3), ['down', 'down', 'enter']);
    });

    test('a cursor someone moved at the desktop is counted from', () {
      expect(AppState.menuKeys(menu(2), 1), ['up', 'up', 'enter']);
    });

    test('the cursor is read off the screen', () {
      final asked = AppState.parsePrompt(
          'Pick one?\n  1. first\n❯ 2. second\n  3. third\n');
      expect(asked.choices.map((c) => c.selected), [false, true, false]);
      // Codex marks it with a different character.
      final codex = AppState.parsePrompt(
          'Would you like to run it?\n› 1. Yes, proceed (y)\n  2. No (esc)\n');
      expect(codex.choices.first.selected, isTrue);
    });
  });

  group('a question with a preview beside its options', () {
    // Captured off a live Claude pane. When the options carry a preview,
    // Claude draws it as a box to their right on the same lines, and the
    // first label wraps onto a second.
    const screen =
        '❯ Fix it. Before you edit anything, use your question tool to ask me which approach to take, with three options.\n'
        '\n'
        '────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n'
        ' ☐ Approach\n'
        '\n'
        'How should shipping be modeled so FREESHIP can actually waive it?\n'
        '\n'
        '❯ 1. Shipping param               ┌───────────────────────────────────────────────────────────────┐\n'
        '    (Recommended)                 │ export function applyCoupon(                                  │\n'
        '  2. Breakdown object             │   subtotal: number,                                           │\n'
        '  3. Separate shippingFor()       │   shipping: number,                                           │\n'
        '                                  │   code: string,                                               │\n'
        '                                  │ ): number {                                                   │\n'
        '                                  │   if (code === "WELCOME10") return subtotal * 0.9 + shipping; │\n'
        '                                  │   if (code === "FREESHIP") return subtotal;                   │\n'
        '                                  │   return subtotal + shipping;                                 │\n'
        '                                  │ }                                                             │\n'
        '                                  └───────────────────────────────────────────────────────────────┘\n'
        '\n'
        '                                  Notes: press n to add notes\n'
        '\n'
        '────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n'
        '  Chat about this\n'
        '\n'
        'Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel\n'
        '\n';

    test('the options are the options, not the code beside them', () {
      expect(AppState.parsePrompt(screen).choices.map((c) => c.label), [
        'Shipping param (Recommended)',
        'Breakdown object',
        'Separate shippingFor()',
      ]);
    });

    test('a wrapped "(Recommended)" is part of the name', () {
      expect(AppState.parsePrompt(screen).choices.first.detail, isEmpty);
    });

    test('the question is the question', () {
      expect(AppState.parsePrompt(screen).question,
          'How should shipping be modeled so FREESHIP can actually waive it?');
    });
  });

  group('Codex approval menus', () {
    // Captured off a live Codex pane. Its menu marks the selection with `›`
    // where Claude draws `❯`.
    const screen =
        '› why is the machine so loaded, what is taking all the resources\n'
        '\n'
        '\n'
        '• I’ll check the current process and system resource usage to see what’s driving the load.\n'
        '\n'
        '• Ran ps -Ao pid,ppid,%cpu,%mem,etime,comm | sort -k3 -nr | head -20\n'
        '  └ zsh:1: operation not permitted: ps\n'
        '\n'
        '• Running ps -Ao pid,ppid,%cpu,%mem,etime,comm | sort -k3 -nr | head -20\n'
        '\n'
        '\n'
        '  Would you like to run the following command?\n'
        '\n'
        '  Environment: local\n'
        '\n'
        '  Reason: May I inspect the running process list to identify what is using the machine\'s resources?\n'
        '\n'
        '  \$ ps -Ao pid,ppid,%cpu,%mem,etime,comm | sort -k3 -nr | head -20\n'
        '\n'
        '\n'
        '› 1. Yes, proceed (y)\n'
        '  2. Yes, and don\'t ask again for commands that start with `ps -Ao \'pid,ppid,%cpu,%mem,etime,comm\'` (p)\n'
        '  3. No, and tell Codex what to do differently (esc)\n'
        '\n'
        '  Press enter to confirm or esc to cancel\n'
        '\n';

    test('all three options are offered', () {
      final asked = AppState.parsePrompt(screen);
      expect(asked.choices.map((c) => c.label), [
        'Yes, proceed',
        "Yes, and don't ask again for commands that start with "
            "`ps -Ao 'pid,ppid,%cpu,%mem,etime,comm'`",
        'No, and tell Codex what to do differently',
      ]);
    });

    test('the question is the question, not the reason under it', () {
      expect(AppState.parsePrompt(screen).question,
          startsWith('Would you like to run the following command?'));
    });

    test('the command being approved comes with the question', () {
      // Consenting to "run the following command" without the command on
      // screen is consenting blind.
      expect(AppState.parsePrompt(screen).question,
          contains(r'$ ps -Ao pid,ppid,%cpu,%mem,etime,comm'));
    });

    test('keyboard hints are not part of the answer', () {
      final labels = AppState.parsePrompt(screen).choices.map((c) => c.label);
      expect(labels.where((l) => l.endsWith('(y)') || l.endsWith('(esc)')),
          isEmpty);
    });
  });

  group('reading a question off the screen', () {
    // Captured verbatim off a live Claude Code pane. Each option carries an
    // indented explanation, and that explanation is the whole reason to
    // choose one over another.
    const menu =
        '  Want me to retry adding pick up prescription?\n'
        '\n'
        '✻ Sautéed for 11s · done 12:13 PM\n'
        '\n'
        '❯ Use your question tool to ask me whether new notes should go at the top or the bottom of the file, with three options.\n'
        '────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n'
        ' ☐ Note order\n'
        '\n'
        'Where should new notes go in notes.md?\n'
        '\n'
        '❯ 1. Append to bottom (Recommended)\n'
        '     New items go at the end of the Errands list, preserving the order they were added — this is what the file does today.\n'
        '  2. Prepend to top\n'
        '     New items go at the top of the Errands list, so the most recent note is always first.\n'
        '  3. Ask me each time\n'
        '     No fixed rule — I\'ll ask where to put each new note as it comes up.\n'
        '  4. Type something.\n'
        '────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n'
        '  5. Chat about this\n'
        '\n'
        'Enter to select · ↑/↓ to navigate · Esc to cancel\n'
        '\n';

    test('the question is the question', () {
      expect(AppState.parsePrompt(menu).question,
          'Where should new notes go in notes.md?');
    });

    test('every option is offered, escape hatches included', () {
      final choices = AppState.parsePrompt(menu).choices;
      expect(choices.length, 5);
      expect(choices.first.label, startsWith('Append to bottom'));
      expect(choices[1].label, 'Prepend to top');
    });

    test('what the agent said about an option comes with it', () {
      final choices = AppState.parsePrompt(menu).choices;
      expect(choices[1].detail, contains('most recent note is always first'));
      expect(choices.first.detail, contains('preserving the order'));
    });

    test('a diff above the menu is not the question', () {
      // A diff has numbered lines, and the line before a menu is not
      // necessarily a question.
      const withDiff = '  130 +                : SessionsScreen(\n'
          '  131 +                    state: _state,\n'
          '  132 +                  ),\n'
          '❯ 1. Add an emulator key\n'
          '  2. Wait for the phone\n';
      final asked = AppState.parsePrompt(withDiff);
      expect(asked.question, isEmpty);
      expect(asked.choices.length, 2);
      expect(asked.choices.first.label, 'Add an emulator key');
      expect(asked.choices.first.detail, isEmpty);
    });
  });

  group('upload progress', () {
    test('the chip fills as the bytes go up', () async {
      // A message sent while an attachment is still going up waits for it.
      final state = AppState();
      final seen = <double>[];
      state.addListener(() {
        if (state.uploading) seen.add(state.uploadProgress);
      });
      // The callback the upload isolate drives, wired as uploadAttachment
      // wires it: report, but not for every 64KB chunk.
      var progress = 0.0;
      void report(int sent, int total) {
        final fraction = sent / total;
        if (fraction - progress < 0.02 && fraction < 1) return;
        progress = fraction;
        state.uploading = true;
        state.uploadProgress = fraction;
        state.notifyForTest();
      }

      for (var sent = 0; sent <= 1000; sent += 5) {
        report(sent, 1000);
      }
      expect(seen.first, lessThan(0.1));
      expect(seen.last, 1.0);
      // Throttled: 200 chunks must not be 200 repaints.
      expect(seen.length, lessThan(60));
    });
  });

  group('attachments of any type', () {
    test('the name the agent sees is the name you picked', () {
      // "fares.csv" in a prompt tells an agent what it is holding, where
      // "shepherd-1764212880.bin" tells it nothing.
      expect(Uploads.safeName('/storage/emulated/0/Download/fares.csv'),
          'fares.csv');
    });

    test('a name that could confuse a shell cannot', () {
      expect(Uploads.safeName("/tmp/re'port \$(id).csv"), 're-port-id-.csv');
      expect(Uploads.safeName('/tmp/../../etc/passwd'), 'passwd');
      expect(Uploads.safeName('/tmp/'), 'attachment');
    });

    test('a name long enough to be a problem is trimmed to its end', () {
      final long = '${'a' * 200}.log';
      final safe = Uploads.safeName('/tmp/$long');
      expect(safe.length, lessThanOrEqualTo(60));
      expect(safe, endsWith('.log'));
    });
  });

  group('answering a question', () {
    // Verbatim from a Claude Code permission prompt, box rules and all.
    const screen = ' Edit file\n'
        ' notes.md\n'
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌\n'
        ' 1  todo\n'
        ' 2 +call the bank on Tuesday\n'
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌\n'
        ' Do you want to make this edit to notes.md?\n'
        ' ❯ 1. Yes\n'
        '   2. Yes, and switch to accept edits for this session (shift+tab)\n'
        '   3. No\n'
        '\n'
        ' Esc to cancel · Tab to amend\n'
        '  Opus 5 | 0in 0out | ctx:n/a | ~/notes\n';

    test('the question is the question, not the diff above it', () {
      expect(AppState.parsePrompt(screen).question,
          'Do you want to make this edit to notes.md?');
    });

    test('the choices come back in the order they are pressed in', () {
      final asked = AppState.parsePrompt(screen);
      expect(asked.choices.length, 3);
      expect(asked.choices.first.label, 'Yes');
      expect(asked.choices.last.label, 'No');
    });

    test('a numbered line inside a diff is not a choice', () {
      // " 1  todo" and " 2 +call the bank" are file lines. Only a run that
      // starts at one and counts up is a menu.
      expect(AppState.parsePrompt(screen).choices.map((c) => c.label),
          isNot(contains('todo')));
    });

    test('a question with no menu still reads as a question', () {
      final asked = AppState.parsePrompt(
          'What should I call the new column?\n❯\n  Model: Opus 5');
      expect(asked.choices, isEmpty);
      expect(asked.question, 'What should I call the new column?');
    });
  });

  group('host scripts', () {
    // A heredoc terminator must stand alone on its line, and stdin can be
    // redirected only once: `python3 - < list <<EOF` hands python the list
    // as its program. Either mistake fails silently.
    final script = AppState.previewScript(
      'python3 - a b >> "\$SHEPHERD_LIST" <<\'SHEPHERD_CODEX\'\n'
      'print("hi")\n'
      'SHEPHERD_CODEX\n',
      {'w1:p1': '/tmp/a.jsonl'},
    );

    test('every terminator sits alone on its line', () {
      for (final marker in const ['SHEPHERD_PREVIEW', 'SHEPHERD_CODEX']) {
        final opens =
            RegExp('<<\'$marker\'').allMatches(script).length;
        final closes = script
            .split('\n')
            .where((line) => line.trimRight() == marker)
            .length;
        expect(closes, opens,
            reason: '$marker: $opens opened, $closes closed by a bare line');
      }
    });

    test('the program is the only thing on python stdin', () {
      expect(script, isNot(contains(r'python3 - < "$SHEPHERD_LIST"')));
      expect(script, contains(r'python3 - "$SHEPHERD_LIST" <<'));
    });
  });

  group('pasted messages', () {
    test('the paste wrapper is not part of what you said', () {
      // Claude Code brackets pasted text before it reaches the transcript,
      // and a phone is a device people paste into.
      final a = ClaudeAdapter();
      a.addRecord({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': '<pasted_content id="9c06">\n'
              'Add a category column\n'
              '</pasted_content id="9c06">',
        },
      });
      expect(a.turns.single.userText, 'Add a category column');
    });
  });

  group('the row shows the latest reply', () {
    Pane pane(String id) => Pane(paneId: id, tabId: 't', workspaceId: 'w');

    test('a pane id is a whole field, not a prefix', () {
      // "w1:p1" must not match inside "w1:p10".
      const combined = '%%%w1:p10 reply belongs to the tenth pane\n'
          '%%%w1:p1 reply belongs to the first pane\n';
      expect(AppState.extractPreview(combined, pane('w1:p1')),
          'belongs to the first pane');
      expect(AppState.extractPreview(combined, pane('w1:p10')),
          'belongs to the tenth pane');
    });

    test('a pane with no line of its own gets nothing, not a neighbour', () {
      const combined = '%%%w1:p2 reply someone else\n';
      expect(AppState.extractPreview(combined, pane('w1:p1')), isNull);
    });

    test('a working agent can show what it is doing instead', () {
      const combined = '%%%w1:p1 reply the last thing it said\n'
          '%%%w1:p1 live Bash - counting the files\n';
      expect(AppState.extractPreview(combined, pane('w1:p1'), live: true),
          'Bash - counting the files');
    });
  });

  group('older turns survive a reconnect', () {
    Turn turn(String user) => Turn(id: user, userText: user);

    test('a re-read window is joined to what is already on screen', () {
      final existing = [turn('one'), turn('two'), turn('three')];
      final fresh = [turn('three'), turn('four')];
      expect(AppState.mergeHistory(existing, fresh).map((t) => t.userText),
          ['one', 'two', 'three', 'four']);
    });

    test('a window with nothing in common is appended, never dropped', () {
      final existing = [turn('one')];
      final fresh = [turn('nine')];
      expect(AppState.mergeHistory(existing, fresh).map((t) => t.userText),
          ['one', 'nine']);
    });

    test('the first read of a pane simply takes the window', () {
      expect(AppState.mergeHistory(const [], [turn('one')]).single.userText,
          'one');
    });
  });

  group('character encoding', () {
    test('a chunk ending mid-character keeps the incomplete bytes back', () {
      // "—" is E2 80 94; a socket chunk can end after any of those bytes.
      final emDash = [0xE2, 0x80, 0x94];
      expect(completeUtf8([0x61, ...emDash]), 4);
      expect(completeUtf8([0x61, 0xE2, 0x80]), 1);
      expect(completeUtf8([0x61, 0xE2]), 1);
      expect(completeUtf8([0x61, 0x62]), 2);
    });
  });

  group('session names', () {
    test('a label on the pane outranks the title on the agent', () {
      // Only `panes` carries the label; only `agents` carries the counter the
      // list sorts by. The row is built from `agents`.
      final state = HostState.fromSnapshot({
        'panes': [
          {
            'pane_id': 'w6:p1',
            'agent': 'pi',
            'cwd': '/Users/x/work/ledger',
            'label': 'ledger',
            'terminal_title_stripped': 'Downloads,-read-it · Off',
          }
        ],
        'agents': [
          {
            'pane_id': 'w6:p1',
            'agent': 'pi',
            'cwd': '/Users/x/work/ledger',
            'terminal_title_stripped': 'Downloads,-read-it · Off',
            'state_change_seq': 7,
          }
        ],
      });
      final row = state.agentPanes.single;
      expect(row.sessionName, 'ledger');
      expect(row.stateSeq, 7);
    });
  });

  group('list repaints', () {
    HostState withStatus(String status, {String id = 'w1:p1'}) =>
        HostState.fromSnapshot({
          'panes': [
            {'pane_id': id, 'agent': 'pi', 'agent_status': status, 'cwd': '/x'}
          ],
          'agents': [
            {'pane_id': id, 'agent': 'pi', 'agent_status': status, 'cwd': '/x'}
          ],
        });

    test('a status change is noticed', () {
      expect(
          AppState.statusesDiffer(withStatus('working'), withStatus('done')),
          isTrue);
    });

    test('an identical snapshot is not', () {
      expect(
          AppState.statusesDiffer(withStatus('working'), withStatus('working')),
          isFalse);
    });

    test('an agent appearing or leaving is noticed', () {
      expect(
          AppState.statusesDiffer(
              withStatus('idle'), HostState.fromSnapshot(const {})),
          isTrue);
    });
  });

  group('cache after a restart', () {
    test('steps survive the round trip in the order they happened', () {
      final turn = Turn(id: 'c0', userText: 'do it')
        ..steps.addAll([
          const Reasoning('thinking about it'),
          ToolCall(id: 't1', name: 'Bash', detail: 'ls', input: '{}')
            ..result = 'a b c'
            ..isError = true,
          const Reply('done'),
          const Failure('token expired'),
        ]);
      final cache = TranscriptCache()..remember('/p', [turn], 42, 'anchor');
      final payload = {
        '_version': TranscriptCache.version,
        for (final e in cache.entries.entries)
          e.key: {
            'consumed': e.value.consumed,
            'anchor': e.value.anchor,
            'touched': e.value.touched,
            'turns': [
              for (final t in e.value.turns)
                {
                  'id': t.id,
                  'userText': t.userText,
                  'steps': [for (final s in t.steps) s.toMap()],
                }
            ],
          }
      };

      final back = decodeForTest(encodeForTest(payload))['/p']!;
      expect(back.consumed, 42);
      final steps = back.turns.single.steps;
      expect(steps.map((s) => s.runtimeType.toString()),
          ['Reasoning', 'ToolCall', 'Reply', 'Failure']);
      final call = steps[1] as ToolCall;
      expect(call.result, 'a b c');
      expect(call.isError, isTrue);
    });

    test('a cache from an older scheme is a miss, not something to trust', () {
      // Version 1 stored byte offsets that could claim a complete read with
      // turns missing, so it is discarded.
      expect(decodeForTest('{"_version":1,"/p":{"turns":[]}}'), isEmpty);
    });
  });
}
