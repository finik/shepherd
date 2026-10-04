import 'dart:convert';

import 'adapters.dart';
import 'turn.dart';

/// Muse keeps a session as an event log, not a conversation.
///
/// Every line is a runtime event; the conversation is the subset with
/// `payload_type: "runtime.session"` and `payload.kind: "run"`, whose
/// `event.kind` says what happened: `started` carries your prompt,
/// `assistant_message_committed` a reply, `assistant_tool_calls_committed`
/// the calls and `tool_result_batch_committed` their results, matched by
/// call id. A picture a tool read arrives on its own as
/// `tool_result_model_visible_content`. Reasoning is encrypted; only its
/// summary is readable. A turn that failed ends with a `terminal` event
/// that says why.
///
/// Background work — reminders, subagents — runs as `task` events and in
/// files of its own, and is not part of the conversation.
class MuseAdapter implements TranscriptAdapter {
  @override
  ContextUsage? usage;

  @override
  final List<Turn> turns = [];
  @override
  int baseOffset = 0;
  int _seq = 0;

  /// Calls waiting for their result, by call id.
  final Map<String, ToolCall> _open = {};

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
    if (r['payload_type'] != 'runtime.session') return false;
    final payload = r['payload'];
    if (payload is! Map || payload['kind'] != 'run') return false;
    final event = payload['event'];
    if (event is! Map) return false;

    switch (event['kind']) {
      case 'started':
        final prompt = event['prompt'];
        if (prompt is! String || prompt.trim().isEmpty) return false;
        turns.add(Turn(
            id: 'm${_seq++}',
            userText: clampBlock(withoutWrappers(prompt.trim()), max: 4000)));
        return true;
      case 'model_completed':
        final u = event['usage'];
        final used = u is Map ? (u['input_tokens'] as num?)?.toInt() : null;
        if (used != null && used > 0) {
          usage = ContextUsage(
              used: used, model: (event['model'] as String?) ?? '');
        }
        return false;
      case 'assistant_message_committed':
        final text = event['text'];
        if (turns.isEmpty || text is! String || text.trim().isEmpty) {
          return false;
        }
        turns.last.steps.add(Reply(clampBlock(text)));
        return true;
      case 'reasoning_summary_committed':
        final text = event['text'];
        if (turns.isEmpty || text is! String || text.trim().isEmpty) {
          return false;
        }
        turns.last.steps.add(Reasoning(clampBlock(text)));
        return true;
      case 'assistant_tool_calls_committed':
        return _calls(event['tool_calls']);
      case 'tool_result_batch_committed':
        return _results(event['results']);
      case 'tool_result_model_visible_content':
        return _pictures(r, event['content']);
      case 'terminal':
        final reason = event['reason'];
        if (turns.isEmpty ||
            event['terminal'] != 'failed' ||
            reason is! String ||
            reason.isEmpty) {
          return false;
        }
        turns.last.steps.add(Failure(reason));
        return true;
    }
    return false;
  }

  bool _calls(dynamic calls) {
    if (turns.isEmpty || calls is! List) return false;
    var changed = false;
    for (final call in calls) {
      if (call is! Map) continue;
      final id = (call['call_id'] ?? call['id'] ?? '') as String;
      final name = (call['name'] as String?) ?? 'tool';
      final raw = call['args'];
      Map<String, dynamic>? args;
      if (raw is String) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) args = decoded;
        } catch (_) {}
      } else if (raw is Map<String, dynamic>) {
        args = raw;
      }
      final step = ToolCall(
        id: id,
        name: name,
        detail: describeTool(name, args),
        input: clampBlock(args == null
            ? (raw?.toString() ?? '')
            : const JsonEncoder.withIndent('  ').convert(args)),
      );
      turns.last.steps.add(step);
      _open[id] = step;
      changed = true;
    }
    return changed;
  }

  bool _results(dynamic results) {
    if (results is! List) return false;
    var changed = false;
    for (final result in results) {
      if (result is! Map) continue;
      final call = _open.remove(result['tool_call_id']);
      if (call == null) continue;
      final text = (result['text'] as String?) ?? '';
      call.result = clampBlock(text);
      // A command's result is a JSON report; a non-zero exit is a failure.
      try {
        final report = jsonDecode(text);
        if (report is Map && report['exit_code'] is num) {
          call.isError = report['exit_code'] != 0;
        }
      } catch (_) {}
      if (result['is_error'] == true) call.isError = true;
      changed = true;
    }
    return changed;
  }

  bool _pictures(Map<String, dynamic> record, dynamic content) {
    if (turns.isEmpty || content is! List) return false;
    var index = 0;
    var changed = false;
    for (final block in content) {
      if (block is! Map || block['kind'] != 'image') continue;
      final data = block['base64_data'] as String?;
      turns.last.steps.add(ImageRef(
        offset: offsetOfRecord(record, baseOffset),
        index: index++,
        mediaType: (block['media_type'] as String?) ?? '',
        bytes: (block['__bytes'] as num?)?.toInt() ??
            (data == null ? 0 : (data.length * 3) ~/ 4),
        thumb: block['__thumb'] as String?,
      ));
      changed = true;
    }
    return changed;
  }
}
