/// One thing the agent emitted inside a turn.
///
/// A turn is a sequence, not three buckets: the agent reasons, calls a tool,
/// says a sentence, calls three more, says another. Keeping prose in one list
/// and calls in another puts every call at the end of the reply, which is
/// where none of them happened.
sealed class TurnStep {
  const TurnStep();

  /// [withThumb] carries a picture's thumbnail across an isolate boundary.
  /// It is left out by default because the same map is what the on-disk
  /// cache stores, and that cache is the app's preferences file.
  Map<String, dynamic> toMap({bool withThumb = false});

  static TurnStep fromMap(Map<String, dynamic> m) => switch (m['kind']) {
        'tool' => ToolCall.fromMap((m['tool'] as Map).cast<String, dynamic>()),
        'reasoning' => Reasoning((m['text'] as String?) ?? ''),
        'image' => ImageRef.fromMap(m),
        'failure' => Failure((m['text'] as String?) ?? ''),
        _ => Reply((m['text'] as String?) ?? ''),
      };
}

/// Prose the agent addressed to the reader.
class Reply extends TurnStep {
  final String text;
  const Reply(this.text);

  @override
  Map<String, dynamic> toMap({bool withThumb = false}) =>
      {'kind': 'reply', 'text': text};
}

/// Thinking, when the agent records it: Pi does, Claude Code does not, and
/// Codex encrypts it.
class Reasoning extends TurnStep {
  final String text;
  const Reasoning(this.text);

  @override
  Map<String, dynamic> toMap({bool withThumb = false}) =>
      {'kind': 'reasoning', 'text': text};
}

/// Why the agent produced nothing. An agent whose token expired writes an
/// empty reply and a reason; showing the empty half is how a dead session
/// passes for a quiet one.
class Failure extends TurnStep {
  final String message;
  const Failure(this.message);

  @override
  Map<String, dynamic> toMap({bool withThumb = false}) =>
      {'kind': 'failure', 'text': message};
}

/// A picture in the conversation, not the picture itself.
///
/// Transcripts carry images inline as base64 — a median Pi record is 657KB
/// and the largest here is 51MB — so the bytes are deliberately not kept.
/// What is kept is enough to find that one record again and fetch it when
/// somebody actually wants to look at it.
class ImageRef extends TurnStep {
  /// Byte offset of the record this image came from.
  ///
  /// An offset is fixed as the file grows, and lets the host seek straight to
  /// the record.
  final int offset;

  /// "image/jpeg" when the record said; empty when it was too big to parse.
  final String mediaType;

  /// Roughly how many bytes the record occupied, for the placeholder.
  final int bytes;

  /// Which picture this is within its record.
  ///
  /// One tool result can carry several — a subagent that read three cards
  /// writes all three into one line.
  final int index;

  /// A few kilobytes of JPEG, base64, made on the host while it was reading
  /// the record anyway.
  ///
  /// A row saying "tap to load" is easy to scroll straight past; a picture is
  /// not. This is small enough to carry for every image in the window and far
  /// too small to read, which is what the tap is still for. It is deliberately
  /// absent from [toMap]: the cache is the app's preferences file, and a
  /// thumbnail is cheap to ask for again.
  final String? thumb;

  const ImageRef({
    required this.offset,
    this.index = 0,
    this.mediaType = '',
    this.bytes = 0,
    this.thumb,
  });

  /// What the host is asked for: a place in the file and a place in the
  /// record.
  String get key => '$offset:$index';

  @override
  Map<String, dynamic> toMap({bool withThumb = false}) => {
        'kind': 'image',
        'offset': offset,
        'index': index,
        'mediaType': mediaType,
        'bytes': bytes,
        if (withThumb && thumb != null) 'thumb': thumb,
      };

  static ImageRef fromMap(Map<String, dynamic> m) => ImageRef(
        offset: (m['offset'] as num?)?.toInt() ?? 0,
        index: (m['index'] as num?)?.toInt() ?? 0,
        mediaType: (m['mediaType'] as String?) ?? '',
        bytes: (m['bytes'] as num?)?.toInt() ?? 0,
        thumb: m['thumb'] as String?,
      );
}

/// One call the agent made, with whatever came back.
///
/// The name alone answers "what kind of work"; the descriptor answers "on
/// what"; the input and result answer "and what actually happened" — which is
/// only worth reading one call at a time, so the last two are kept clamped.
class ToolCall extends TurnStep {
  final String id;
  final String name;

  /// A short human phrase: Claude's own `description`, a file basename, or the
  /// first line of a command.
  final String detail;

  /// The arguments, pretty-printed.
  final String input;

