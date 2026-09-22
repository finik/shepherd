import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/transcript/adapters.dart';
import 'package:shepherd/transcript/codex.dart';
import 'package:shepherd/transcript/turn.dart';

/// Codex records, as a rollout writes them.
///
/// Its file is not a conversation but an event log: most lines are token
/// counts, world state and `item_completed` events, and the conversation is
/// the subset typed `response_item`.
Map<String, dynamic> record(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void main() {
  final user = record('''
  {"type":"response_item","payload":{"type":"message","role":"user",
   "content":[{"type":"input_text","text":"In one sentence, what does tool/publish.sh do?"}]}}''');

  final assistant = record('''
  {"type":"response_item","payload":{"type":"message","role":"assistant",
   "phase":"final_answer",
   "content":[{"type":"output_text","text":"It builds a release APK and publishes it."}]}}''');

  final call = record('''
  {"type":"response_item","payload":{"type":"custom_tool_call","name":"exec",
   "call_id":"call_up2JJ","status":"completed",
   "input":"const r = await tools.exec_command({cmd:\\"sed -n '1,240p' tool/publish.sh\\",workdir:\\"/x\\"}); text(r.output);"}}''');

  final output = record('''
  {"type":"response_item","payload":{"type":"custom_tool_call_output",
   "call_id":"call_up2JJ",
   "output":[{"type":"input_text","text":"Script completed"},
             {"type":"input_text","text":"#!/usr/bin/env bash"}]}}''');

  CodexAdapter fresh() => TranscriptAdapter.forAgent('codex') as CodexAdapter;

  test('a codex pane gets the codex parser', () {
    expect(TranscriptAdapter.forAgent('codex'), isA<CodexAdapter>());
  });

  test('a turn is what you typed and what came back, in order', () {
    final a = fresh()
      ..addRecord(user)
      ..addRecord(assistant)
      ..addRecord(call)
      ..addRecord(output);
    final turn = a.turns.single;
    expect(turn.userText, 'In one sentence, what does tool/publish.sh do?');
    expect(turn.steps.map((s) => s.runtimeType.toString()),
        ['Reply', 'ToolCall']);
    final tool = turn.steps.last as ToolCall;
    expect(tool.result, contains('#!/usr/bin/env bash'));
  });

  test('the command inside the wrapper is what the tool line says', () {
    // Codex hands `exec` a snippet of JavaScript; the command a person would
    // recognise is a string argument inside it.
    final a = fresh()..addRecord(user)..addRecord(call);
    expect((a.turns.single.steps.single as ToolCall).detail,
        "sed -n '1,240p' tool/publish.sh");
  });

  test('the harness talking to the model is not a turn', () {
    // A session opens with instructions and an environment block, all sent
    // as user-role messages.
    final a = fresh()
      ..addRecord(record('''
      {"type":"response_item","payload":{"type":"message","role":"developer",
       "content":[{"type":"input_text","text":"<skills_instructions>…</skills_instructions>"}]}}'''))
      ..addRecord(record('''
      {"type":"response_item","payload":{"type":"message","role":"user",
       "content":[{"type":"input_text","text":"<environment_context>\\n  <cwd>/x</cwd>\\n</environment_context>"}]}}'''))
      ..addRecord(user);
    expect(a.turns.length, 1);
    expect(a.turns.single.userText, startsWith('In one sentence'));
  });

  test('a tag in the middle of a sentence is still your sentence', () {
    expect(CodexAdapter.isPreamble('<environment_context>\n x'), isTrue);
    expect(CodexAdapter.isPreamble('why is <div> escaped here?'), isFalse);
    expect(CodexAdapter.isPreamble('<Not a tag at all'), isFalse);
  });

  test('sealed reasoning is not shown as thinking', () {
    // `encrypted_content` is what it sounds like; the summary is usually
    // empty. An empty thought is worse than no thought.
    final a = fresh()
      ..addRecord(user)
      ..addRecord(record('''
      {"type":"response_item","payload":{"type":"reasoning","summary":[],
       "encrypted_content":"gAAAAA…"}}'''));
    expect(a.turns.single.steps, isEmpty);
  });

  test('a reasoning summary, when there is one, is shown', () {
    final a = fresh()
      ..addRecord(user)
      ..addRecord(record('''
      {"type":"response_item","payload":{"type":"reasoning",
       "summary":[{"type":"summary_text","text":"Read the script first."}]}}'''));
    expect(a.turns.single.steps.single, isA<Reasoning>());
  });

  test('bookkeeping is skipped', () {
    // Roughly half the file: token counts, world state, per-item events.
    final a = fresh()..addRecord(user);
    for (final json in [
      '{"type":"event_msg","payload":{"type":"task_started"}}',
      '{"type":"token_usage_record","payload":{"thread_id":"t"}}',
      '{"type":"world_state","payload":{"full":true}}',
      '{"type":"turn_context","payload":{"turn_id":"t"}}',
      '{"type":"session_meta","payload":{"cwd":"/x"}}',
    ]) {
      expect(a.addRecord(record(json)), isFalse, reason: json);
    }
    expect(a.turns.single.steps, isEmpty);
  });
}
