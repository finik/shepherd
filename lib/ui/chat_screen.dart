import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../herdr/models.dart';
import '../state/app_state.dart';
import '../state/uploads.dart';
import 'agent_glyph.dart';
import 'blocked_prompt.dart';
import '../transcript/turn.dart';
import 'design.dart';
import 'turn_detail_screen.dart';

class ChatScreen extends StatefulWidget {
  final AppState state;

  const ChatScreen({super.key, required this.state});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    widget.state.chatVisible = true;
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    widget.state.chatVisible = false;
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The list is reversed, so offset 0 is the newest content. Auto-follow
  /// holds while the reader is within 80dp of it and releases when they
  /// scroll back.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final follow = _scroll.offset <= 80;
    if (follow != _follow) setState(() => _follow = follow);
  }

  String _lastContent = '';
  String? _lastStatus;
  bool _lastLoading = false;
  String? _lastActivity;
  String? _lastQuestion;
  ConnState? _lastConn;

  /// Rebuild only when something on this screen actually changed: a rebuild
  /// re-parses the markdown of every visible reply, and most notifications are
  /// about state the chat does not show.
  void _onState() {
    if (!mounted) return;
    final state = widget.state;
    final content = _signature(state);
    final status = state.selectedPane?.agentStatus;
    final loading = state.transcriptLoading;
    // A tool call mid-turn appends to the last turn without changing the turn
    // count, so the activity line needs its own comparison to ever update.
    final activity = _activity(state);
    // Compared as text: the record is rebuilt on every read, so identity
    // would say "changed" every three seconds.
    final asked = state.selectedPane == null
        ? null
        : state.blockedPrompt(state.selectedPane!.paneId);
    final question =
        asked == null ? null : '${asked.question}\u0000${asked.choices}';
    if (content == _lastContent &&
        state.conn == _lastConn &&
        status == _lastStatus &&
        loading == _lastLoading &&
        activity == _lastActivity &&
        question == _lastQuestion) {
      return;
    }
    _lastQuestion = question;
    _lastConn = state.conn;
    _lastContent = content;
    _lastStatus = status;
    _lastLoading = loading;
    _lastActivity = activity;
    setState(() {});
  }

  /// What is on screen, cheaply.
  ///
  /// The turn count alone is not enough: an agent that answers and keeps
  /// going appends every further sentence to the same turn, so the size of
  /// the last step counts too.
  static String _signature(AppState state) {
    // The composer is on this screen too: an upload that fills a chip has to
    // count as something changing, or the chip sits at nought per cent.
    final sending = state.uploading
        ? 'u${state.uploadingName}${(state.uploadProgress * 50).round()}'
        : '';
    // A thumbnail fetched after the thread was drawn changes what is on
    // screen without changing a single turn.
    final pictures = 'p${state.thumbsArrived}';
    final turns = state.turns;
    if (turns.isEmpty) return '0$sending$pictures';
    final last = turns.last;
    final step = last.steps.isEmpty ? null : last.steps.last;
    final tail = switch (step) {
      Reply(:final text) => 'r${text.length}',
      Reasoning(:final text) => 'n${text.length}',
      Failure(:final message) => 'f${message.length}',
      ToolCall(:final result) => 't${result.length}',
      ImageRef(:final offset) => 'i$offset',
      null => '-',
    };
    return '${turns.length}.${last.userText.length}.${last.steps.length}'
        '.$tail$sending$pictures';
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final state = widget.state;
    final width = MediaQuery.of(context).size.width;
    final pad = width < 340 ? 12.0 : 16.0;

    return Scaffold(
      backgroundColor: d.ground,
      body: SafeArea(
        child: Column(
          children: [
            _header(d, state, pad),
            Expanded(child: _thread(d, state, pad)),
            if (state.selectedPane case final pane?)
              if (pane.isBlocked)
                if (state.blockedPrompt(pane.paneId) case final asked?)
                  BlockedPrompt(
                    asked: asked,
                    onAnswer: (choice) =>
                        state.answerPrompt(pane.paneId, choice),
                  ),
            if (_activity(state) case final activity?)
              _activityLine(d, activity, pad),
            _composerBar(d, state, pad),
          ],
        ),
      ),
    );
  }

  /// One wide tap target back to Sessions, carrying the title in full rather
  /// than truncating it into a subtitle.
  Widget _header(D d, AppState state, double pad) {
    final pane = state.selectedPane;
    return InkWell(
      onTap: () => Navigator.of(context).maybePop(),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: d.divider, width: 2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.arrow_back, size: 15, color: d.ink3),
                const SizedBox(width: 6),
                AgentGlyph(agent: pane?.agent, size: 13),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '~/${pane?.shortCwd ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: d.meta.copyWith(fontSize: 11, color: d.ink3),
                  ),
                ),
                // State is already unmistakable in the composer; this
                // corner is better spent on the things you might want to do.
                GestureDetector(
                  onTap: () => _openMenu(pane),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Icon(Icons.more_vert, size: 20, color: d.ink2),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(pane?.sessionName ?? 'Shepherd', style: d.screenTitle),
          ],
        ),
      ),
    );
  }

  /// Everything you might want to do to this agent.
  Future<void> _openMenu(Pane? pane) async {
    if (pane == null) return;
    final d = D.of(context);
    final state = widget.state;
    final git = state.gitState(pane.paneId);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: d.ground,
      builder: (sheetContext) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
                child: Text(pane.sessionName, style: d.rowTitle),
              ),
              if (git != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    git.isDirty
                        ? '${git.branch} · ${git.dirty} uncommitted'
                        : '${git.branch} · clean',
                    style: d.label.copyWith(
                      color: git.isDirty ? d.ink2 : d.ink3,
                    ),
                  ),
                )
              else
                const SizedBox(height: 8),
              const Divider(height: 1),
              ListTile(
                title: Text('Rename', style: d.rowTitle),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _rename(pane);
                },
              ),
              _menuToggle(d, 'Show chain of thought', state.showThinking, (v) {
                state.setShowThinking(v);
                setSheetState(() {});
                setState(() {});
              }),
              _menuToggle(d, 'Show tool calls', state.showTools, (v) {
                state.setShowTools(v);
                setSheetState(() {});
                setState(() {});
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuToggle(
    D d,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) => InkWell(
    onTap: () => onChanged(!value),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(child: Text(label, style: d.rowTitle)),
          SquareToggle(value: value),
        ],
      ),
    ),
  );

  Future<void> _rename(Pane pane) async {
    final controller = TextEditingController(text: pane.sessionName);
    final d = D.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: d.ground,
        title: Text('Rename', style: d.rowTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: d.prose.copyWith(fontSize: 15),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('RENAME'),
          ),
        ],
      ),
    );
    if (name != null) await widget.state.renamePane(pane.paneId, name);
  }

  Widget _thread(D d, AppState state, double pad) {
    final turns = state.turns;
    // A connection being made is a wait, not an error; only a failed one is
    // reported.
    if (state.conn == ConnState.failed) {
      return _empty(d, 'NOT CONNECTED', state.error ?? 'No session.', pad);
    }
    if (state.conn != ConnState.connected) {
      return turns.isEmpty ? _waiting(d, 'CONNECTING') : _list(d, turns, pad);
    }

    if (state.transcriptLoading && turns.isEmpty) {
      return _waiting(d, 'READING TRANSCRIPT');
    }

    if (turns.isEmpty) {
      return _empty(
        d,
        'NO TRANSCRIPT YET',
        state.transcriptDiagnostic ?? 'Nothing written in this folder yet.',
        pad,
      );
    }

    return _list(d, turns, pad);
  }

  /// One quiet line and a spinner: the only thing shown until there is a
  /// conversation to show, so nothing on screen is ever replaced by the real
  /// thing arriving.
  Widget _waiting(D d, String label) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            WorkingSpinner(color: d.ink3, size: 18),
            const SizedBox(height: 14),
            Text(label, style: d.label.copyWith(color: d.ink3)),
          ],
        ),
      );

  // Reversed: index 0 is the newest item, so the view opens anchored at the
  // latest turn without a scroll animation to get there.
  Widget _list(D d, List<Turn> turns, double pad) => ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        itemCount: turns.length,
        itemBuilder: (context, i) => _turn(d, turns[turns.length - 1 - i], pad),
      );

  /// User turn is a full-bleed band; the agent reply is unadorned prose at
  /// full measure. Fill and weight are the two channels that separate them —
  /// bubbles would spend a fifth of a 360dp measure on gutters.
  Widget _turn(D d, Turn turn, double pad) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (turn.userText.isNotEmpty)
          Container(
            width: double.infinity,
            color: d.fill,
            padding: EdgeInsets.fromLTRB(pad, 14, pad, 16),
            margin: const EdgeInsets.only(top: 8, bottom: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  turn.pending ? 'SENDING' : 'YOU',
                  style: d.kicker.copyWith(
                    color: turn.pending ? d.accentText : null,
                  ),
                ),
                const SizedBox(height: 8),
                if (withoutStagedPaths(turn.userText) case final message) ...[
                  if (message.text.isNotEmpty)
                    Text(message.text, style: d.userMessage),
                  if (message.files.isNotEmpty) ...[
                    if (message.text.isNotEmpty) const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        for (final name in message.files) _imageChip(d, name),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
        ..._reply(d, turn, pad),
        const SizedBox(height: 20),
      ],
    );
  }

  /// The reply as it was produced: prose, then the work done before the next
  /// sentence, then that sentence. Hoisting every call to the end of the turn
  /// puts the evidence after the conclusion it supports.
  List<Widget> _reply(D d, Turn turn, double pad) {
    final state = widget.state;
    final out = <Widget>[];
    final prose = <String>[];
    var reasoning = 0;
    var tools = 0;

    void flushProse() {
      if (prose.isEmpty) return;
      out.add(
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: MarkdownBody(
            data: prose.join('\n\n'),
            styleSheet: _markdownStyle(d),
          ),
        ),
      );
      prose.clear();
    }

    void flushLedger() {
      if (reasoning == 0 && tools == 0) return;
      out.add(_ledgerLine(d, turn, pad, reasoning, tools));
      reasoning = 0;
      tools = 0;
    }

    for (final step in turn.steps) {
      switch (step) {
        case Reply():
          flushLedger();
          prose.add(step.text);
        case Reasoning():
          if (!widget.state.showThinking) break;
          flushProse();
          reasoning++;
        case ToolCall():
          if (!widget.state.showTools) break;
          flushProse();
          tools++;
        case ImageRef():
          flushProse();
          flushLedger();
          out.add(_imageStep(d, state, step, pad));
        case Failure():
          flushProse();
          flushLedger();
          out.add(_failure(d, step.message, pad));
      }
    }
    flushProse();
    flushLedger();
    return out;
  }

  /// A picture in the conversation, fetched only if you ask for it.
  ///
  /// Transcripts carry images inline as base64 and they run to tens of
  /// megabytes — the largest in this host's files is 51MB — so nothing is
  /// loaded until it is tapped.
  Widget _imageStep(D d, AppState state, ImageRef ref, double pad) {
    final loaded = state.loadedImage(ref);
    if (loaded != null) {
      // Once fetched it stays in the thread: a picture you have opened is
      // part of the conversation, not a link to it.
      return Padding(
        padding: EdgeInsets.fromLTRB(pad, 6, pad, 6),
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _ImageView(bytes: loaded.bytes),
          )),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: Image.memory(
              loaded.bytes,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              // Decode at display size; the source can be a 12-megapixel
              // photograph and this is a phone.
              cacheWidth: 1080,
              errorBuilder: (_, __, ___) =>
                  Text('Could not decode', style: d.label.copyWith(color: d.ink3)),
            ),
          ),
        ),
      );
    }
    // A thumbnail the host made while it was reading the record anyway. A row
    // of text is easy to scroll past; a picture is not, and this one costs a
    // few kilobytes rather than a few hundred.
    final thumb = state.thumbFor(ref);
    final size = ref.bytes > 0 ? _sizeOf(ref.bytes) : '';
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 6, pad, 6),
      child: InkWell(
        onTap: () => _openImage(state, ref),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (thumb != null)
              Container(
                decoration:
                    BoxDecoration(border: Border.all(color: d.divider)),
                child: Image.memory(
                  thumb,
                  height: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.image_outlined, size: 16, color: d.ink2),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration:
                    BoxDecoration(border: Border.all(color: d.divider, width: 2)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.image_outlined, size: 16, color: d.ink2),
                    const SizedBox(width: 8),
                    Text('IMAGE', style: d.label.copyWith(color: d.ink2)),
                  ],
                ),
              ),
            const SizedBox(width: 10),
            Text(
              size.isEmpty ? 'tap to open' : '$size · tap to open',
              style: d.label.copyWith(fontSize: 10, color: d.ink3),
            ),
          ],
        ),
      ),
    );
  }

  /// The name of a staged file, without the directory or the collision stamp
  /// the host name carries.
  static String _shortName(String remotePath) {
    final base = remotePath.split('/').last;
    final dash = base.indexOf('-');
    final name = dash < 0 ? base : base.substring(dash + 1);
    return name.length <= 22 ? name : '…${name.substring(name.length - 21)}';
  }

  /// How big the picture is, in the unit a person would use for it.
  static String _sizeOf(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';

  Future<void> _openImage(AppState state, ImageRef ref) async {
    final d = D.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final loading = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(child: WorkingSpinner(color: d.accentField, size: 22)),
    );
    final image = await state.loadImage(ref);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    setState(() {});
    unawaited(loading);
    if (image == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not load that image')));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ImageView(bytes: image.bytes),
    ));
  }

  /// A staged file, or one on its way.
  ///
  /// [progress] fills the chip itself rather than adding a bar beside it:
  /// this is a phone, the thing being described is two centimetres wide, and
  /// a second control to explain the first one is one too many.
  Widget _imageChip(D d, String label, {double? progress}) => Container(
    decoration: BoxDecoration(border: Border.all(color: d.ink3, width: 1)),
    child: Stack(
      children: [
        if (progress != null)
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: progress.clamp(0.02, 1),
              child: Container(color: d.divider),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                progress == null || progress >= 1
                    ? Icons.attach_file
                    : Icons.arrow_upward,
                size: 14,
                color: d.ink2,
              ),
              const SizedBox(width: 6),
              Text(
                label.toUpperCase(),
                style: d.label.copyWith(fontSize: 10, color: d.ink2),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  /// The agent answered with nothing and a reason. Said plainly and in the
  /// accent, because a turn that silently produced no reply is the one thing
  /// a chat must never render as an empty gap.
  Widget _failure(D d, String text, double pad) => Container(
    margin: EdgeInsets.fromLTRB(pad, 6, pad, 0),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: d.accentField, width: 2),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('NO REPLY', style: d.label.copyWith(color: d.accentText)),
        const SizedBox(height: 6),
        Text(text, style: d.prose.copyWith(fontSize: 13, color: d.ink2)),
      ],
    ),
  );

  /// A ledger, not a chip: one flush-left mono line closing every turn, the
  /// same weight as other metadata, so it disappears while reading and is
  /// findable when auditing.
  Widget _ledgerLine(D d, Turn turn, double pad, int steps, int tools) {
    final parts = <String>[
      if (steps > 0) '$steps STEP${steps == 1 ? '' : 'S'}',
      if (tools > 0) '$tools TOOL${tools == 1 ? '' : 'S'}',
    ];
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TurnDetailScreen(
            turn: turn,
            showThinking: widget.state.showThinking,
            showTools: widget.state.showTools,
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(pad, 14, pad, 4),
        child: Text(
          '— ${parts.join(' · ')}',
          style: d.label.copyWith(color: d.ink3),
        ),
      ),
    );
  }

  MarkdownStyleSheet _markdownStyle(D d) => MarkdownStyleSheet(
    p: d.prose,
    pPadding: const EdgeInsets.only(bottom: D.proseParagraphGap),
    h1: d.replyHeading,
    h2: d.replyHeading,
    h3: d.replyHeading,
    h1Padding: const EdgeInsets.only(top: 22, bottom: 8),
    h2Padding: const EdgeInsets.only(top: 22, bottom: 8),
    h3Padding: const EdgeInsets.only(top: 22, bottom: 8),
    strong: d.prose.copyWith(fontWeight: FontWeight.w700),
    em: d.prose.copyWith(fontStyle: FontStyle.italic),
    listBullet: d.listItem,
    listIndent: 18,
    code: d.inlineCode,
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(color: d.fill),
    blockquote: d.prose.copyWith(color: d.ink2),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: d.divider, width: 2)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 12),
    a: d.prose.copyWith(color: d.accentText),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: d.divider, width: 2)),
    ),
  );

  Widget _empty(D d, String title, String body, double pad) => Padding(
    padding: EdgeInsets.symmetric(horizontal: pad),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: d.label.copyWith(color: d.ink)),
        const SizedBox(height: 10),
        Text(
          body,
          style: body.contains('/')
              ? d.liveTail.copyWith(color: d.ink2)
              : d.prose.copyWith(color: d.ink2),
        ),
      ],
    ),
  );

  /// The last thing the agent did in the turn still in flight.
  ///
  /// The transcript is appended per tool call, so this changes several times
  /// within a turn — which is the whole point: a spinner says work is
  /// happening, this says what.
  String? _activity(AppState state) {
    if (!state.agentWorking) return null;
    final turns = state.turns;
    if (turns.isEmpty) return null;
    // The last step, whichever kind it is: a thought that has not led to a
    // call yet is as much "what is happening" as the call that follows it,
    // and showing only calls leaves the line stale through long reasoning.
    for (final step in turns.last.steps.reversed) {
      switch (step) {
        case ToolCall():
          return step.label;
        case Reasoning():
          final line = firstLineOf(step.text);
          if (line.isNotEmpty) return line;
        case Reply():
        case Failure():
        case ImageRef():
          return null;
      }
    }
    return null;
  }

  /// A one-line strip between thread and composer, so it reads as the agent's
  /// current state rather than as another message in the transcript.
  Widget _activityLine(D d, String text, double pad) => Container(
    width: double.infinity,
    padding: EdgeInsets.fromLTRB(pad, 8, pad, 8),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: d.divider, width: 2)),
    ),
    child: Row(
      children: [
        WorkingSpinner(color: d.accentField, size: 12),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: d.liveTail.copyWith(color: d.ink2),
          ),
        ),
      ],
    ),
  );

  Widget _composerBar(D d, AppState state, double pad) {
    final working = state.agentWorking;
    return Container(
      padding: EdgeInsets.fromLTRB(pad, 10, pad, 12),
      decoration: BoxDecoration(
        color: d.ground,
        border: Border(top: BorderSide(color: d.divider, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_attached.isNotEmpty || state.uploading)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _attached.length; i++)
                    GestureDetector(
                      onTap: () => setState(() => _attached.removeAt(i)),
                      // Filled all the way: staged and ready to send.
                      child: _imageChip(d, '${_shortName(_attached[i])}  ×',
                          progress: 1),
                    ),
                  if (state.uploading)
                    _imageChip(
                      d,
                      '${_shortName(state.uploadingName)}  '
                          '${(state.uploadProgress * 100).round()}%',
                      progress: state.uploadProgress,
                    ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _composer,
                  minLines: 1,
                  maxLines: 5,
                  // Explicit text/send, or a multi-line field turns the Enter key
                  // into a newline and there is then no way to submit at all.
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(state),
                  style: d.prose.copyWith(fontSize: 15),
                  cursorColor: d.accentField,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    hintText: working ? 'Queue a message…' : 'Message',
                    hintStyle: d.prose.copyWith(fontSize: 15, color: d.ink3),
                  ),
                ),
              ),
              // Two things the keyboard cannot offer: a file off the phone,
              // and a way to stop what is running.
              GestureDetector(
                onTap: state.uploading ? null : () => _attach(state),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10, bottom: 6),
                  child: state.uploading
                      ? WorkingSpinner(color: d.ink3, size: 18)
                      : Icon(Icons.attach_file, size: 22, color: d.ink2),
                ),
              ),
              // Enter sends — including while the agent is working, which is what
              // queueing a message means. The only button worth the space is the
              // one the keyboard cannot offer.
              if (working) ...[
                const SizedBox(width: 6),
                StopControl(onTap: state.stop),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// Choose what to send: a picture from the gallery, or any file at all.
  ///
  /// The agent is handed a path, not bytes, so the useful question is not
  /// "can Shepherd send this" but "can the agent read it" — and for a log, a
  /// CSV, a PDF or a config the answer is already yes.
  Future<void> _attach(AppState state) async {
    final d = D.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: d.ground,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.image_outlined, color: d.ink2),
              title: Text('Photo', style: d.rowTitle),
              subtitle: Text('From the gallery, with a crop step',
                  style: d.label.copyWith(color: d.ink3)),
              onTap: () => Navigator.of(sheet).pop('photo'),
            ),
            ListTile(
              leading: Icon(Icons.attach_file, color: d.ink2),
              title: Text('File', style: d.rowTitle),
              subtitle: Text('A log, a CSV, a PDF — anything it can read',
                  style: d.label.copyWith(color: d.ink3)),
              onTap: () => Navigator.of(sheet).pop('file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    ({File file, String name})? picked;
    try {
      picked = choice == 'photo' ? await _pickPhoto(d) : await _pickFile();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open it: $e')));
      return;
    }
    if (picked == null || !mounted) return;
    await _stage(state, picked.file, picked.name);
  }

  Future<({File file, String name})?> _pickPhoto(D d) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
      maxWidth: 3000,
    );
    if (picked == null) return null;
    // Cropping is for pictures only.
    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop',
          toolbarColor: d.ground,
          toolbarWidgetColor: d.ink,
          statusBarColor: d.ground,
          activeControlsWidgetColor: d.accentField,
          backgroundColor: d.ground,
          lockAspectRatio: false,
        ),
      ],
    );
    final file = File(cropped?.path ?? picked.path);
    return (file: file, name: picked.name);
  }

  Future<({File file, String name})?> _pickFile() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return null;
    final chosen = picked.first;
    // Android hands back a `content://` URI, for which the package reports no
    // `path`, so the bytes are copied out to a local file first.
    // A folder of its own per pick: the same name picked twice must not land
    // on the copy left from the first time.
    final directory = await Directory(
            '${(await getTemporaryDirectory()).path}/picked-'
            '${DateTime.now().microsecondsSinceEpoch}')
        .create(recursive: true);
    final local = File('${directory.path}/${Uploads.safeName(chosen.name)}');
    await chosen.xFile.saveTo(local.path);
    return (file: local, name: chosen.name);
  }

  /// The upload in flight, if any, so a message sent while it runs waits for
  /// it rather than going without it.
  Future<void>? _staging;

  /// Put the file on the host and remember it for the next message.
  Future<void> _stage(AppState state, File file, String name) async {
    final done = Completer<void>();
    _staging = done.future;
    try {
      await _stageInner(state, file, name);
    } finally {
      done.complete();
      _staging = null;
    }
  }

  Future<void> _stageInner(AppState state, File file, String name) async {
    final messenger = ScaffoldMessenger.of(context);
    if (await file.length() > Uploads.maxBytes) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text('$name is too big to send over this link')));
      return;
    }
    final remote = await state.uploadAttachment(file, name);
    if (!mounted) return;
    if (remote == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not send $name')),
      );
      return;
    }
    setState(() => _attached.add(remote));
  }

  /// Files staged on the host, waiting to be sent with the next message.
  /// Kept out of the text field: the path is for the agent, not for you.
  final _attached = <String>[];

  Future<void> _send(AppState state) async {
    // A message sent while a file is still uploading waits for it, so the
    // attachment goes with it.
    if (_staging != null) await _staging;
    final text = _composer.text.trim();
    if (text.isEmpty && _attached.isEmpty) return;
    // The paths join the message on the way out, where the agent will read
    // them, and are shown back as markers when the transcript returns it.
    final message = [text, ..._attached].where((p) => p.isNotEmpty).join(' ');
    _composer.clear();
    setState(_attached.clear);
    _follow = true;
    state.send(message);
  }
}

/// Full screen, pinch to zoom, black behind: a picture is the only thing on
/// the page while you are looking at it.
class _ImageView extends StatelessWidget {
  final Uint8List bytes;

  const _ImageView({required this.bytes});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  maxScale: 8,
                  child: Center(child: Image.memory(bytes)),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
      );
}
