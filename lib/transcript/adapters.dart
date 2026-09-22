import 'dart:convert';

import 'codex.dart';
import 'turn.dart';

/// Turns an agent's JSONL transcript into [Turn]s.
///
/// Claude, Pi and Codex differ enough that each gets its own implementation
/// rather than one parser with branches: different parent keys, different
/// tool-call shapes, different places for pictures.
abstract class TranscriptAdapter {
  /// Where in the file the text fed to this adapter began, so a record's
  /// offset within the window is a position in the file.
  int baseOffset = 0;

  /// Feed one JSONL record. Returns true if the turn list changed.
  bool addRecord(Map<String, dynamic> record);

  List<Turn> get turns;

  /// Start numbering turns from [from], so ids stay unique when a parse
  /// continues an earlier one.
  void seed(int from);

  static TranscriptAdapter forAgent(String? agent) {
    switch (agent) {
      case 'pi':
        return PiAdapter();
      case 'codex':
        return CodexAdapter();
      case 'claude':
        return ClaudeAdapter();
      default:
        // Unknown agents still get Claude-ish handling, which tolerates both
        // bare strings and block arrays.
        return ClaudeAdapter();
    }
  }
}

/// Every picture anywhere in a record.
///
/// Pi's `read` of an image is a tool result, and when a subagent did the
/// reading that result is nested inside the parent's, several levels down.
/// Searching the whole record matches the host script that fetches one.
List<_Block> imagesAnywhere(dynamic node, [int depth = 0]) {
  if (depth > 14) return const [];
  final out = <_Block>[];
  if (node is List) {
    for (final item in node) {
      out.addAll(imagesAnywhere(item, depth + 1));
    }
    return out;
  }
  if (node is! Map) return const [];
  if (node['type'] == 'image' || node['type'] == 'input_image') {
    // Codex writes a data: URL rather than a payload field.
    final url = (node['image_url'] ?? node['url']) as String?;
    if (url != null && url.startsWith('data:')) {
      final semi = url.indexOf(';');
      final comma = url.indexOf(',');
      out.add(_Block('image', url.substring(5, semi < 0 ? comma : semi),
          bytes: (node['__bytes'] as num?)?.toInt() ??
              ((url.length - comma - 1) * 3) ~/ 4,
          thumb: node['__thumb'] as String?));
      return out;
    }
    final source = node['source'] is Map ? node['source'] as Map : const {};
    final media = (node['media_type'] ?? source['media_type'] ??
        node['mimeType'] ?? node['mediaType']) as String?;
    final reported = (node['__bytes'] ?? source['__bytes']) as num?;
    final data = (node['data'] ?? source['data']) as String?;
    out.add(_Block('image', media ?? '',
        bytes: reported?.toInt() ??
            (data == null ? 0 : (data.length * 3) ~/ 4),
        thumb: (node['__thumb'] ?? source['__thumb']) as String?));
    return out;
  }
  for (final value in node.values) {
    out.addAll(imagesAnywhere(value, depth + 1));
  }
  return out;
}

/// Image blocks nested inside a tool result.
List<_Block> _imagesIn(dynamic content) {
  if (content is! List) return const [];
  final out = <_Block>[];
  for (final block in content) {
    if (block is! Map || block['type'] != 'image') continue;
    final source = block['source'] is Map ? block['source'] as Map : const {};
    final media =
        (block['media_type'] ?? source['media_type'] ?? block['mimeType'])
            as String?;
    final reported = (block['__bytes'] ?? source['__bytes']) as num?;
    final data = (block['data'] ?? source['data']) as String?;
    out.add(_Block('image', media ?? '',
        bytes: reported?.toInt() ??
            (data == null ? 0 : (data.length * 3) ~/ 4),
        thumb: (block['__thumb'] ?? source['__thumb']) as String?));
  }
  return out;
}

/// Where a record sits in the file, for pointing back at it later.
///
/// The backfill arrives stamped with an absolute position by the host, used
/// as it is; the live tail is framed here, where offsets are relative to the
/// point the follow began and the base is added.
int offsetOfRecord(Map<String, dynamic> record, int base) =>
    _offsetOfRecord(record, base);

