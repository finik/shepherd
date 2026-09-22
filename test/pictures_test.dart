import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/transcript/adapters.dart';
import 'package:shepherd/transcript/turn.dart';

/// Three agents, three ways of writing a picture into a transcript.
///
/// Each of these was taken from a real session.
void main() {
  Map<String, dynamic> json(String text) =>
      jsonDecode(text) as Map<String, dynamic>;

  group('Pi buries a picture inside the result that read it', () {
    // A `read` of an image is a tool result; when a subagent did the reading,
    // that result is nested inside the parent's result, several levels down.
    final nested = json('''
    {"type":"message","message":{"role":"toolResult","toolName":"subagent",
     "content":[{"type":"text","text":"done"}],
     "details":{"results":[{"agent":"scan","messages":[
       {"role":"toolResult","toolName":"read","content":[
         {"type":"text","text":"Read image file [image/jpeg]"},
         {"type":"image","data":"${'A' * 400}","mimeType":"image/jpeg"}]},
       {"role":"toolResult","toolName":"read","content":[
         {"type":"image","data":"${'B' * 800}","mimeType":"image/jpeg"}]}
     ]}]}}}''');

    test('a picture two results deep is still found', () {
      final a = PiAdapter()
        ..addRecord(json('''
        {"type":"message","message":{"role":"user",
         "content":[{"type":"text","text":"scan these"}]}}'''))
        ..addRecord(nested);
      expect(a.turns.single.images.length, 2);
      expect(a.turns.single.images.first.mediaType, 'image/jpeg');
    });

    test('each picture in one record is numbered, so each is its own', () {
      // Both live at the same byte offset; the index tells them apart.
      final a = PiAdapter()
        ..addRecord(json('''
        {"type":"message","message":{"role":"user",
         "content":[{"type":"text","text":"scan these"}]}}'''))
        ..addRecord(nested);
      final pictures = a.turns.single.images.toList();
      expect(pictures[0].index, 0);
      expect(pictures[1].index, 1);
      expect(pictures[0].key, isNot(pictures[1].key));
      // And the sizes are read from the payloads, not shared.
      expect(pictures[0].bytes, lessThan(pictures[1].bytes));
    });
  });

  group('Codex answers with a data: URL', () {
    // `view_image` puts the picture in the tool's output as an input_image
    // whose image_url is the whole file, base64, inline.
    final call = json('''
    {"type":"response_item","payload":{"type":"custom_tool_call","name":"exec",
     "call_id":"c1","input":"const r = await tools.view_image({path:\\"/x/spend.png\\"}); image(r.image_url);"}}''');
    final output = json('''
    {"type":"response_item","payload":{"type":"custom_tool_call_output",
     "call_id":"c1","output":[
       {"type":"input_text","text":"Script completed"},
       {"type":"input_image","image_url":"data:image/png;base64,${'C' * 1200}"}]}}''');

    test('the picture is found, with its type and its size', () {
      final a = TranscriptAdapter.forAgent('codex')
        ..addRecord(json('''
        {"type":"response_item","payload":{"type":"message","role":"user",
         "content":[{"type":"input_text","text":"what is in spend.png?"}]}}'''))
        ..addRecord(call)
        ..addRecord(output);
      final picture = a.turns.single.images.single;
      expect(picture.mediaType, 'image/png');
      expect(picture.bytes, closeTo(900, 10));
    });

    test('the tool line says what it looked at', () {
      final a = TranscriptAdapter.forAgent('codex')
        ..addRecord(json('''
        {"type":"response_item","payload":{"type":"message","role":"user",
         "content":[{"type":"input_text","text":"what is in spend.png?"}]}}'''))
        ..addRecord(call);
      expect((a.turns.single.steps.single as ToolCall).detail, 'spend.png');
    });
  });

  group('Claude nests one in a tool result', () {
    test('a screenshot in a tool result is found', () {
      final a = ClaudeAdapter()
        ..addRecord(json('''
        {"type":"user","message":{"role":"user","content":"take a look"}}'''))
        ..addRecord(json('''
        {"type":"user","message":{"role":"user","content":[
          {"type":"tool_result","tool_use_id":"t1","content":[
            {"type":"image","source":{"media_type":"image/png","__bytes":293000}}]}]}}'''));
      expect(a.turns.single.images.single.bytes, 293000);
    });
  });

  test('a picture eight levels down is still found', () {
    // Pi's inspector subagent puts what it read at
    // details.results[].messages[].content[].
    Map<String, dynamic> wrap(Map<String, dynamic> inner, int levels) {
      var node = inner;
      for (var i = 0; i < levels; i++) {
        node = {'level$i': [node]};
      }
      return node;
    }
    final deep = wrap({'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png'}, 6);
    expect(imagesAnywhere(deep).length, 1);
  });
}
