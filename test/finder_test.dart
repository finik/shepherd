import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';

/// Finding the session a Pi or omp pane has open, from the folder it runs in.
void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('finder'));
  tearDown(() => home.deleteSync(recursive: true));

  void session(String root, String folder, String name, String cwd,
      {bool titled = false, required DateTime at}) {
    final file = File('${home.path}/$root/$folder/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync([
        if (titled) jsonEncode({'type': 'title', 'title': 'x'}),
        jsonEncode({'type': 'session', 'id': name, 'cwd': cwd}),
        jsonEncode({'type': 'message'}),
      ].join('\n'));
    file.setLastModifiedSync(at);
  }

  Map<String, String> find(List<String> paneAndCwd) {
    final out = Process.runSync(
        'python3', ['-c', AppState.piFinderScriptForTest, ...paneAndCwd],
        environment: {'HOME': home.path});
    expect(out.exitCode, 0, reason: out.stderr as String);
    return {
      for (final line in (out.stdout as String).trim().split('\n'))
        if (line.contains(' '))
          line.substring(0, line.indexOf(' ')):
              line.substring(line.indexOf(' ') + 1)
    };
  }

  test('the newest session started in the pane\'s folder', () {
    final work = Directory('${home.path}/work/ledger')
      ..createSync(recursive: true);
    final other = Directory('${home.path}/work/notes')
      ..createSync(recursive: true);
    session('.pi/agent/sessions', 'a', 'old.jsonl', work.path,
        at: DateTime(2026, 10, 1));
    session('.pi/agent/sessions', 'a', 'new.jsonl', work.path,
        at: DateTime(2026, 10, 9));
    session('.pi/agent/sessions', 'b', 'elsewhere.jsonl', other.path,
        at: DateTime(2026, 10, 20));
    // omp puts a title before the session record.
    session('.omp/agent/sessions', 'c', 'omp.jsonl', other.path,
        titled: true, at: DateTime(2026, 10, 21));

    final found = find(['t3', work.path, 't5', other.path]);
    expect(found['t3'], endsWith('/a/new.jsonl'));
    expect(found['t5'], endsWith('/c/omp.jsonl'));
  });
}