int _offsetOfRecord(Map<String, dynamic> record, int base) {
  final absolute = (record['__abs'] as num?)?.toInt();
  if (absolute != null) return absolute;
  return base + ((record['__offset'] as num?)?.toInt() ?? 0);
}

/// Extracts plain text from content that may be a bare string or a block list.
List<_Block> _blocks(dynamic content) {
  if (content is String) {
    return [_Block('text', content)];
  }
  if (content is List) {
    final out = <_Block>[];
    for (final b in content) {
      if (b is! Map) continue;
      final type = b['type'] as String?;
      switch (type) {
        case 'text':
          out.add(_Block('text', (b['text'] as String?) ?? ''));
        case 'thinking':
          out.add(_Block(
              'thinking', (b['thinking'] ?? b['text']) as String? ?? ''));
        case 'tool_use':
          out.add(_Block('tool', '',
              call: _toolCall(b['id'], b['name'], b['input'])));
        case 'toolCall':
          out.add(_Block('tool', '',
              call: _toolCall(
                  b['id'], b['name'] ?? b['toolName'], b['arguments'])));
        case 'tool_result':
          out.add(_Block('tool_result', _resultText(b['content']),
              resultFor: b['tool_use_id'] as String?,
              isError: b['is_error'] == true));
          // A tool that returns a picture — a screenshot, a rendered chart —
          // nests it one level further down.
          out.addAll(_imagesIn(b['content']));
        case 'image':
          final source = b['source'] is Map ? b['source'] as Map : const {};
          final media =
              (b['media_type'] ?? source['media_type'] ?? b['mimeType'])
                  as String?;
          // The host reports the size when it strips a payload for the
          // backfill; the live tail carries the real data, so measure it.
          final reported = (b['__bytes'] ?? source['__bytes']) as num?;
          final data = (b['data'] ?? source['data']) as String?;
          final size = reported?.toInt() ??
              (data == null ? 0 : (data.length * 3) ~/ 4);
          out.add(_Block('image', media ?? '',
              bytes: size,
              thumb: (b['__thumb'] ?? source['__thumb']) as String?));
        case 'document':
          out.add(_Block('text', '[document]'));
      }
    }
    return out;
  }
  return const [];
}

/// Arguments arrive as an object from Claude and, in some Pi builds, as a JSON
/// string. Both spellings have to decode to the same thing.
Map<String, dynamic>? _asMap(dynamic args) {
  if (args is Map) return args.cast<String, dynamic>();
  if (args is String && args.trim().startsWith('{')) {
    try {
      final decoded = jsonDecode(args);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      // A malformed argument blob costs the detail line, nothing more.
    }
  }
  return null;
}

ToolCall _toolCall(dynamic id, dynamic name, dynamic args) {
  final toolName = name is String && name.isNotEmpty ? name : 'tool';
  final input = _asMap(args);
  return ToolCall(
    id: id is String ? id : '',
    name: toolName,
    detail: _describeTool(toolName, input),
    input: input == null
        ? (args is String ? clampBlock(args, max: _detailMax) : '')
        : clampBlock(_prettyJson(input), max: _detailMax),
  );
}

/// Enough of an argument blob or a result to judge what happened, without
/// holding a whole file read per call across eighty turns.
const _detailMax = 1200;

String _prettyJson(Map<String, dynamic> input) {
  try {
    return const JsonEncoder.withIndent('  ').convert(input);
  } catch (_) {
    return input.toString();
  }
}

/// Claude results are a string or a block list; Pi's are always a block list.
String _resultText(dynamic content) {
  if (content is String) return clampBlock(content, max: _detailMax);
  if (content is List) {
    final parts = <String>[];
    for (final b in content) {
      if (b is Map && b['type'] == 'text') {
        parts.add((b['text'] as String?) ?? '');
      } else if (b is Map && b['type'] == 'image') {
        parts.add('[image]');
      }
    }
    return clampBlock(parts.join('\n').trim(), max: _detailMax);
  }
  return '';
}

