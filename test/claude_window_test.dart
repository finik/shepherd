import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';

void main() {
  group('the window of a Claude model', () {
    const fable = ModelOption(
        id: 'claude-fable-5-1[1m]', label: 'Fable', detail: '', context: 1000000);

    test('Claude lists its 1M variant with a suffix the transcript lacks', () {
      expect(AppState.windowOf([fable], 'claude-fable-5-1'), 1000000);
      expect(AppState.windowOf([fable], 'claude-fable-5-1[1m]'), 1000000);
      expect(AppState.windowOf([fable], 'claude-opus-5-5'), isNull);
    });

    test('a model with no window of its own matches nothing', () {
      const bare = ModelOption(id: 'opus', label: 'opus', detail: '');
      expect(AppState.windowOf([bare], 'opus'), isNull);
    });

    group('from the public table kept on the host', () {
      late Directory home;
      setUp(() {
        home = Directory.systemTemp.createTempSync('shepherd_window');
        Directory('${home.path}/.shepherd').createSync();
        File('${home.path}/.shepherd/prices.json').writeAsStringSync(jsonEncode({
          'claude-sonnet-5-5': {
            'litellm_provider': 'anthropic',
            'max_input_tokens': 1000000
          },
          'claude-sonnet-4-5': {
            'litellm_provider': 'anthropic',
            'max_input_tokens': 200000
          },
          'github_copilot/claude-sonnet-5.5': {
            'litellm_provider': 'github_copilot',
            'max_input_tokens': 200000
          },
          'vertex_ai/x': {'litellm_provider': 'anthropic'},
        }));
      });
      tearDown(() => home.deleteSync(recursive: true));

      Future<String> ask(String model) async {
        final r = await Process.run(
            'python3', ['-I', '-c', AppState.tableWindowScript, model],
            environment: {'HOME': home.path});
        return (r.stdout as String).trim();
      }

      test('a model Anthropic lists gives its window', () async {
        expect(await ask('claude-sonnet-5-5'), '@@@1000000');
        expect(await ask('claude-sonnet-4-5'), '@@@200000');
      });

      test('an unknown model, or a row without a window, gives nothing',
          () async {
        expect(await ask('claude-nothing'), '');
        expect(await ask('vertex_ai/x'), '');
      });

      test('no table gives nothing', () async {
        File('${home.path}/.shepherd/prices.json').deleteSync();
        expect(await ask('claude-sonnet-5-5'), '');
      });
    });
  });
}
