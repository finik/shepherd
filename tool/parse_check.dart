// Runs the app's own framer and adapter over a real transcript tail, so a
// missing reply can be blamed on the parser or cleared of it.
import 'dart:io';
import 'package:shepherd/transcript/adapters.dart';
import 'package:shepherd/transcript/turn.dart';

void main(List<String> args) {
  final file = File(args[0]);
  final window = int.parse(args[1]);
  final size = file.lengthSync();
  final start = size > window ? size - window : 0;
  final bytes = file.readAsBytesSync().sublist(start);
  final maps = parseTranscript({
    'text': String.fromCharCodes(bytes),
    'agent': args.length > 2 ? args[2] : 'claude',
  });
  final turns = turnsFromMaps(maps);
  print('read ${bytes.length} bytes from offset $start, turns=${turns.length}');
  for (final t in turns.length <= 4 ? turns : turns.sublist(turns.length - 4)) {
    print('--- user: ${t.userText.replaceAll('\n', ' ')}');
    for (final step in t.steps) {
      final kind = switch (step) {
        Reply() => 'reply: ${step.text.replaceAll('\n', ' ')}',
        Reasoning() => 'reasoning',
        ToolCall() => 'tool ${step.name}',
        Failure() => 'failure ${step.message}',
        ImageRef() => 'image @${step.offset} ${step.mediaType}',
      };
      print('    $kind');
    }
  }
}