/// "Read chat-ui.md" says what an agent is doing; "Read" does not.
///
/// Claude writes a human `description` for shell commands, which is the best
/// thing available.
String _describeTool(String name, Map<String, dynamic>? input) {
  if (input == null) return '';

  String? detail;
  final description = input['description'];
  if (description is String && description.trim().isNotEmpty) {
    detail = description.trim();
  } else {
    for (final key in const ['file_path', 'path', 'notebook_path', 'pattern']) {
      final v = input[key];
      if (v is String && v.trim().isNotEmpty) {
        detail = v.split('/').last;
        break;
      }
    }
    if (detail == null) {
      final command = input['command'];
      if (command is String && command.trim().isNotEmpty) {
        detail = command.trim().split('\n').first;
      }
    }
  }
  if (detail == null || detail.isEmpty) return '';
  if (detail.length > 70) detail = '${detail.substring(0, 70).trimRight()}…';
  return detail;
}

class _Block {
  final String type;
  final String text;
  final ToolCall? call;
  final String? resultFor;
  final bool isError;

  /// For an image: how many bytes the picture is, so a reader can decide
  /// whether to pull it over a phone connection.
  final int bytes;

  /// For an image: the host's thumbnail, base64, when it made one.
  final String? thumb;

  const _Block(this.type, this.text,
      {this.call,
      this.resultFor,
      this.isError = false,
      this.bytes = 0,
      this.thumb});
}

/// A turn that failed instead of answering.
///
/// Pi records this as an assistant message with empty content, a stopReason
/// of "error" and the reason in errorMessage — an expired OAuth token, a rate
/// limit. Nothing else in the record says anything happened at all.
String? _errorMessage(Map msg) {
  if (msg['stopReason'] != 'error') return null;
  final reason = msg['errorMessage'];
  if (reason is String && reason.trim().isNotEmpty) {
    return clampBlock(reason.trim(), max: 500);
  }
  return 'The agent stopped with an error.';
}

/// Attach a result to the call it answers.
///
/// Matching on id rather than position: a turn can have several calls in
/// flight at once, and their results come back in whatever order they finish.
bool _attachResult(Turn turn, _Block block) {
  for (var i = turn.steps.length - 1; i >= 0; i--) {
    final call = turn.steps[i];
    if (call is ToolCall && call.id.isNotEmpty && call.id == block.resultFor) {
      call.result = block.text;
      call.isError = block.isError;
      return true;
    }
  }
  // Some Pi builds write neither an id on the call nor one on the result. The
  // newest call still waiting for one is the only sensible candidate, and it
  // beats the alternative: a second ToolCall appended for the same call, so
  // one invocation renders as "2 TOOLS" with the output lost.
  for (var i = turn.steps.length - 1; i >= 0; i--) {
    final call = turn.steps[i];
    if (call is ToolCall && call.result.isEmpty) {
      call.result = block.text;
      call.isError = block.isError;
      return true;
    }
  }
  return false;
}

/// "[Image: source: /path/to.png]" and friends: a note about an attachment.
final RegExp _attachmentNote =
    RegExp(r'^\[(image|file|pasted[^\]]*)[:\]]', caseSensitive: false);

class ClaudeAdapter implements TranscriptAdapter {
  @override
  final List<Turn> turns = [];
  @override
  int baseOffset = 0;
  int _seq = 0;

  @override
  void seed(int from) => _seq = from;

