import 'dart:convert';

import 'adapters.dart';
import 'turn.dart';

/// Codex writes a rollout, not a conversation.
///
/// Every line is `{timestamp, ordinal, type, payload}` and most of them are
/// bookkeeping — token counts, world state, turn contexts, `item_completed`
/// events that repeat what the record beside them already said. The
/// conversation is the subset with `type: "response_item"`, and inside that
/// the shapes are OpenAI's: `message` with `input_text`/`output_text` blocks,
/// `custom_tool_call` paired to its output by `call_id`, and `reasoning`
/// whose text is encrypted and therefore not ours to show.
///
/// The first few user-role messages are not from the user: an environment
/// context block, and whatever instructions the harness injected. They are
/// wrapped in tags, which is what tells them apart.
class CodexAdapter implements TranscriptAdapter {
  @override
  final List<Turn> turns = [];
  @override
  int baseOffset = 0;
  int _seq = 0;

  /// Calls waiting for their output, by `call_id`.
  final Map<String, ToolCall> _open = {};

  /// The record being handled, for the offset a picture is fetched by.
  Map<String, dynamic> _record = const {};

  @override
  void seed(int from) => _seq = from;

  @override
  bool addRecord(Map<String, dynamic> r) {
    if (r['__dropped'] == 'image') {
      if (turns.isEmpty) return false;
      turns.last.steps.add(ImageRef(
        offset: offsetOfRecord(r, baseOffset),
        bytes: (r['__bytes'] as num?)?.toInt() ?? 0,
      ));
      return true;
    }
    if (r['type'] != 'response_item') return false;
    final payload = r['payload'];
    if (payload is! Map) return false;

    switch (payload['type']) {
      case 'message':
        return _message(r, payload);
      case 'reasoning':
        return _reasoning(payload);
      case 'custom_tool_call':
      case 'function_call':
      case 'local_shell_call':
        return _call(payload);
      case 'custom_tool_call_output':
      case 'function_call_output':
      case 'local_shell_call_output':
        _record = r;
        return _result(payload);
    }
    return false;
  }

  bool _message(Map<String, dynamic> record, Map payload) {
    final role = payload['role'] as String?;
    // Instructions to the agent, not part of anybody's conversation.
    if (role != 'user' && role != 'assistant') return false;

    final texts = <String>[];
    final pictures = <({String media, int bytes})>[];
    final content = payload['content'];
    if (content is List) {
      for (final block in content) {
        if (block is! Map) continue;
        switch (block['type']) {
          case 'input_text':
          case 'output_text':
          case 'text':
            final text = block['text'];
            if (text is String && text.isNotEmpty) texts.add(text);
          case 'input_image':
          case 'image':
            pictures.add(_picture(block));
        }
      }
    } else if (content is String) {
      texts.add(content);
    }
    final text = texts.join('\n').trim();

    if (role == 'assistant') {
      if (text.isEmpty && pictures.isEmpty) return false;
      if (turns.isEmpty) return false;
      if (text.isNotEmpty) turns.last.steps.add(Reply(clampBlock(text)));
      _attachPictures(record, pictures);
      return true;
    }

    // A user message that is really the harness talking to the agent.
    if (isPreamble(text)) return false;
    if (text.isEmpty && pictures.isEmpty) return false;
    turns.add(Turn(
      id: 'x${_seq++}',
      userText: clampBlock(withoutWrappers(text), max: 4000),
    ));
    _attachPictures(record, pictures);
    return true;
  }

  /// Codex opens a session by handing the model an environment block and any
  /// harness instructions, all as user-role messages. They are wrapped in a
  /// tag on the first line, which nothing a person types ever is.
  static bool isPreamble(String text) {
    final trimmed = text.trimLeft();
    if (!trimmed.startsWith('<')) return false;
    return RegExp(r'^<[a-z_][a-z0-9_]*>').hasMatch(trimmed);
  }

