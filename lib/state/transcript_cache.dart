import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../transcript/adapters.dart';
import '../transcript/turn.dart';

/// What was already read from each transcript, kept across launches.
///
/// Without this, every restart re-reads megabytes over SSH before the first
/// line appears — and shows an empty thread while it does. The turns are the
/// same maps the parse isolate produces, so restoring them is a decode rather
/// than a re-parse.
class TranscriptCache {
  static const _fileName = 'transcripts.json';

  /// Bumped when a stored cache could be wrong rather than merely old; a
  /// cache from another version is a miss.
  static const _version = 2;

  @visibleForTesting
  static int get version => _version;

  /// Enough panes to cover a day's work without turning the cache into a
  /// second copy of every transcript on the host.
  static const _maxPanes = 8;
  static const _maxTurns = 40;

  final Map<String, CachedTranscript> _entries = {};

  Map<String, CachedTranscript> get entries => _entries;

  Future<void> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return;
      final raw = await file.readAsString();
      final decoded = await compute(_decode, raw);
      if (decoded.isEmpty) return;
      _entries
        ..clear()
        ..addAll(decoded);
    } catch (_) {
      // A cache that cannot be read is a cache miss, never a failure.
    }
  }

  void remember(String path, List<Turn> turns, int consumed, String? anchor) {
    if (turns.isEmpty) return;
    final kept = turns.length <= _maxTurns
        ? turns
        : turns.sublist(turns.length - _maxTurns);
    _entries[path] = CachedTranscript(
      turns: kept,
      consumed: consumed,
      anchor: anchor ?? '',
      touched: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> save() async {
    try {
      final newest = _entries.entries.toList()
        ..sort((a, b) => b.value.touched.compareTo(a.value.touched));
      final keep = newest.take(_maxPanes);
      final payload = <String, dynamic>{
        '_version': _version,
        for (final e in keep)
          e.key: {
            'consumed': e.value.consumed,
            'anchor': e.value.anchor,
            'touched': e.value.touched,
            'turns': [
              for (final t in e.value.turns)
                {
                  'id': t.id,
                  'userText': t.userText,
                  'steps': [for (final step in t.steps) step.toMap()],
                }
            ],
          }
      };
      final text = await compute(_encode, payload);
      await (await _file()).writeAsString(text);
    } catch (_) {
      // Losing the cache costs a slow open, nothing more.
    }
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }
}

class CachedTranscript {
  final List<Turn> turns;
  final int consumed;
  final String anchor;
  final int touched;

  const CachedTranscript({
    required this.turns,
    required this.consumed,
    required this.anchor,
    required this.touched,
  });
}

/// Both directions run off the UI thread: the file can hold a few hundred
/// turns, and this work lands exactly when the app is starting up.
String _encode(Map<String, dynamic> payload) => jsonEncode(payload);

@visibleForTesting
String encodeForTest(Map<String, dynamic> payload) => _encode(payload);

@visibleForTesting
Map<String, CachedTranscript> decodeForTest(String raw) => _decode(raw);

Map<String, CachedTranscript> _decode(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return {};
  if (decoded['_version'] != TranscriptCache._version) return {};
  final out = <String, CachedTranscript>{};
  decoded.forEach((key, value) {
    if (key is! String || key.startsWith('_') || value is! Map) return;
    final turns = value['turns'];
    if (turns is! List) return;
    out[key] = CachedTranscript(
      turns: turnsFromMaps([
        for (final t in turns)
          if (t is Map) t.cast<String, dynamic>()
      ]),
      consumed: (value['consumed'] as num?)?.toInt() ?? 0,
      anchor: (value['anchor'] as String?) ?? '',
      touched: (value['touched'] as num?)?.toInt() ?? 0,
    );
  });
  return out;
}