  @override
  bool addRecord(Map<String, dynamic> r) {
    if (r['__dropped'] == 'image') {
      if (turns.isEmpty) return false;
      turns.last.steps.add(ImageRef(
        offset: _offsetOfRecord(r, baseOffset),
        bytes: (r['__bytes'] as num?)?.toInt() ?? 0,
      ));
      return true;
    }
    final type = r['type'] as String?;
    // 16+ record types exist and more arrive with each release; anything
    // without a message is bookkeeping.
    if (type != 'user' && type != 'assistant') return false;
    final msg = r['message'];
    if (msg is! Map) return false;
    final role = msg['role'] as String?;
    final failure = _errorMessage(msg);
    if (failure != null && turns.isNotEmpty) {
      turns.last.steps.add(Failure(failure));
      return true;
    }
    final blocks = _blocks(msg['content']);
    if (blocks.isEmpty) return false;

    if (role == 'user') {
      // Claude logs tool results as user-role messages. Those continue the
      // current turn; only real prose starts a new one.
      var changed = false;
      if (turns.isNotEmpty) {
        for (final b in blocks.where((b) => b.type == 'tool_result')) {
          if (_attachResult(turns.last, b)) changed = true;
        }
      }
      final text = blocks
          .where((b) => b.type == 'text')
          .map((b) => b.text)
          .join('\n')
          .trim();
      final pictures = blocks.where((b) => b.type == 'image').toList();
      if (text.isEmpty) {
        // A picture on its own belongs to the message it came with.
        if (pictures.isNotEmpty && turns.isNotEmpty) {
          for (var i = 0; i < pictures.length; i++) {
            turns.last.steps.add(ImageRef(
                offset: _offsetOfRecord(r, baseOffset),
                index: i,
                mediaType: pictures[i].text,
                bytes: pictures[i].bytes,
                thumb: pictures[i].thumb));
            }
          return true;
        }
        return changed;
      }
      if (text.startsWith('<command-name>') ||
          text.startsWith('<local-command')) {
        return changed;
      }
      // Claude records an attached file as its own user message. It belongs
      // to the message that carried it rather than starting a turn, and the
      // picture in it is kept.
      if (_attachmentNote.hasMatch(text)) {
        if (turns.isNotEmpty) {
          for (var i = 0; i < pictures.length; i++) {
            turns.last.steps.add(ImageRef(
                offset: _offsetOfRecord(r, baseOffset),
                index: i,
                mediaType: pictures[i].text,
                bytes: pictures[i].bytes,
                thumb: pictures[i].thumb));
            }
          return pictures.isNotEmpty || changed;
        }
        return changed;
      }
      turns.add(Turn(id: 'c${_seq++}', userText: clampBlock(withoutWrappers(text), max: 4000)));
      for (var i = 0; i < pictures.length; i++) {
        turns.last.steps.add(ImageRef(
            offset: _offsetOfRecord(r, baseOffset),
            index: i,
            mediaType: pictures[i].text,
            bytes: pictures[i].bytes,
            thumb: pictures[i].thumb));
        }
      return true;
    }

    if (turns.isEmpty) return false;
    final turn = turns.last;
    var changed = false;
    for (final b in blocks) {
      switch (b.type) {
        case 'text':
          if (b.text.trim().isNotEmpty) {
            turn.steps.add(Reply(clampBlock(b.text)));
            changed = true;
          }
        case 'thinking':
          if (b.text.trim().isNotEmpty) {
            turn.steps.add(Reasoning(clampBlock(b.text)));
            changed = true;
          }
        case 'image':
          turn.steps.add(ImageRef(
              offset: _offsetOfRecord(r, baseOffset),
              mediaType: b.text,
              bytes: b.bytes,
              thumb: b.thumb));
          changed = true;
        case 'tool':
          if (b.call != null) {
            turn.steps.add(b.call!);
            changed = true;
          }
      }
    }
    return changed;
  }
}

class PiAdapter implements TranscriptAdapter {
  @override
  final List<Turn> turns = [];
  @override
  int baseOffset = 0;
  int _seq = 0;

  @override
  void seed(int from) => _seq = from;

