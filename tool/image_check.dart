// End-to-end check of the picture path against a real transcript: parse the
// window the app would read, then fetch every picture it found, the way the
// app fetches it. Blames the parser or clears it.
import 'dart:convert';
import 'dart:io';

import 'package:shepherd/transcript/adapters.dart';
import 'package:shepherd/transcript/turn.dart';

void main(List<String> args) {
  final path = args[0];
  final agent = args.length > 1 ? args[1] : 'claude';
  final window = args.length > 2 ? int.parse(args[2]) : 4 * 1024 * 1024;
  final file = File(path);
  final size = file.lengthSync();
  final start = size > window ? size - window : 0;
  final bytes = file.readAsBytesSync().sublist(start);
  final maps = parseTranscript({
    'text': utf8.decode(bytes, allowMalformed: true),
    'agent': agent,
    'base': '$start',
  });
  final turns = turnsFromMaps(maps);
  final pictures = [for (final t in turns) ...t.images];
  print('$agent · turns=${turns.length} · pictures=${pictures.length}');
  for (final picture in pictures.take(6)) {
    print('  @${picture.offset}  ${picture.mediaType}  ${picture.bytes} bytes');
  }
  if (pictures.isEmpty) exit(0);
  print('offsets: ${pictures.take(6).map((p) => p.offset).join(' ')}');
}