  String result = '';
  bool isError = false;

  ToolCall({
    required this.id,
    required this.name,
    this.detail = '',
    this.input = '',
  });

  /// One line for the activity strip and the list row.
  String get label => detail.isEmpty ? name : '$name · $detail';

  bool get hasDetail => input.isNotEmpty || result.isNotEmpty;

  @override
  Map<String, dynamic> toMap({bool withThumb = false}) => {
        'kind': 'tool',
        'tool': {
          'id': id,
          'name': name,
          'detail': detail,
          'input': input,
          'result': result,
          'isError': isError,
        },
      };

  static ToolCall fromMap(Map<String, dynamic> m) => ToolCall(
        id: (m['id'] as String?) ?? '',
        name: (m['name'] as String?) ?? 'tool',
        detail: (m['detail'] as String?) ?? '',
        input: (m['input'] as String?) ?? '',
      )
        ..result = (m['result'] as String?) ?? ''
        ..isError = m['isError'] == true;
}

/// One exchange: a user message plus everything the agent produced in reply.
///
/// The UI list is turns, not messages — appending messages without emitting
/// turn inserts is what makes a transcript view freeze on its first snapshot.
class Turn {
  final String id;
  final String userText;

  /// True for a message typed here that the agent has not yet written to its
  /// transcript. It is shown straight away and replaced by the real record.
  final bool pending;

  /// Everything the agent emitted, in the order it emitted it.
  final List<TurnStep> steps = [];

  Turn({required this.id, required this.userText, this.pending = false});

  Iterable<String> get assistantTexts =>
      steps.whereType<Reply>().map((r) => r.text);
  Iterable<String> get thinkingTexts =>
      steps.whereType<Reasoning>().map((r) => r.text);
  Iterable<ToolCall> get tools => steps.whereType<ToolCall>();
  Iterable<ImageRef> get images => steps.whereType<ImageRef>();
  Iterable<String> get errors =>
      steps.whereType<Failure>().map((f) => f.message);

  String get assistantText => assistantTexts.join('\n\n');

  int get thinkingCount => thinkingTexts.length;
  int get toolCount => tools.length;

  /// The most recent thing the agent did, for the in-flight indicator.
  String? get lastActivity => tools.isEmpty ? null : tools.last.label;

  bool get hasContent => steps.isNotEmpty;
}

/// Cap any single block so one 3 MB tool result can't wedge the UI.
String clampBlock(String s, {int max = 8192}) =>
    s.length <= max ? s : '${s.substring(0, max)}\n… (truncated)';

/// First non-empty line, clamped — what an in-flight thought looks like on one
/// line of a list row or an activity strip.
String firstLineOf(String text, {int max = 90}) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    return trimmed.length > max
        ? '${trimmed.substring(0, max).trimRight()}…'
        : trimmed;
  }
  return '';
}

/// Paths to files staged for an agent, as they appear inside a message.
///
/// Herdr's pasted images and Shepherd's attachments each have a staging
/// directory of their own, and an attachment can be any file an agent can
/// read — a log, a CSV, a PDF.
final RegExp stagedFilePattern = RegExp(
    r'\S*(?:herdr-clipboard-images|shepherd-uploads)-\d+/[^\s]+',
    caseSensitive: false);

/// What an agent wrapped around what you typed, taken back off.
///
/// Claude Code brackets pasted text in `<pasted_content id="…">` before it
/// reaches the transcript. It is the agent's bookkeeping about the message,
/// not the message, and a phone is a device people paste into.
final _wrapperLine =
    RegExp(r'^\s*</?pasted_content\b[^>]*>\s*$', multiLine: true);

String withoutWrappers(String text) =>
    text.replaceAll(_wrapperLine, '').trim();

/// A message with its staged paths replaced by the files' names.
///
/// The agent is given a path because that is what it can read; a path is not
/// what the sender needs to see afterwards.
({String text, List<String> files}) withoutStagedPaths(String text) {
  final files = <String>[];
  final shortened = text.replaceAllMapped(stagedFilePattern, (match) {
    files.add(attachmentName(match[0]!));
    return '[${files.last}]';
  });
  return (text: shortened.replaceAll(RegExp(r' {2,}'), ' ').trim(),
      files: files);
}

/// What to call a staged file when showing it back to the person who sent it.
///
/// The host name carries a collision stamp in front of the real one, which is
/// for the filesystem rather than for reading.
String attachmentName(String remotePath) {
  final base = remotePath.split('/').last;
  final dash = base.indexOf('-');
  final name = dash < 0 ? base : base.substring(dash + 1);
  return name.isEmpty ? 'attachment' : name;
}