  @override
  bool addRecord(Map<String, dynamic> r) {
    if (r['__dropped'] == 'image') {
      if (turns.isEmpty) return false;
      turns.last.steps.add(ImageRef(
        offset: _offsetOfRecord(r, baseOffset),
        bytes: (r['__bytes'] as num?)?.toInt() ?? 0,
      ));
      return true;
    }
    if (r['type'] != 'message') return false;
    final msg = r['message'];
    if (msg is! Map) return false;
    final role = msg['role'] as String?;
    final failure = _errorMessage(msg);
    if (failure != null && turns.isNotEmpty) {
      turns.last.steps.add(Failure(failure));
      return true;
    }
    final blocks = _blocks(msg['content']);

    if (role == 'user') {
      final text = blocks
          .where((b) => b.type == 'text')
          .map((b) => b.text)
          .join('\n')
          .trim();
      final pictures = blocks.where((b) => b.type == 'image').toList();
      if (text.isEmpty) {
        if (pictures.isNotEmpty && turns.isNotEmpty) {
          for (var i = 0; i < pictures.length; i++) {
            turns.last.steps.add(ImageRef(
                offset: _offsetOfRecord(r, baseOffset),
                index: i,
                mediaType: pictures[i].text,
                bytes: pictures[i].bytes,
                thumb: pictures[i].thumb));
            }
          return true;
        }
        return false;
      }
      turns.add(Turn(id: 'p${_seq++}', userText: clampBlock(withoutWrappers(text), max: 4000)));
      for (var i = 0; i < pictures.length; i++) {
        turns.last.steps.add(ImageRef(
            offset: _offsetOfRecord(r, baseOffset),
            index: i,
            mediaType: pictures[i].text,
            bytes: pictures[i].bytes,
            thumb: pictures[i].thumb));
        }
      return true;
    }

    if (turns.isEmpty) return false;
    final turn = turns.last;

    if (role == 'toolResult') {
      final found = imagesAnywhere(msg);
      for (var i = 0; i < found.length; i++) {
        turn.steps.add(ImageRef(
            offset: _offsetOfRecord(r, baseOffset),
            index: i,
            mediaType: found[i].text,
            bytes: found[i].bytes,
            thumb: found[i].thumb));
      }
    }
    // Pi models tool results as their own role rather than a content block.
    if (role == 'toolResult') {
      final block = _Block('tool_result', _resultText(msg['content']),
          resultFor: msg['toolCallId'] as String?, isError: msg['isError'] == true);
      if (_attachResult(turn, block)) return true;
      // A result whose call was never recorded still says work happened.
      turn.steps.add(ToolCall(
        id: (msg['toolCallId'] as String?) ?? '',
        name: (msg['toolName'] as String?) ?? 'tool',
      )..result = block.text);
      return true;
    }

    if (role != 'assistant') return false;
    var changed = false;
    for (final b in blocks) {
      switch (b.type) {
        case 'text':
          if (b.text.trim().isNotEmpty) {
            turn.steps.add(Reply(clampBlock(b.text)));
            changed = true;
          }
        case 'thinking':
          if (b.text.trim().isNotEmpty) {
            turn.steps.add(Reasoning(clampBlock(b.text)));
            changed = true;
          }
        case 'image':
          turn.steps.add(ImageRef(
              offset: _offsetOfRecord(r, baseOffset),
              mediaType: b.text,
              bytes: b.bytes,
              thumb: b.thumb));
          changed = true;
        case 'tool':
          if (b.call != null) {
            turn.steps.add(b.call!);
            changed = true;
          }
      }
    }
    return changed;
  }
}

/// Splits a byte stream into JSONL records.
///
/// Oversized lines are dropped without parsing — a multi-megabyte tool result
/// must not stall the records behind it — and a partial trailing line is held
/// until its newline arrives.
class JsonlFramer {
  static const maxLine = 256 * 1024;

  final _buffer = StringBuffer();
  bool _skippingOversized = false;
  bool _skippedLooksLikeImage = false;

  /// Byte offset of the next record, counted from the start of everything fed
  /// to this framer. A caller that knows where its window began can turn that
  /// into a position in the file — which is the only stable way to point at
  /// one record, since counting from either end shifts as the file grows.
  int _offset = 0;
  int _recordStart = 0;
  int _skippedBytes = 0;

  /// Does a record too big to hold look like it was big because of a
  /// picture? Each agent spells it differently: Claude nests `"type":
  /// "image"` with base64, Pi uses `mimeType`, Codex writes `input_image`
  /// with a data URL.
  static bool _looksLikeImage(String text) =>
      (text.contains('"image"') || text.contains('input_image') ||
              text.contains('image_url')) &&
      (text.contains('base64') || text.contains('mimeType') ||
          text.contains('data:image'));