  ({String media, int bytes}) _picture(Map block) {
    final url = (block['image_url'] ?? block['url']) as String?;
    final reported = (block['__bytes'] as num?)?.toInt();
    if (url != null && url.startsWith('data:')) {
      final comma = url.indexOf(',');
      final media = url.substring(5, url.indexOf(';') < 0 ? comma : url.indexOf(';'));
      return (
        media: media,
        bytes: reported ?? ((url.length - comma - 1) * 3) ~/ 4,
      );
    }
    return (media: (block['media_type'] as String?) ?? '', bytes: reported ?? 0);
  }

  void _attachPictures(
      Map<String, dynamic> record, List<({String media, int bytes})> pictures) {
    for (final picture in pictures) {
      turns.last.steps.add(ImageRef(
        offset: offsetOfRecord(record, baseOffset),
        mediaType: picture.media,
        bytes: picture.bytes,
      ));
    }
  }

  bool _reasoning(Map payload) {
    // `summary` is the only readable part; `encrypted_content` is what it
    // sounds like. An empty summary is the usual case, and showing "thinking"
    // with nothing in it is worse than showing nothing.
    final summary = payload['summary'];
    if (summary is! List || summary.isEmpty) return false;
    final texts = <String>[];
    for (final part in summary) {
      if (part is Map && part['text'] is String) {
        texts.add(part['text'] as String);
      } else if (part is String) {
        texts.add(part);
      }
    }
    final text = texts.join('\n').trim();
    if (text.isEmpty || turns.isEmpty) return false;
    turns.last.steps.add(Reasoning(clampBlock(text)));
    return true;
  }

  bool _call(Map payload) {
    if (turns.isEmpty) return false;
    final id = (payload['call_id'] ?? payload['id']) as String? ?? '';
    final name = (payload['name'] as String?) ?? 'tool';
    final raw = payload['input'] ?? payload['arguments'] ?? payload['action'];
    final input = raw is String ? raw : jsonEncode(raw);
    final call = ToolCall(
      id: id,
      name: name,
      detail: describeCodexCall(input),
      input: clampBlock(input, max: 1200),
    );
    turns.last.steps.add(call);
    if (id.isNotEmpty) _open[id] = call;
    return true;
  }

  /// What the call is actually doing, for the one line under the tool name.
  ///
  /// Codex's `exec` tool is handed a snippet of JavaScript that calls
  /// `exec_command({cmd: "…"})`, so the command a person would recognise is
  /// inside a string inside an argument.
  static String describeCodexCall(String input) {
    final command = RegExp(r'''cmd\s*:\s*["'](.+?)["']\s*[,}]''', dotAll: true)
        .firstMatch(input);
    if (command != null) return firstLineOf(command.group(1)!, max: 80);
    final path = RegExp(r'''(?:path|file|filename)\s*:\s*["']([^"']+)["']''')
        .firstMatch(input);
    if (path != null) return path.group(1)!.split('/').last;
    return firstLineOf(input, max: 80);
  }

  bool _result(Map payload) {
    final id = (payload['call_id'] ?? payload['id']) as String? ?? '';
    final call = _open.remove(id);
    if (call == null) return false;
    final output = payload['output'];
    final texts = <String>[];
    if (output is String) {
      texts.add(output);
    } else if (output is List) {
      for (final block in output) {
        if (block is Map && block['text'] is String) {
          texts.add(block['text'] as String);
        } else if (block is String) {
          texts.add(block);
        }
      }
    }
    call.result = clampBlock(texts.join('\n').trim(), max: 1200);
    // `view_image` answers with the picture itself, as a data: URL inside the
    // tool's output. It is the only way a picture reaches a Codex transcript.
    final pictures = imagesAnywhere(output);
    for (var i = 0; i < pictures.length; i++) {
      turns.last.steps.add(ImageRef(
        offset: offsetOfRecord(_record, baseOffset),
        index: i,
        mediaType: pictures[i].text,
        bytes: pictures[i].bytes,
        thumb: pictures[i].thumb,
      ));
    }
    call.isError = payload['status'] == 'failed' ||
        (payload['success'] == false);
    return true;
  }
}