  Iterable<Map<String, dynamic>> add(String chunk) sync* {
    var rest = chunk;
    while (true) {
      final nl = rest.indexOf('\n');
      if (nl < 0) {
        // Bytes skipped are still bytes of the file: they count towards the
        // offset, which is what a picture is fetched by.
        if (_skippingOversized) {
          _skippedBytes += utf8.encode(rest).length;
          return;
        }
        _buffer.write(rest);
        if (_buffer.length > maxLine) {
          _recordStart = _offset;
          final held = _buffer.toString();
          _skippedLooksLikeImage = _looksLikeImage(held);
          _skippedBytes = utf8.encode(held).length;
          _buffer.clear();
          _skippingOversized = true;
        }
        return;
      }
      final head = rest.substring(0, nl);
      rest = rest.substring(nl + 1);
      if (_skippingOversized) {
        _skippedBytes += utf8.encode(head).length;
        _offset = _recordStart + _skippedBytes + 1;
        _skippingOversized = false;
        // A dropped record still happened. An image is the one kind worth
        // announcing — they are the reason lines get this big — so the reader
        // sees a picture rather than nothing at all.
        if (_skippedLooksLikeImage) {
          _skippedLooksLikeImage = false;
          yield {
            '__dropped': 'image',
            '__offset': _recordStart,
            // Most of an image record is its payload, so its length is a fair
            // estimate of the picture — and better than saying nothing.
            '__bytes': (_skippedBytes * 3) ~/ 4,
          };
        }
        _skippedBytes = 0;
        continue;
      }
      final line = _buffer.toString() + head;
      _buffer.clear();
      _recordStart = _offset;
      _offset += utf8.encode(line).length + 1;
      if (line.trim().isEmpty || line.length > maxLine) {
        if (_looksLikeImage(line)) {
          yield {
            '__dropped': 'image',
            '__offset': _recordStart,
            '__bytes': (line.length * 3) ~/ 4,
          };
        }
        continue;
      }
      try {
        final obj = jsonDecode(line);
        if (obj is Map<String, dynamic>) {
          // The backfill arrives already stamped by the host, whose offsets
          // are the real ones; the framer's own count is for the live tail.
          obj.putIfAbsent('__offset', () => _recordStart);
          yield obj;
        }
      } catch (_) {
        // A malformed record is skipped, never fatal.
      }
    }
  }
}

/// Parses a transcript chunk into plain maps, off the UI thread.
///
/// Framing and JSON-decoding megabytes blocks long enough to trip Android's
/// ANR watchdog, so this runs in an isolate via `compute`. Plain maps rather
/// than [Turn]s because the result has to survive being copied between
/// isolates.
List<Map<String, dynamic>> parseTranscript(Map<String, String> request) {
  final adapter = TranscriptAdapter.forAgent(request['agent']);
  // Continue numbering where the cached turns left off, so incremental
  // results cannot collide with ids already on screen.
  adapter.seed(int.tryParse(request['seed'] ?? '') ?? 0);
  adapter.baseOffset = int.tryParse(request['base'] ?? '') ?? 0;
  final framer = JsonlFramer();
  for (final record in framer.add(request['text'] ?? '')) {
    adapter.addRecord(record);
  }
  final turns = adapter.turns;
  // Only the tail is worth keeping: older turns cost memory and layout time
  // for history nobody scrolls back to on a phone.
  const keep = 80;
  final kept = turns.length <= keep ? turns : turns.sublist(turns.length - keep);
  return [
    for (final t in kept)
      {
        'id': t.id,
        'userText': t.userText,
        // Carry the host's thumbnails across, so they are not fetched again.
        'steps': [for (final step in t.steps) step.toMap(withThumb: true)],
      }
  ];
}

/// Rebuilds [Turn]s from what the isolate sent back.
List<Turn> turnsFromMaps(List<Map<String, dynamic>> maps) => [
      for (final m in maps)
        Turn(id: m['id'] as String, userText: m['userText'] as String)
          ..steps.addAll([
            for (final step in (m['steps'] as List))
              TurnStep.fromMap((step as Map).cast<String, dynamic>())
          ]),
    ];
