import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../herdr/client.dart';
import '../herdr/models.dart';
import 'machines.dart';
import 'push.dart';
import 'transcript_cache.dart';
import 'updater.dart';
import 'uploads.dart';
import 'watch.dart';
import '../transcript/adapters.dart';
import '../transcript/turn.dart';

enum ConnState { idle, connecting, connected, failed }

/// One answer an agent will accept, and what it said about it.
class Choice {
  final String label;

  /// The line or two Claude writes under an option. On a phone this is the
  /// difference between agreeing to one edit and agreeing to every edit for
  /// the rest of the session.
  final String detail;

  /// Whether the menu's cursor is on this option right now — the one the
  /// agent's `❯` or `›` points at, or the one OpenCode draws highlighted.
  /// Enter picks whatever that is.
  final bool selected;

  /// Options laid out in a row — OpenCode's "Allow once   Allow always
  /// Reject" — are moved between with left and right rather than up and down.
  final bool sideways;

  const Choice({
    required this.label,
    this.detail = '',
    this.selected = false,
    this.sideways = false,
  });

  @override
  bool operator ==(Object other) =>
      other is Choice && other.label == label && other.detail == detail;

  @override
  int get hashCode => Object.hash(label, detail);

  @override
  String toString() =>
      '${selected ? '> ' : ''}${detail.isEmpty ? label : '$label — $detail'}';
}

/// How much transcript tail to pull on a pane switch.
const _backfillBytes = 512 * 1024;

/// Widen the history window until it holds at least this many turns. One
/// record can be tens of KB, so a fixed window covers wildly different
/// amounts of conversation depending on how the agent has been working.
const _minBackfillTurns = 12;

/// Ceiling on that widening; past this the wire cost is not worth it.
const _maxBackfillBytes = 2 * 1024 * 1024;

/// What the live adapter keeps, matching what the parse isolate keeps.
const _maxLiveTurns = 80;

/// Where Herdr's default session socket lives, relative to the login home.
const _defaultSocketSuffix = '.config/herdr/herdr.sock';

class AppState extends ChangeNotifier {
  ConnState conn = ConnState.idle;
  String? error;
  /// The host as Herdr last described it, with one correction: a Pi or omp
  /// pane showing a question is waiting on you whatever Herdr says.
  HostState get host => _hostView ??= _withScreenBlocks(_host);
  set host(HostState value) {
    _host = value;
    _hostView = null;
  }

  HostState _host = const HostState();
  HostState? _hostView;

  /// Panes Herdr reports as working whose screen shows a question. Pi's
  /// Herdr integration reports blocked only when the extension asking says
  /// so, and a question tool need not.
  final Set<String> _screenBlocked = {};

  HostState _withScreenBlocks(HostState raw) {
    if (_screenBlocked.isEmpty) return raw;
    Pane mark(Pane p) => _screenBlocked.contains(p.paneId) && p.isWorking
        ? p.withStatus('blocked')
        : p;
    return HostState(
      workspaces: raw.workspaces,
      tabs: raw.tabs,
      panes: raw.panes.map(mark).toList(),
      agents: raw.agents.map(mark).toList(),
      focusedWorkspaceId: raw.focusedWorkspaceId,
      focusedTabId: raw.focusedTabId,
      focusedPaneId: raw.focusedPaneId,
    );
  }
  String? selectedPaneId;

  List<Turn> turns = const [];

  /// True between selecting a pane and the first records arriving. Without it
  /// Chat shows "no transcript" for the second before the tail lands, which
  /// reads as an empty conversation and then jumps.
  ///
  /// This is never resolved on a timer: over a real network the backfill can
  /// take far longer than any timeout worth waiting on, and giving up would
  /// claim there is no transcript while one is still arriving. It clears only
  /// when we know — records arrived, or the file genuinely is not there.
  bool transcriptLoading = false;

  /// Why there is no transcript, in the user's words rather than a stack
  /// trace. "Nothing here" and "I looked in the wrong place" are the same
  /// screen otherwise, and only one of them is your fault.
  String? transcriptDiagnostic;
  bool showThinking = true;
  bool showTools = true;
  /// How you are told an agent stopped: 'off', 'push' (Herdr's plugin sends
  /// to this device) or 'poll' (the app watches from a foreground service).
  /// One or the other — running both means every event arrives twice.
  String notifyMode = 'off';

  /// Do not notify if the host saw a key or a click within this many minutes:
  /// an agent you are sitting in front of does not need to buzz your pocket.
  /// 0 means always notify.
  int quietMinutes = 0;
  bool sending = false;

  SSHClient? _ssh;
  HerdrClient? _rpc;
  HerdrEventStream? _eventConn;
  SSHSession? _tailSession;
  bool _tailAlive = false;
  bool _rebinding = false;
  TranscriptAdapter? _adapter;
  Timer? _resnapshot;
  Timer? _poll;
  int _pollFailures = 0;

  /// Turns already parsed for a transcript, and how many bytes of it we have
  /// consumed. Transcripts only grow, so a later visit fetches the difference
  /// rather than the tail all over again.
  final Map<String, List<Turn>> _cachedTurns = {};
  final Map<String, int> _consumed = {};

  /// The last stretch of bytes consumed from each transcript, used to prove
  /// the file was appended to rather than rewritten under the same offset.
  final Map<String, String> _anchors = {};

  /// Incremented on every bind. The previous tail's stream can outlive its
  /// session, so records are taken only from the current bind — a re-bind to
  /// the same file would otherwise feed every record twice.
  int _bindEpoch = 0;

  /// Incremented on every connect and disconnect. A connect that loses the
  /// race must not write _ssh, host or conn on top of the one that won.
  int _connectGeneration = 0;

  Pane? get selectedPane =>
      host.paneById(selectedPaneId) ?? host.focusedPane;

  bool get agentWorking => selectedPane?.isWorking ?? false;

  /// Push a change to the screens, as the transcript tail does.
  @visibleForTesting
  void notifyForTest() => notifyListeners();


  Machine? activeMachine;

  /// Verbatim text of what a blocked agent is asking, per pane. Approval
  /// prompts live only in the TUI — they are never written to the transcript —
  /// so the Sessions field has to read them off the pane.
  final Map<String, ({String question, List<Choice> choices})>
      _blockedPrompts = {};
  Machine? _lastMachine;
  String? _lastKey;
  String? _lastPassword;

  ({String question, List<Choice> choices})? blockedPrompt(String paneId) =>
      _blockedPrompts[paneId];

  /// One line of what each agent last said, for the Sessions list. The folder
  /// is already the row's title when the agent gave no name, so repeating it
  /// underneath says nothing; the last thing it said says a great deal.
  final Map<String, String> _previews = {};
  final Map<String, int> _previewSeq = {};
  final Map<String, int> _previewSize = {};
  DateTime _lastSizeCheck = DateTime.fromMillisecondsSinceEpoch(0);
  bool _previewsInFlight = false;
  DateTime _lastPreviewFetch = DateTime.fromMillisecondsSinceEpoch(0);

  String? preview(String paneId) => _previews[paneId];

  /// Branch and uncommitted-file count for each agent's working directory.
  /// An agent that has been editing for an hour looks identical to an idle
  /// one until you can see what it has left lying around.
  final Map<String, GitState> _git = {};

  GitState? gitState(String paneId) => _git[paneId];

  /// "25% · 14.6 / 55.9 MB" — the megabytes move between percents, so the
  /// line keeps saying "alive" on a link slow enough that the percentage
  /// looks stuck.
  String get updateLabel {
    final percent = (updateProgress * 100).floor();
    if (updateTotal <= 0) return 'DOWNLOADING · $percent%';
    String mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
    return 'DOWNLOADING · $percent% · '
        '${mb(updateReceived)} / ${mb(updateTotal)} MB';
  }

  /// Build number published on the host, when it is newer than this one.
  int? updateBuild;
  double updateProgress = 0;
  int updateReceived = 0;
  int updateTotal = 0;
  bool updating = false;

  Future<void> checkForUpdate() async {
    final ssh = _ssh;
    if (ssh == null) return;
    final available = await Updater.availableBuild(ssh);
    final current = await Updater.currentBuild();
    final next = (available != null && available > current) ? available : null;
    if (next != updateBuild) {
      updateBuild = next;
      notifyListeners();
    }
  }

  Future<String> installUpdate() async {
    final ssh = _ssh;
    if (ssh == null || activeMachine == null) return 'FAILED · NOT CONNECTED';
    updating = true;
    updateProgress = 0;
    updateReceived = 0;
    updateTotal = 0;
    notifyListeners();
    // Stop polling for the duration: a 57MB transfer saturates the link, and
    // two timed-out snapshots would tear down the connection the download
    // shares.
    _poll?.cancel();
    _poll = null;
    try {
      // The transfer reports every 16KB chunk; twice a second is enough to
      // keep the megabyte counter moving without rebuilding every listening
      // screen 3,600 times.
      var lastNotified = DateTime.fromMillisecondsSinceEpoch(0);
      final machine = activeMachine!;
      return await Updater.install(
        ssh,
        host: machine.host,
        port: machine.port,
        user: machine.user,
        privateKeyPem: _lastKey,
        password: _lastPassword,
        onProgress: (received, total) {
          updateReceived = received;
          updateTotal = total;
          updateProgress = total > 0 ? received / total : 0;
          final now = DateTime.now();
          if (now.difference(lastNotified) <
                  const Duration(milliseconds: 500) &&
              received < total) {
            return;
          }
          lastNotified = now;
          notifyListeners();
        },
      );
    } catch (e) {
      return 'FAILED · ${e.toString().split('(').first.trim().toUpperCase()}';
    } finally {
      updating = false;
      if (conn == ConnState.connected) _startPolling();
      notifyListeners();
    }
  }

  /// Whether Chat is on screen. The live tail costs an SSH channel every
  /// 1.5s, so it must not keep running once nobody is looking at it.
  bool _chatVisible = false;
  DateTime _lastBlockedRead = DateTime.fromMillisecondsSinceEpoch(0);

  set chatVisible(bool value) {
    if (_chatVisible == value) return;
    _chatVisible = value;
  }

  Future<void> connect(
    Machine machine, {
    String? privateKeyPem,
    String? password,
  }) async {
    final keepScreen = _reconnecting;
    await disconnect(keepScreen: keepScreen);
    activeMachine = machine;
    _lastMachine = machine;
    _lastKey = privateKeyPem;
    _lastPassword = password;
    conn = ConnState.connecting;
    error = null;
    notifyListeners();
    final generation = ++_connectGeneration;

    try {
      final socket = await SSHSocket.connect(
        machine.host,
        machine.port,
        timeout: const Duration(seconds: 15),
      );
      final ssh = SSHClient(
        socket,
        username: machine.user,
        identities: (privateKeyPem == null || privateKeyPem.isEmpty)
            ? null
            : SSHKeyPair.fromPem(privateKeyPem),
        onPasswordRequest:
            (password == null || password.isEmpty) ? null : () => password,
      );
      // No timeout here means a host that accepts TCP and then stalls the
      // handshake — a phone that just changed networks — leaves the app in
      // "connecting" with nothing to retry.
      await ssh.authenticated.timeout(const Duration(seconds: 20));
      if (generation != _connectGeneration) {
        ssh.close();
        return;
      }
      _ssh = ssh;

      final path = await _resolveSocketPath(ssh);
      _rpc = HerdrClient(ssh, path);
      await _rpc!.call('ping');

      _eventConn = await _rpc!.subscribe();
      _eventConn!.events.listen(_onEvent, onError: (_) {});

      host = await _rpc!.snapshot();
      if (generation != _connectGeneration) return;
      _startPolling();
      selectedPaneId ??= host.focusedPaneId;
      conn = ConnState.connected;
      notifyListeners();
      unawaited(_refreshBlockedPrompts());
      unawaited(checkForUpdate());
      // Hand the host somewhere to push to. Doing it on every connect keeps
      // the file current through token rotation, which happens on its own
      // schedule and without telling anyone.
      if (notifyMode == 'push') unawaited(_registerForPush(ssh));
      unawaited(Push.setQuietMinutes(ssh, quietMinutes));

      // On a reconnect the chat already shows the conversation: join the
      // fresh read to it rather than swapping it out from under the reader.
      await _bindSelectedPane(silent: keepScreen && turns.isNotEmpty);
    } catch (e) {
      error = e.toString();
      // Between a reconnect's attempts the connection is still being made;
      // only the last attempt reports failure.
      conn = keepScreen ? ConnState.connecting : ConnState.failed;
      notifyListeners();
    }
  }

  /// Ask the host where its home is rather than making the user configure a
  /// socket path — Herdr's default location is derived from it.
  Future<String> _resolveSocketPath(SSHClient ssh) async {
    var home = '';
    try {
      home = utf8.decode(await HerdrClient.run(ssh, r'printf %s "$HOME"')).trim();
    } catch (_) {}
    if (home.isEmpty) home = '/home/${activeMachine?.user ?? ''}';
    return '$home/${activeMachine?.socketSuffix ?? _defaultSocketSuffix}';
  }

  /// Herdr emits status changes only through `pane.agent_status_changed`,
  /// which is a per-pane subscription requiring a pane_id — so there is no
  /// event to subscribe to for "any agent changed state". Measured: an agent
  /// can run for a minute without producing a single event on the global
  /// subscriptions. Without this poll the list simply never stops saying
  /// "working".
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => refreshNow());
  }

  /// One refresh. Android suspends timers and tears down sockets while the
  /// app is backgrounded, so a failure here usually means the connection did
  /// not survive — swallowing it leaves the UI asserting whatever it last saw,
  /// which is how a finished agent keeps spinning.
  Future<void> refreshNow() async {
    // A tick already in flight when the download started must not reconnect
    // underneath it either.
    if (updating) return;
    if (conn == ConnState.failed) {
      await reconnect();
      return;
    }
    if (conn != ConnState.connected) return;
    try {
      final snap = await _rpc?.snapshot();
      if (snap == null) return;
      _pollFailures = 0;
      final before = selectedPane?.agentSession?.value;
      final changed = _statusesDiffer(_host, snap);
      host = snap;
      if (changed) notifyListeners();
      if (selectedPane?.agentSession?.value != before) {
        await _bindSelectedPane();
      }
      unawaited(_refreshBlockedPrompts());
      unawaited(_refreshPreviews());
      if (_chatVisible && !_rebinding) {
        if (!_tailAlive) {
          _rebinding = true;
          unawaited(_bindSelectedPane(silent: true)
              .whenComplete(() => _rebinding = false));
        } else if (DateTime.now().difference(_lastBehindCheck) >
            const Duration(seconds: 15)) {
          unawaited(_checkBehind());
        }
      }
    } catch (_) {
      _pollFailures++;
      // Two in a row is not a blip; the session is gone.
      if (_pollFailures >= 2) {
        _pollFailures = 0;
        error = 'Connection lost while away.';
        await reconnect();
      }
    }
  }

  /// Fetch the tail of every agent's transcript in a single exec.
  ///
  /// One channel for all panes rather than one each: sshd allows ten sessions
  /// and a handful of agents would eat them. Only panes whose state moved are
  /// re-read, so a quiet host costs nothing.
  Future<void> _refreshPreviews() async {
    final ssh = _ssh;
    if (ssh == null || _previewsInFlight) return;
    // Herdr's state counter says an agent moved, but a scrape can race the
    // write it was triggered by — and then the counter never moves again, so
    // the row keeps a reply that is one turn out of date for as long as the
    // agent stays quiet. The transcript's size settles it: cheap to ask for,
    // and it changes exactly when there is something new to read.
    final sizes = await _transcriptSizes(ssh);
    final panes = host.agentPanes.where((p) {
      final size = sizes[p.paneId];
      if (size != null) return _previewSize[p.paneId] != size;
      return (_previewSeq[p.paneId] ?? -1) != p.stateSeq;
    }).toList();
    if (panes.isEmpty) return;
    // A busy agent changes state constantly; refetching on every poll would
    // pull and parse a hundred KB every three seconds.
    final now = DateTime.now();
    // A working agent writes every few seconds and its row is meant to track
    // that; a quiet one has nothing new to say for minutes at a time.
    final anyWorking = panes.any((p) => p.isWorking);
    final wait = anyWorking
        ? const Duration(seconds: 6)
        : const Duration(seconds: 20);
    if (now.difference(_lastPreviewFetch) < wait) return;
    _lastPreviewFetch = now;
    _previewsInFlight = true;
    try {
      final script = StringBuffer();
      final paths = <String, String>{};
      final codex = <(String, String)>[];
      final opencode = <(String, String)>[];
      for (final pane in panes) {
        // Git state is per working directory, and worth having even for a
        // pane whose transcript we cannot find.
        final cwd = pane.cwd;
        if (cwd != null && cwd.isNotEmpty) {
          script.writeln('cd ${_shellQuote(cwd)} 2>/dev/null && '
              'b=\$(git rev-parse --abbrev-ref HEAD 2>/dev/null) && '
              'n=\$(git status --porcelain 2>/dev/null | wc -l | tr -d " ") && '
              'echo "@@@"${_shellQuote(pane.paneId)}" \$b \$n"');
        }
        final session = pane.agentSession;
        if (session == null || session.value.isEmpty) {
          // Codex tells Herdr nothing about its session, so the row would
          // have no last line at all. Its rollout is found the same way the
          // chat finds it: by the directory it was started in.
          final cwd = pane.cwd;
          if (pane.agent == 'codex' && cwd != null && cwd.isNotEmpty) {
            codex.add((pane.paneId, cwd));
          }
          continue;
        }
        if (pane.agent == 'opencode' && _isOpencodeId(session.value)) {
          opencode.add((pane.paneId, session.value));
          continue;
        }
        if (session.isPath) {
          paths[pane.paneId] = session.value;
        } else {
          final id = session.value;
          if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id)) continue;
          script.writeln(
              'f=\$(find ~/.claude/projects ~/.codex/sessions -maxdepth 3 '
              '-name "*$id*.jsonl" 2>/dev/null | head -1); '
              '[ -n "\$f" ] && printf "%s %s\\n" ${_shellQuote(pane.paneId)} "\$f" '
              '>> "\$SHEPHERD_LIST"');
        }
      }
      if (codex.isNotEmpty) {
        final args = codex
            .map((p) => '${_shellQuote(p.$1)} ${_shellQuote(p.$2)}')
            .join(' ');
        // The redirection goes on the command line. A heredoc ends only at a
        // line holding the marker alone.
        script.writeln('python3 - $args >> "\$SHEPHERD_LIST" '
            '<<\'SHEPHERD_CODEX\'\n'
            '$_codexPython\n'
            'SHEPHERD_CODEX');
      }
      if (opencode.isNotEmpty) {
        script.writeln(_opencodeSync(opencode, list: '"\$SHEPHERD_LIST"'));
      }
      if (script.isEmpty) return;
      // No timeout here means a stalled channel leaves _previewsInFlight set
      // and previews never load again for the life of the connection.
      final out = utf8.decode(
        await HerdrClient.run(ssh, _previewScript(script.toString(), paths))
            .timeout(const Duration(seconds: 25)),
        allowMalformed: true,
      );
      var changed = false;
      for (final line in out.split('\n')) {
        final titled = _rememberTitle(line);
        if (titled != null) {
          if (titled) changed = true;
          continue;
        }
        if (!line.startsWith('@@@')) continue;
        final parts = line.substring(3).trim().split(RegExp(r'\s+'));
        if (parts.length < 3) continue;
        final state = GitState(
          branch: parts[1],
          dirty: int.tryParse(parts[2]) ?? 0,
        );
        if (_git[parts[0]] != state) {
          _git[parts[0]] = state;
          changed = true;
        }
      }
      for (final pane in panes) {
        final text = (pane.isWorking ? _extractPreview(out, pane, live: true)
                : null) ??
            _extractPreview(out, pane);
        if (text == null) continue; // Retry next time rather than give up.
        if (_previews[pane.paneId] != text) {
          _previews[pane.paneId] = text;
          changed = true;
        }
        _previewSeq[pane.paneId] = pane.stateSeq;
        final size = sizes[pane.paneId];
        if (size != null) _previewSize[pane.paneId] = size;
      }
      if (changed) notifyListeners();
    } catch (_) {
    } finally {
      _previewsInFlight = false;
    }
  }

  /// Transcript sizes for every agent pane, in one exec.
  ///
  /// Returns an empty map when the check is skipped or fails, which leaves
  /// the caller on Herdr's state counter.
  Future<Map<String, int>> _transcriptSizes(SSHClient ssh) async {
    final now = DateTime.now();
    final anyWorking = host.agentPanes.any((p) => p.isWorking);
    if (now.difference(_lastSizeCheck) <
        (anyWorking ? const Duration(seconds: 4) : const Duration(seconds: 10))) {
      return const {};
    }
    _lastSizeCheck = now;
    final script = StringBuffer();
    for (final pane in host.agentPanes) {
      final session = pane.agentSession;
      if (session == null || session.value.isEmpty || !session.isPath) continue;
      script.writeln('printf "%s %s\\n" ${_shellQuote(pane.paneId)} '
          '"\$(wc -c < ${_shellQuote(session.value)} 2>/dev/null || echo -1)"');
    }
    if (script.isEmpty) return const {};
    try {
      final out = utf8.decode(
        await HerdrClient.run(ssh, script.toString()).timeout(const Duration(seconds: 15)),
        allowMalformed: true,
      );
      final sizes = <String, int>{};
      for (final line in out.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length != 2) continue;
        final size = int.tryParse(parts[1]);
        if (size != null && size >= 0) sizes[parts[0]] = size;
      }
      return sizes;
    } catch (_) {
      return const {};
    }
  }


  /// One exec that returns the previews themselves rather than the megabytes
  /// they are derived from.
  ///
  /// Bookkeeping records and tool results can put 60KB or more between the
  /// last assistant message and the end of a Claude transcript, so the host
  /// walks back until it finds one and sends back a line.
  @visibleForTesting
  static String previewScript(String gitAndFinds, Map<String, String> paths) =>
      _previewScript(gitAndFinds, paths);

  static String _previewScript(String gitAndFinds, Map<String, String> paths) {
    final list = StringBuffer();
    paths.forEach((paneId, path) {
      list.writeln('printf "%s %s\\n" ${_shellQuote(paneId)} '
          '${_shellQuote(path)} >> "\$SHEPHERD_LIST"');
    });
    // The list goes in as an argument: the heredoc already occupies stdin, and
    // a second stdin redirection leaves it to the shell which one python
    // reads.
    return 'SHEPHERD_LIST=\$(mktemp); '
        '$gitAndFinds'
        '$list'
        'python3 - "\$SHEPHERD_LIST" <<\'SHEPHERD_PREVIEW\'\n'
        '$_previewPython\n'
        'SHEPHERD_PREVIEW\n'
        'rm -f "\$SHEPHERD_LIST"';
  }

  static const _previewPython = r'''import json, os, sys
def texts(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for block in content:
            if isinstance(block, dict) and block.get('type') == 'text':
                out.append(block.get('text', ''))
        return ' '.join(out)
    return ''
def step(content):
    if not isinstance(content, list):
        return None
    for block in reversed(content):
        if not isinstance(block, dict):
            continue
        kind = block.get('type')
        if kind == 'thinking':
            return (block.get('thinking') or block.get('text') or '').strip()
        if kind in ('tool_use', 'toolCall'):
            name = block.get('name') or block.get('toolName') or 'tool'
            args = block.get('input') or block.get('arguments')
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except ValueError:
                    args = None
            detail = ''
            if isinstance(args, dict):
                if isinstance(args.get('description'), str):
                    detail = args['description'].strip()
                else:
                    for key in ('file_path', 'path', 'pattern'):
                        if isinstance(args.get(key), str) and args[key].strip():
                            detail = args[key].rsplit('/', 1)[-1]
                            break
                    else:
                        command = args.get('command')
                        if isinstance(command, str):
                            detail = command.strip().splitlines()[0] if command.strip() else ''
            return name + (' - ' + detail if detail else '')
        if kind == 'text':
            return None
    return None
with open(sys.argv[1]) as listing:
    wanted = listing.readlines()
def codex_bits(record):
    # Codex: {type: response_item, payload: {...}} with OpenAI shapes inside.
    if record.get('type') != 'response_item':
        return None
    payload = record.get('payload')
    if not isinstance(payload, dict):
        return None
    kind = payload.get('type')
    if kind == 'message' and payload.get('role') == 'assistant':
        content = payload.get('content')
        parts = []
        if isinstance(content, list):
            parts = [b.get('text', '') for b in content
                     if isinstance(b, dict) and b.get('text')]
        elif isinstance(content, str):
            parts = [content]
        return ('reply', ' '.join(parts).strip())
    if kind in ('custom_tool_call', 'function_call', 'local_shell_call'):
        name = payload.get('name') or 'tool'
        raw = payload.get('input') or payload.get('arguments') or ''
        if not isinstance(raw, str):
            raw = json.dumps(raw)
        import re as _re
        found = _re.search(r'cmd\s*:\s*["\'](.+?)["\']\s*[,}]', raw, _re.S)
        detail = found.group(1).splitlines()[0] if found else ''
        return ('live', name + (' - ' + detail if detail else ''))
    return None


for line in wanted:
    line = line.rstrip('\n')
    if not line:
        continue
    pane, _, path = line.partition(' ')
    reply = live = ''
    try:
        size = os.path.getsize(path)
    except OSError:
        continue
    # Walk back in blocks until an assistant record turns up: Claude appends a
    # run of bookkeeping records and huge tool results after every turn, and
    # the newest reply can sit far behind the end of the file.
    window = 64000
    while window <= 2000000:
        with open(path, 'rb') as handle:
            handle.seek(max(0, size - window))
            chunk = handle.read().decode('utf-8', 'replace')
        for entry in chunk.split('\n'):
            entry = entry.strip()
            # Cheap filter before the JSON parse. Claude and Pi put the role
            # in the record; Codex puts the conversation inside a
            # response_item, whose tool calls mention neither.
            if not entry:
                continue
            if '"assistant"' not in entry and '"response_item"' not in entry:
                continue
            try:
                record = json.loads(entry)
            except ValueError:
                continue
            bits = codex_bits(record)
            if bits is not None:
                if bits[0] == 'reply' and bits[1]:
                    reply, live = bits[1], ''
                elif bits[0] == 'live' and bits[1]:
                    live = bits[1]
                continue
            message = record.get('message')
            if not isinstance(message, dict) or message.get('role') != 'assistant':
                continue
            text = texts(message.get('content')).strip()
            if text:
                reply, live = text, ''
            current = step(message.get('content'))
            if current:
                live = current
        if reply or window >= size:
            break
        window *= 4
    for label, value in (('reply', reply), ('live', live)):
        if not value:
            continue
        one = ' '.join(value.split())[:160]
        print('%%%' + pane + ' ' + label + ' ' + one)''';

  /// Read one pane's line out of the host's output.
  ///
  /// The pane id is a whole field at the start of its own line, so `w1:p1`
  /// never matches inside `w1:p10`.
  @visibleForTesting
  static String? extractPreview(String combined, Pane pane,
          {bool live = false}) =>
      _extractPreview(combined, pane, live: live);

  static String? _extractPreview(String combined, Pane pane, {bool live = false}) {
    final wanted = live ? 'live' : 'reply';
    for (final line in combined.split('\n')) {
      if (!line.startsWith('%%%')) continue;
      final parts = line.substring(3).split(' ');
      if (parts.length < 3) continue;
      if (parts[0] != pane.paneId || parts[1] != wanted) continue;
      final text = parts.sublist(2).join(' ').trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  /// Only repaint when something a human would notice actually moved.
  @visibleForTesting
  static bool statusesDiffer(HostState a, HostState b) => _statusesDiffer(a, b);

  static bool _statusesDiffer(HostState a, HostState b) {
    if (a.agentPanes.length != b.agentPanes.length) return true;
    for (var i = 0; i < a.agentPanes.length; i++) {
      final x = a.agentPanes[i];
      final y = b.agentPanes[i];
      if (x.paneId != y.paneId ||
          x.agentStatus != y.agentStatus ||
          x.sessionName != y.sessionName) {
        return true;
      }
    }
    return false;
  }

  /// Events are a nudge to re-read state, not a delta to apply — Herdr's
  /// per-pane subscriptions need a pane_id, so there is no global agent-status
  /// stream to diff against. Coalesce bursts into one snapshot.
  void _onEvent(Map<String, dynamic> _) {
    _resnapshot?.cancel();
    _resnapshot = Timer(const Duration(milliseconds: 250), () async {
      try {
        final snap = await _rpc?.snapshot();
        if (snap == null) return;
        final previous = selectedPane?.agentSession?.value;
        host = snap;
        notifyListeners();
        if (selectedPane?.agentSession?.value != previous) {
          await _bindSelectedPane();
        }
        await _refreshBlockedPrompts();
      } catch (_) {}
    });
  }

  Future<void> selectPane(String paneId) async {
    touchActivity();
    final samePane = selectedPaneId == paneId && turns.isNotEmpty;
    selectedPaneId = paneId;
    if (samePane) {
      notifyListeners();
      return;
    }
    turns = const [];
    transcriptLoading = true;
    notifyListeners();
    final pane = host.paneById(paneId);
    if (pane != null) {
      try {
        await _rpc?.focusPane(pane);
      } catch (_) {}
    }
    await _bindSelectedPane();
  }

  /// Resolve the pane's transcript and start following it.
  ///
  /// [silent] is for re-binding the pane already on screen — restarting a tail
  /// that died. Clearing the thread and showing "reading transcript" is right
  /// when you have just opened a different agent and wrong when you are
  /// reading this one.
  Future<void> _bindSelectedPane({bool silent = false, int attempt = 0}) async {
    final pane = selectedPane;
    final ssh = _ssh;
    if (pane == null || ssh == null) return;

    final epoch = ++_bindEpoch;
    // Set here rather than only in selectPane, so the launch path and any
    // re-bind are covered too. A silent re-bind keeps what is on screen; with
    // nothing on screen it loads like any other.
    transcriptLoading = !silent || turns.isEmpty;
    transcriptDiagnostic = null;
    _tailSession?.close();
    _tailSession = null;
    _tailAlive = false;
    if (!silent) {
      _boundPath = null;
      _behindAt = null;
    }

    // The cache is not put on screen: replacing it when the fresh window
    // lands would move text under the reader, so the chat shows a spinner
    // until then. The cache seeds the merge below, so nothing older than the
    // window is lost.

    final path = await _resolveTranscriptPath(pane);
    if (epoch != _bindEpoch) return;
    if ((path == null || path.isEmpty) &&
        _lookupFailed &&
        _retryBind(epoch, silent, attempt)) {
      return;
    }
    _adapter = TranscriptAdapter.forAgent(pane.agent);
    if (!silent && turns.isEmpty) notifyListeners();

    if (path == null || path.isEmpty) {
      final session = pane.agentSession;
      transcriptDiagnostic = session == null
          ? 'Herdr reported no session for this pane.'
          : 'No file on this host for ${session.kind} '
              '${session.value.split('/').last}';
      _finishLoading(epoch);
      return;
    }

    final framer = JsonlFramer();
    // A new session's file may be empty, or not written yet: omp creates it
    // on the first message. There is no history to read, only a file to wait
    // for, and the follow waits for it by name.
    if (await _isEmptyFile(ssh, path)) {
      if (epoch != _bindEpoch) return;
      final adapter = TranscriptAdapter.forAgent(pane.agent);
      _adapter = adapter;
      _consumed[path] = 0;
      _publish();
      transcriptLoading = false;
      notifyListeners();
      try {
        await _startFollow(ssh, path, epoch, framer);
      } catch (_) {
        if (_retryBind(epoch, silent, attempt)) return;
      }
      return;
    }
    if (epoch != _bindEpoch) return;

    try {
      // History first, as a one-shot read, so the window can be widened when
      // it holds too few turns: records run tens of KB, so a fixed byte window
      // covers one turn on a busy session and dozens on a quiet one.
      // Every bind re-reads a bounded window rather than resuming from a
      // stored offset, so what is on screen always matches the file.
      var window = _backfillBytes;
      while (true) {
        // Read an exact byte range and report the size it was taken from, in
        // one command. Measuring the size separately leaves a window in which
        // the agent appends, and the follow would then either skip those
        // bytes or replay them.
        final raw = await HerdrClient.run(
          ssh,
          'python3 - ${_shellQuote(path)} $window $_minBackfillTurns '
          '<<\'SHEPHERD_WINDOW\'\n'
          '$_thumbnailPython\n$_windowPython\n'
          'SHEPHERD_WINDOW',
          timeout: const Duration(seconds: 45),
        );
        if (epoch != _bindEpoch) return;
        final newline = raw.indexOf(10);
        if (newline < 0) break;
        // stderr is merged into this stream, so a login-shell warning ahead of
        // the header shifts it. Without a size there is nowhere safe to start
        // following from, so this stops rather than guessing zero.
        final header = utf8.decode(raw.sublist(0, newline), allowMalformed: true);
        final endOffset = header.startsWith('SZ ')
            ? int.tryParse(header.substring(3).trim())
            : null;
        if (endOffset == null) {
          if (_retryBind(epoch, silent, attempt)) return;
          transcriptDiagnostic = 'Could not measure:\n$path\n$header';
          _finishLoading(epoch);
          return;
        }
        final bytes = raw.sublist(newline + 1);
        final history = utf8.decode(bytes, allowMalformed: true);
        _rememberAnchor(path, bytes);
        // Off the UI thread: framing and decoding megabytes of JSON here
        // blocks long enough for Android to show an ANR.
        final parsed = await compute(parseTranscript, {
          'text': history,
          'agent': pane.agent ?? '',
          // Where this window sits in the file, so an image's offset is a
          // place the host can seek to.
          'base': '${endOffset - bytes.length}',
        });
        if (epoch != _bindEpoch) return;
        final historyTurns = turnsFromMaps(parsed);
        final enough = historyTurns.length >= _minBackfillTurns;
        // Compare bytes with bytes: the decoded string is shorter than the
        // read whenever the transcript contains a multi-byte character.
        final exhausted =
            bytes.length < window || window >= _maxBackfillBytes;
        if (enough || exhausted) {
          // The follow stream appends to a fresh adapter seeded with what the
          // isolate produced, so new records extend this history rather than
          // starting a second one.
          final adapter = TranscriptAdapter.forAgent(pane.agent);
          // A silent re-bind reads a window, not the whole file, so it is
          // merged with the thread already on screen rather than replacing
          // it and dropping the older turns.
          adapter.turns.addAll(silent
              ? _mergeHistory(_cachedTurns[path] ?? const [], historyTurns)
              : historyTurns);
          // Without this the first live turn reuses the first history turn's
          // id, which is a loaded gun for anything that keys by it.
          adapter.seed(adapter.turns.length);
          adapter.baseOffset = endOffset;
          _adapter = adapter;
          _publish();
          _cachedTurns[path] = List<Turn>.unmodifiable(adapter.turns);
          _consumed[path] = endOffset;
          _rememberForNextLaunch(path);
          // Loaded, even if there was nothing in it: a brand-new session
          // has no turns, and waiting on a spinner for the first one would
          // look like the load had hung.
          transcriptLoading = false;
          notifyListeners();
          break;
        }
        window *= 4;
      }

      await _startFollow(ssh, path, epoch, framer);
    } catch (e) {
      // Most failures here are the link, not the transcript: every channel
      // busy with the list's own polling, or a read that timed out while the
      // phone was waking up. Retry behind the spinner, and report only once
      // the retries are spent.
      if (_retryBind(epoch, silent, attempt)) return;
      transcriptDiagnostic = 'Could not read:\n$path\n$e';
      _finishLoading(epoch);
    }
  }

  /// Schedule another go at binding the chat after a transient failure.
  /// Returns false once the retries are spent.
  bool _retryBind(int epoch, bool silent, int attempt) {
    const delays = [Duration(seconds: 1), Duration(seconds: 3), Duration(seconds: 6)];
    if (attempt >= delays.length) return false;
    final wanted = selectedPaneId;
    Timer(delays[attempt], () {
      // Somebody opened another chat, or a fresh bind already began.
      if (epoch != _bindEpoch || selectedPaneId != wanted) return;
      unawaited(_bindSelectedPane(silent: silent, attempt: attempt + 1));
    });
    return true;
  }



  /// Keep the session title in a "@@@T pane title" line. Null when the line
  /// is not one; otherwise whether the title changed.
  bool? _rememberTitle(String line) {
    if (!line.startsWith('@@@T ')) return null;
    final rest = line.substring(5);
    final space = rest.indexOf(' ');
    if (space < 0) return false;
    final paneId = rest.substring(0, space);
    final title = rest.substring(space + 1).trim();
    final session = host.panes
        .where((p) => p.paneId == paneId)
        .map((p) => p.agentSession?.value)
        .firstOrNull;
    if (session == null || title.isEmpty) return false;
    if (Pane.sessionTitles[session] == title) return false;
    Pane.sessionTitles[session] = title;
    return true;
  }

  /// The JSONL mirror of an OpenCode session, brought up to date.
  Future<String?> _mirrorOpencode(Pane pane, String id) async {
    final ssh = _ssh;
    if (ssh == null || !_isOpencodeId(id)) return null;
    try {
      final out = await HerdrClient.run(
          ssh, _opencodeSync([(pane.paneId, id)]),
          timeout: const Duration(seconds: 25));
      final lines = utf8.decode(out, allowMalformed: true).trim().split('\n');
      for (final l in lines) {
        _rememberTitle(l);
      }
      final line =
          lines.lastWhere((l) => !l.startsWith('@@@'), orElse: () => '');
      final space = line.indexOf(' ');
      final path = space < 0 ? '' : line.substring(space + 1).trim();
      if (path.isEmpty) {
        transcriptDiagnostic = 'No OpenCode session $id in\n'
            '~/.local/share/opencode/opencode.db';
      }
      return path.isEmpty ? null : path;
    } catch (e) {
      transcriptDiagnostic = 'Could not read the OpenCode database: $e';
      _lookupFailed = true;
      return null;
    }
  }

  /// The newest Codex rollout started in this pane's directory.
  Future<String?> _findCodexRollout(Pane pane) async {
    final ssh = _ssh;
    final cwd = pane.cwd;
    if (ssh == null || cwd == null || cwd.isEmpty) return null;
    try {
      final out = await HerdrClient.run(
        ssh,
        'python3 - ${_shellQuote(pane.paneId)} ${_shellQuote(cwd)} '
        '<<\'SHEPHERD_CODEX\'\n'
        '$_codexPython\n'
        'SHEPHERD_CODEX',
        timeout: const Duration(seconds: 25),
      );
      final line = utf8.decode(out, allowMalformed: true).trim();
      final space = line.indexOf(' ');
      final path = space < 0 ? '' : line.substring(space + 1).trim();
      if (path.isEmpty) {
        transcriptDiagnostic =
            'No Codex rollout found for\n$cwd\nunder ~/.codex/sessions';
      }
      return path.isEmpty ? null : path;
    } catch (e) {
      transcriptDiagnostic = 'Could not look for a Codex rollout: $e';
      _lookupFailed = true;
      return null;
    }
  }

  /// Codex files a session under ~/.codex/sessions/YYYY/MM/DD and names it
  /// after the time and a uuid; the working directory is inside, on the first
  /// line. Newest wins, because a directory can have been worked in twice.
  static const _codexPython = r'''import json, os, sys
# Arguments are pane id and working directory, in pairs.
wanted = {}
for i in range(1, len(sys.argv) - 1, 2):
    wanted[os.path.realpath(sys.argv[i + 1])] = sys.argv[i]
best = {}
root = os.path.expanduser('~/.codex/sessions')
for base, _, names in os.walk(root):
    for name in names:
        if not name.startswith('rollout-') or not name.endswith('.jsonl'):
            continue
        path = os.path.join(base, name)
        try:
            with open(path) as handle:
                first = handle.readline()
            record = json.loads(first)
        except Exception:
            continue
        if record.get('type') != 'session_meta':
            continue
        cwd = (record.get('payload') or {}).get('cwd')
        if not cwd:
            continue
        pane = wanted.get(os.path.realpath(cwd))
        if not pane:
            continue
        stamp = os.path.getmtime(path)
        if pane not in best or stamp > best[pane][0]:
            best[pane] = (stamp, path)
for pane, (_, path) in best.items():
    sys.stdout.write('%s %s\n' % (pane, path))''';

  /// OpenCode keeps a session as rows in SQLite rather than in a file. This
  /// mirrors each finished part into an append-only JSONL file, once, in
  /// Pi's record shape, so everything that reads a transcript reads it
  /// unchanged. `sync PANE SID ...` prints "pane path" per session; `follow
  /// SID` keeps the mirror current until the shell that started it exits.
  static const _opencodePython = r'''import json, os, sqlite3, sys, time

# OpenCode keeps a session as rows in a SQLite database. This copies each
# finished part, once, into an append-only JSONL file in Pi's record shape,
# so the file can be read, tailed and seeked like any other transcript.
DB = os.path.expanduser('~/.local/share/opencode/opencode.db')
HOME = os.path.expanduser('~/.shepherd/opencode')


def connect():
    db = sqlite3.connect('file:%s?mode=ro' % DB, uri=True, timeout=5)
    db.row_factory = sqlite3.Row
    return db


def tables(db):
    return {r[0] for r in db.execute(
        "select name from sqlite_master where type='table'")}


def rows(db, sid):
    """Parts of the session in order, each with its message."""
    have = tables(db)
    if 'part' in have and 'message' in have:
        return db.execute(
            'select m.id mid, m.data mdata, p.id pid, p.data pdata '
            'from part p join message m on m.id = p.message_id '
            'where p.session_id = ? order by m.time_created, m.id, p.id',
            (sid,)).fetchall()
    return []


def finished(message, part):
    kind = part.get('type')
    if message.get('role') == 'user':
        return True
    if kind == 'tool':
        return (part.get('state') or {}).get('status') in ('completed', 'error')
    if kind in ('text', 'reasoning'):
        return bool((part.get('time') or {}).get('end')
                    or (message.get('time') or {}).get('completed'))
    return bool((message.get('time') or {}).get('completed'))


def picture(file):
    """A file part or attachment that is an inline picture, as Pi writes one."""
    url = file.get('url') or ''
    mime = file.get('mime') or ''
    if not mime.startswith('image/') or not url.startswith('data:'):
        return None
    comma = url.find(',')
    return {'type': 'image', 'mimeType': mime, 'data': url[comma + 1:]}


def stamp(ms):
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(ms / 1000)) + \
        '.%03dZ' % (ms % 1000)


def records(message, part):
    role = message.get('role')
    kind = part.get('type')
    when = stamp(((message.get('time') or {}).get('created')) or 0)

    def line(msg):
        return {'type': 'message', 'timestamp': when, 'message': msg}

    if role == 'user':
        if kind == 'text' and not part.get('synthetic'):
            return [line({'role': 'user', 'content': [
                {'type': 'text', 'text': part.get('text') or ''}]})]
        if kind == 'file':
            found = picture(part)
            return [line({'role': 'user', 'content': [found]})] if found else []
        return []
    if kind == 'text':
        return [line({'role': 'assistant', 'content': [
            {'type': 'text', 'text': part.get('text') or ''}]})]
    if kind == 'reasoning':
        return [line({'role': 'assistant', 'content': [
            {'type': 'thinking', 'thinking': part.get('text') or ''}]})]
    if kind == 'tool':
        state = part.get('state') or {}
        args = dict(state.get('input') or {})
        if 'filePath' in args and 'path' not in args:
            args['path'] = args['filePath']
        asked = args.get('questions')
        if isinstance(asked, list) and asked and isinstance(asked[0], dict):
            args.setdefault('description', asked[0].get('question') or '')
        call = part.get('callID') or part.get('id')
        name = part.get('tool') or 'tool'
        error = state.get('status') == 'error'
        content = [{'type': 'text', 'text': str(
            state.get('error') if error else state.get('output') or '')}]
        for attachment in state.get('attachments') or []:
            found = picture(attachment)
            if found:
                content.append(found)
        return [
            line({'role': 'assistant', 'content': [
                {'type': 'toolCall', 'id': call, 'name': name,
                 'arguments': args}]}),
            line({'role': 'toolResult', 'toolCallId': call, 'toolName': name,
                  'isError': error, 'content': content}),
        ]
    return []


def failure(message):
    error = message.get('error')
    if not error or message.get('role') != 'assistant':
        return None
    data = error.get('data') if isinstance(error, dict) else None
    text = (data or {}).get('message') if isinstance(data, dict) else None
    return {'type': 'message', 'timestamp': stamp(
        ((message.get('time') or {}).get('created')) or 0), 'message': {
        'role': 'assistant', 'content': [], 'stopReason': 'error',
        'errorMessage': text or (error.get('name') if isinstance(error, dict)
                                 else str(error))}}


def sync(db, sid):
    """Append what finished since the last pass. Returns the mirror's path."""
    os.makedirs(HOME, mode=0o700, exist_ok=True)
    path = os.path.join(HOME, sid + '.jsonl')
    seen_path = os.path.join(HOME, sid + '.seen')
    try:
        with open(seen_path) as handle:
            seen = set(handle.read().split())
    except OSError:
        seen = set()
    new, lines = [], []
    for row in rows(db, sid):
        message, part = json.loads(row['mdata']), json.loads(row['pdata'])
        if row['pid'] in seen or not finished(message, part):
            continue
        new.append(row['pid'])
        lines.extend(records(message, part))
        broken = failure(message)
        if broken and 'err:' + row['mid'] not in seen:
            new.append('err:' + row['mid'])
            seen.add('err:' + row['mid'])
            lines.append(broken)
    if new:
        # Records first: a pass that dies between the two writes repeats a
        # part rather than losing one.
        with open(path, 'a') as handle:
            for record in lines:
                handle.write(json.dumps(record) + '\n')
        with open(seen_path, 'a') as handle:
            handle.write('\n'.join(new) + '\n')
    elif not os.path.exists(path):
        open(path, 'a').close()
    return path


def main():
    mode, ids = sys.argv[1], [a for a in sys.argv[2:]
                              if a.replace('_', '').isalnum()]
    if not os.path.exists(DB):
        return
    if mode == 'sync':
        # Pairs of pane id and session id. "pane path" goes to the list file
        # when one is named, else to stdout; the session's own title always
        # goes to stdout, as "@@@T pane title".
        args, out = sys.argv[2:], sys.stdout
        if args[:1] == ['--list']:
            out, args = open(args[1], 'a'), args[2:]
        db = connect()
        for pane, sid in zip(args[0::2], args[1::2]):
            if not sid.replace('_', '').isalnum():
                continue
            out.write('%s %s\n' % (pane, sync(db, sid)))
            try:
                row = db.execute('select title from session where id = ?',
                                 (sid,)).fetchone()
            except sqlite3.Error:
                row = None
            if row and row[0]:
                print('@@@T %s %s' % (pane, ' '.join(row[0].split())))
        out.flush()
        return
    # follow: keep the mirror current while the chat is open. The shell that
    # started this dies with the follow, and then this stops too.
    parent = os.getppid()
    ends = time.time() + 6 * 3600
    while os.getppid() == parent and time.time() < ends:
        try:
            db = connect()
            for sid in ids:
                sync(db, sid)
            db.close()
        except sqlite3.Error:
            pass
        time.sleep(1)


main()''';

  /// Mirror OpenCode's sessions and print "pane path" for each, as the list
  /// and the chat expect a transcript path.
  static String _opencodeSync(List<(String, String)> panes, {String? list}) =>
      'python3 - sync ${list == null ? '' : '--list $list '}'
      '${panes.map((p) => '${_shellQuote(p.$1)} ${_shellQuote(p.$2)}').join(' ')} '
      '<<\'SHEPHERD_OPENCODE\'\n'
      '$_opencodePython\n'
      'SHEPHERD_OPENCODE';

  static bool _isOpencodeId(String id) => RegExp(r'^ses_[A-Za-z0-9]+$').hasMatch(id);

  /// Read a window of the transcript with the image payloads taken out.
  ///
  /// A screenshot is 180KB of base64 inside a single record; a dozen of them
  /// fill a two-megabyte window entirely, and the chat renders as "no
  /// transcript yet" on a conversation that is mostly pictures. The host
  /// drops the bytes and stamps each record with where it sits in the file,
  /// so a picture can still be fetched if somebody taps it.
  static const _windowPython = r'''import json, os, sys
path, window, wanted = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
size = os.path.getsize(path)
sys.stdout.write('SZ %d\n' % size)
cap = 64 << 20


def records(start):
    with open(path, 'rb') as handle:
        handle.seek(start)
        data = handle.read()
    offset = start
    out = []
    first = True
    for line in data.split(b'\n'):
        here = offset
        offset += len(line) + 1
        if first:
            first = False
            if start > 0:
                continue
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        out.append((here, record))
    return out


def said(record):
    # What a person typed, in whichever shape the agent writes.
    message = record.get('message')
    if isinstance(message, dict) and message.get('role') == 'user':
        content = message.get('content')
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return ' '.join(
                b.get('text', '') for b in content
                if isinstance(b, dict) and b.get('type') == 'text')
        return ''
    # Codex: the conversation is inside response_item payloads, and the first
    # user messages are the harness handing the model its environment.
    payload = record.get('payload')
    if (record.get('type') == 'response_item' and isinstance(payload, dict)
            and payload.get('type') == 'message'
            and payload.get('role') == 'user'):
        content = payload.get('content')
        text = ''
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = ' '.join(
                b.get('text', '') for b in content
                if isinstance(b, dict) and b.get('text'))
        if text.lstrip().startswith('<'):
            return ''
        return text
    return ''


def conversation(found):
    total = 0
    for _, record in found:
        if said(record).strip():
            total += 1
    return total


# Images are why a window can hold no conversation at all: one screenshot is
# 180KB of base64 inside a single record, and a dozen of them fill a two
# megabyte read. Widen here, where the file is, rather than pulling more of
# it across the network — then drop the payloads and send what is left.
found = records(max(0, size - window))
while conversation(found) < wanted and window < cap and window < size:
    window *= 4
    found = records(max(0, size - window))

# Widening quadruples, so it overshoots: trim back to the last `wanted`
# conversation turns rather than sending everything it had to read to find
# them.
cut = 0
seen = 0
for index in range(len(found) - 1, -1, -1):
    if said(found[index][1]).strip():
        seen += 1
        if seen > wanted:
            cut = index
            break

LIMIT = 4000
THUMBS = 14
pending = []


def shrink(value, depth=0):
    """Cut what the app would clamp anyway.

    A window is mostly tool output — a single `ls -R` or a test log can be
    megabytes — and the reader clamps every block long before it is drawn.
    Sending it in full costs the phone's network and nothing else.
    """
    # Deep enough for a picture a Pi subagent read, eight levels down.
    if depth > 14:
        return value
    if isinstance(value, str):
        return value if len(value) <= LIMIT else value[:LIMIT] + '…'
    if isinstance(value, list):
        return [shrink(v, depth + 1) for v in value]
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if k in ('image_url', 'url') and isinstance(v, str) \
                    and v.startswith('data:'):
                # Codex's pictures ride in a data: URL. Same reasoning as
                # `data` below: say how big, carry nothing.
                head, _, body = v.partition(',')
                out[k] = head + ','
                out['__bytes'] = (len(body) * 3) // 4
                pending.append((out, body))
            elif k == 'encrypted_content' and isinstance(v, str):
                # Codex's reasoning, sealed. Kilobytes of base64 that nothing
                # on the phone can read.
                out[k] = ''
            elif k == 'data' and isinstance(v, str):
                # Say how big the picture is before dropping it: the reader
                # decides whether it is worth fetching over a phone link.
                out['data'] = ''
                out['__bytes'] = (len(v) * 3) // 4
                pending.append((out, v))
            else:
                out[k] = shrink(v, depth + 1)
        return out
    return value


prepared = []
for here, record in found[cut:]:
    record = shrink(record)
    record['__abs'] = here
    prepared.append(record)

# Thumbnail the newest pictures here, where they are already decoded, so the
# phone gets a few kilobytes instead of the whole picture.
for slot, payload in pending[-THUMBS:]:
    small = thumbnail(payload)
    if small:
        slot['__thumb'] = small

for record in prepared:
    sys.stdout.write(json.dumps(record) + '\n')''';

  /// Shrink one picture to something worth sending unasked.
  ///
  /// Pillow if the host has it; `sips` otherwise, which ships with macOS and
  /// needs nothing installed. With neither, pictures still open on tap.
  static const _thumbnailPython = r'''THUMB_MAX = 240


def thumbnail(payload):
    import base64
    try:
        raw = base64.b64decode(payload)
    except Exception:
        return None
    if not raw:
        return None
    try:
        import io
        from PIL import Image
        picture = Image.open(io.BytesIO(raw))
        picture.thumbnail((THUMB_MAX, THUMB_MAX))
        if picture.mode not in ('RGB', 'L'):
            picture = picture.convert('RGB')
        buffer = io.BytesIO()
        picture.save(buffer, 'JPEG', quality=55)
        return base64.b64encode(buffer.getvalue()).decode('ascii')
    except Exception:
        pass
    try:
        import os, shutil, subprocess, tempfile
        folder = tempfile.mkdtemp()
        try:
            source = os.path.join(folder, 'in')
            target = os.path.join(folder, 'out.jpg')
            with open(source, 'wb') as handle:
                handle.write(raw)
            subprocess.run(
                ['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '55',
                 '-Z', str(THUMB_MAX), source, '--out', target],
                capture_output=True, timeout=20)
            if os.path.exists(target):
                with open(target, 'rb') as handle:
                    return base64.b64encode(handle.read()).decode('ascii')
        finally:
            shutil.rmtree(folder, ignore_errors=True)
    except Exception:
        pass
    return None
''';


  /// Fetch one image out of a transcript, by where its record sits in the file.
  ///
  /// Images live inline as base64 and run to tens of megabytes, so they are
  /// never parsed into a turn or held in the cache. The host seeks to the
  /// offset, reads the one line, decodes the picture into a private file, and
  /// the bytes come back over SFTP — as bytes, a third smaller than base64
  /// down the shell channel.
  Future<({String mediaType, Uint8List bytes})?> loadImage(ImageRef ref) async {
    final ssh = _ssh;
    final path = _boundPath;
    if (ssh == null || path == null || ref.offset < 0) return null;
    final cached = _imageCache[ref.key];
    if (cached != null) return cached;
    try {
      final out = await HerdrClient.run(
        ssh,
        'python3 - ${_shellQuote(path)} ${ref.offset} ${ref.index} '
        '<<\'SHEPHERD_IMAGE\'\n'
        '$_recordPython\n$_imagePython\n'
        'SHEPHERD_IMAGE',
        timeout: const Duration(seconds: 45),
      );
      final lines = utf8
          .decode(out, allowMalformed: true)
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.length < 2) return null;
      final staged = lines.last;
      final bytes = await _fetchStaged(ssh, staged);
      if (bytes == null || bytes.isEmpty) return null;
      final loaded = (mediaType: lines[lines.length - 2], bytes: bytes);
      // Keep a few, so a picture you have opened renders in the thread
      // without asking the host again — and no more than a few, because this
      // is exactly the memory the references exist to avoid holding.
      _imageCache[ref.key] = loaded;
      if (_imageCache.length > 6) {
        _imageCache.remove(_imageCache.keys.first);
      }
      notifyListeners();
      return loaded;
    } catch (_) {
      return null;
    }
  }

  /// Read a file the host staged for us, then take it away again.
  Future<Uint8List?> _fetchStaged(SSHClient ssh, String staged) async {
    if (!staged.startsWith('/')) return null;
    try {
      final sftp = await ssh.sftp().timeout(const Duration(seconds: 20));
      final handle = await sftp.open(staged);
      try {
        return await handle.readBytes().timeout(const Duration(seconds: 60));
      } finally {
        await handle.close();
      }
    } catch (_) {
      return null;
    } finally {
      // The staging file is the picture again, in full, sitting in a temp
      // directory. It goes as soon as it has been read, whether or not the
      // read worked.
      unawaited(HerdrClient.run(ssh, 'rm -f ${_shellQuote(staged)}')
          .catchError((_) => Uint8List(0)));
    }
  }

  /// Pictures already fetched, newest few only.
  final Map<String, ({String mediaType, Uint8List bytes})> _imageCache = {};

  ({String mediaType, Uint8List bytes})? loadedImage(ImageRef ref) =>
      _imageCache[ref.key];

  /// Thumbnails, by offset: from the backfill when the host made one while it
  /// was reading the record anyway, and fetched on sight for the pictures that
  /// arrived live after it.
  final Map<String, Uint8List> _thumbs = {};
  final Set<String> _thumbAsked = {};
  final Set<String> _thumbWanted = {};
  Timer? _thumbTimer;

  /// The small picture for [ref], or null while there is none yet.
  ///
  /// Asking for one is a side effect of being shown: an image scrolled into
  /// view is exactly the image worth a few kilobytes.
  Uint8List? thumbFor(ImageRef ref) {
    final have = _thumbs[ref.key];
    if (have != null) return have;
    final inline = ref.thumb;
    if (inline != null && inline.isNotEmpty) {
      try {
        return _thumbs[ref.key] = base64Decode(inline);
      } catch (_) {
        // A mangled thumbnail is a missing thumbnail.
      }
    }
    if (ref.offset < 0 || _thumbAsked.contains(ref.key)) return null;
    _thumbAsked.add(ref.key);
    _thumbWanted.add(ref.key);
    // Batch: a screen of pictures is one call, not one call per picture, and
    // the host pays a process per thumbnail either way.
    _thumbTimer?.cancel();
    _thumbTimer = Timer(const Duration(milliseconds: 400), _fetchThumbs);
    return null;
  }

  /// Goes up each time a thumbnail arrives, so a screen showing pictures
  /// knows to draw them.
  int thumbsArrived = 0;

  Future<void> _fetchThumbs() async {
    final ssh = _ssh;
    final path = _boundPath;
    final wanted = _thumbWanted.take(10).toList();
    if (wanted.isEmpty) return;
    _thumbWanted.removeAll(wanted);
    if (ssh == null || path == null) return;
    try {
      final out = await HerdrClient.run(
        ssh,
        'python3 - ${_shellQuote(path)} ${wanted.join(',')} '
        '<<\'SHEPHERD_THUMBS\'\n'
        '$_thumbnailPython\n$_recordPython\n$_thumbPython\n'
        'SHEPHERD_THUMBS',
        timeout: const Duration(seconds: 60),
      );
      var changed = false;
      for (final line in utf8.decode(out, allowMalformed: true).split('\n')) {
        final space = line.indexOf(' ');
        if (space <= 0) continue;
        final key = line.substring(0, space).trim();
        if (int.tryParse(key.split(':').first) == null) continue;
        try {
          _thumbs[key] = base64Decode(line.substring(space + 1).trim());
          thumbsArrived++;
          changed = true;
        } catch (_) {
          // Nothing to show for that one; the row stays as it was.
        }
      }
      if (changed) notifyListeners();
    } catch (_) {
      // No thumbnail is not an error worth a message: the row still says how
      // big the picture is and still opens it.
    }
    if (_thumbWanted.isNotEmpty) {
      _thumbTimer?.cancel();
      _thumbTimer = Timer(const Duration(milliseconds: 200), _fetchThumbs);
    }
  }

  /// Reading one record out of a transcript, and finding the picture in it.
  static const _recordPython = r'''import json, os, sys


def record_at(path, offset):
    with open(path, 'rb') as handle:
        handle.seek(offset)
        # One record is one line. Read in blocks so a 50MB image does not
        # force reading the rest of the file with it.
        chunks = []
        while True:
            block = handle.read(1 << 22)
            if not block:
                break
            newline = block.find(b'\n')
            if newline >= 0:
                chunks.append(block[:newline])
                break
            chunks.append(block)
    try:
        return json.loads(b''.join(chunks))
    except ValueError:
        return None


# Every image anywhere in the record, in order. A picture a tool returned is
# nested inside its result — and a subagent's result nests it again — while
# one you attached sits at the top level.
def find_all(node, depth=0, out=None):
    if out is None:
        out = []
    if depth > 14:
        return out
    if isinstance(node, list):
        for item in node:
            find_all(item, depth + 1, out)
        return out
    if not isinstance(node, dict):
        return out
    if node.get('type') in ('image', 'input_image'):
        # Codex writes a data: URL where the others write a payload field.
        url = node.get('image_url') or node.get('url')
        if isinstance(url, str) and url.startswith('data:'):
            head, _, body = url.partition(',')
            out.append((head[5:].split(';')[0], body))
            return out
        source = node.get('source')
        if isinstance(source, dict) and source.get('data'):
            out.append((source.get('media_type') or '', source['data']))
            return out
        if node.get('data'):
            out.append((node.get('mimeType') or node.get('mediaType') or '',
                        node['data']))
            return out
    for value in node.values():
        find_all(value, depth + 1, out)
    return out


def find(node, index=0):
    found = find_all(node)
    return found[index] if index < len(found) else None
''';

  static const _imagePython = r'''import base64, tempfile
record = record_at(sys.argv[1], int(sys.argv[2]))
which = int(sys.argv[3]) if len(sys.argv) > 3 else 0
found = find(record, which) if record is not None else None
if found:
    raw = base64.b64decode(found[1])
    folder = os.environ.get('TMPDIR') or '/tmp'
    fd, staged = tempfile.mkstemp(prefix='shepherd-view-', dir=folder)
    os.write(fd, raw)
    os.close(fd)
    os.chmod(staged, 0o600)
    sys.stdout.write(found[0] + '\n')
    sys.stdout.write(staged + '\n')''';

  static const _thumbPython = r'''for token in sys.argv[2].split(','):
    parts = token.split(':')
    try:
        where = int(parts[0])
        which = int(parts[1]) if len(parts) > 1 else 0
    except ValueError:
        continue
    record = record_at(sys.argv[1], where)
    found = find(record, which) if record is not None else None
    if not found:
        continue
    small = thumbnail(found[1])
    if small:
        sys.stdout.write('%s %s\n' % (token, small))''';


  /// Keep what is already on screen, and take the newer window from the
  /// point the two agree on.
  ///
  /// The window always ends at the file's end, so its first turn appears
  /// somewhere in what we already have; everything before that point is
  /// history the window is too small to carry.
  @visibleForTesting
  static List<Turn> mergeHistory(List<Turn> existing, List<Turn> fresh) =>
      _mergeHistory(existing, fresh);

  static List<Turn> _mergeHistory(List<Turn> existing, List<Turn> fresh) {
    if (existing.isEmpty) return fresh;
    if (fresh.isEmpty) return existing;
    final joinText = fresh.first.userText;
    for (var i = existing.length - 1; i >= 0; i--) {
      if (existing[i].userText == joinText) {
        return [...existing.take(i), ...fresh];
      }
    }
    // No overlap: the window is entirely newer than what we hold, or the file
    // was replaced. Keeping both in order is better than dropping either.
    return [...existing, ...fresh];
  }

  /// Empty, or not there yet.
  Future<bool> _isEmptyFile(SSHClient ssh, String path) async {
    try {
      final out = await HerdrClient.run(ssh,
          'if [ -s ${_shellQuote(path)} ]; then echo full; else echo empty; fi');
      return utf8.decode(out).trim().endsWith('empty');
    } catch (_) {
      return false;
    }
  }


  void _finishLoading(int epoch) {
    if (epoch != _bindEpoch || !transcriptLoading) return;
    transcriptLoading = false;
    notifyListeners();
  }

  /// Follow the file from its current end, so nothing already shown arrives
  /// a second time.
  Future<void> _startFollow(
    SSHClient ssh,
    String path,
    int epoch,
    JsonlFramer framer,
  ) async {
    final from = (_consumed[path] ?? 0) + 1;
    // Closing the channel does not reap the remote process, so any earlier
    // follow of this file is killed first.
    // An OpenCode mirror only grows while something copies into it, so the
    // follow brings its own copier; it stops when this shell does.
    final opencode = RegExp(r'/\.shepherd/opencode/(ses_[A-Za-z0-9]+)\.jsonl$')
        .firstMatch(path)?.group(1);
    // By name, not by descriptor: the file may not exist yet.
    final tail = 'tail -c +$from -F ${_shellQuote(path)} 2>/dev/null';
    final command = opencode == null
        ? tail
        : 'python3 - follow $opencode >/dev/null 2>&1 '
            '<<\'SHEPHERD_OPENCODE\' &\n'
            '$_opencodePython\n'
            'SHEPHERD_OPENCODE\n'
            '$tail';
    // The pattern has to match the process as ps sees it — the command after
    // the shell ate the quotes, not the string we sent — and pkill reads it
    // as a regex, so the `+` in the offset has to be escaped or it quantifies
    // the space before it and matches nothing.
    // Match the file, not the offset: a re-bind can start from the same
    // offset.
    final pattern = 'tail -c \\+[0-9]* -F ${_regexEscape(path)}';
    final previous = _tailPattern;
    if (previous != null) {
      unawaited(HerdrClient.run(ssh, 'pkill -f ${_shellQuote(previous)} 2>/dev/null || true')
          .catchError((_) => Uint8List(0)));
    }
    _tailPattern = pattern;
    _boundPath = path;
    final session = await HerdrClient.execute(ssh, command);
    if (epoch != _bindEpoch) {
      session.close();
      return;
    }
    _tailSession = session;
    _tailAlive = true;
    // Decoding each chunk on its own turns a multi-byte character that
    // straddles the boundary into replacement characters — and that text is
    // what gets cached, so the damage is permanent. This decoder carries the
    // partial sequence across.
    final decoder = const Utf8Decoder(allowMalformed: true);
    var carry = <int>[];
    session.stdout.cast<List<int>>().listen((bytes) {
      final adapter = _adapter;
      if (adapter == null || epoch != _bindEpoch) return;
      // Count bytes, not characters: this offset is what lets the next visit
      // ask only for what arrived since.
      _consumed[path] = (_consumed[path] ?? 0) + bytes.length;
      _rememberAnchor(path, bytes);
      var changed = false;
      final buffered = carry.isEmpty ? bytes : [...carry, ...bytes];
      final whole = _completeUtf8(buffered);
      carry = buffered.sublist(whole);
      for (final record in framer.add(decoder.convert(buffered, 0, whole))) {
        if (adapter.addRecord(record)) changed = true;
      }
      if (changed) {
        // Hold no more turns than the isolate path keeps.
        if (adapter.turns.length > _maxLiveTurns) {
          adapter.turns.removeRange(0, adapter.turns.length - _maxLiveTurns);
        }
        _publish();
        _cachedTurns[path] = List<Turn>.unmodifiable(adapter.turns);
        _rememberForNextLaunch(path);
        transcriptLoading = false;
        notifyListeners();
      }
    }, onError: (_) => _tailEnded(epoch), onDone: () => _tailEnded(epoch));
  }

  /// The tail is a long-lived SSH channel, and those die without notice: the
  /// phone changes network, Android freezes the socket while the app is away,
  /// sshd times the session out. The next poll restarts it from the byte
  /// offset already consumed.
  void _tailEnded(int epoch) {
    if (epoch != _bindEpoch) return;
    _tailAlive = false;
  }

  /// Ask the host whether the transcript has grown past what we have read.
  ///
  /// A dead tail says so; a silently dead one does not. A phone's connection
  /// can look established for minutes after it stopped carrying anything,
  /// while the Sessions previews keep updating over freshly opened channels —
  /// so the list moves and the conversation does not. This is the only
  /// reliable cross-check, and it costs one `wc -c`.
  ///
  /// Being behind once means nothing: bytes are in flight constantly while an
  /// agent writes. Being behind twice running, with nothing consumed in
  /// between, means the tail is not delivering.
  Future<void> _checkBehind() async {
    final path = _boundPath;
    final ssh = _ssh;
    if (path == null || ssh == null || _rebinding) return;
    _lastBehindCheck = DateTime.now();
    final size = await _fileSize(ssh, path);
    final consumed = _consumed[path] ?? 0;
    if (size <= consumed) {
      _behindAt = null;
      return;
    }
    if (_behindAt != consumed) {
      _behindAt = consumed;
      return;
    }
    _behindAt = null;
    _rebinding = true;
    try {
      await _bindSelectedPane(silent: true);
    } finally {
      // Left set by a throw, this flag disables both the dead-tail restart
      // and this check for the life of the process.
      _rebinding = false;
    }
  }

  String? _boundPath;
  String? _tailPattern;
  int? _behindAt;
  DateTime _lastBehindCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// Writing on every record would be a file write per tool call, so the save
  /// is coalesced — the cost of losing the last few seconds of it is one
  /// slightly longer read next time.
  void _rememberForNextLaunch(String path) {
    // `turns` carries the optimistic echo of anything just sent; storing it
    // would resurrect that bubble on next launch as a message nobody sent,
    // and again beside the real one when it lands.
    _cache.remember(
        path, _adapter?.turns ?? const [], _consumed[path] ?? 0, _anchors[path]);
    _cacheSave?.cancel();
    _cacheSave = Timer(const Duration(seconds: 5), () => _cache.save());
  }

  static const _anchorBytes = 256;

  void _rememberAnchor(String path, List<int> bytes) {
    if (bytes.isEmpty) return;
    final tail = bytes.length <= _anchorBytes
        ? bytes
        : bytes.sublist(bytes.length - _anchorBytes);
    _anchors[path] = utf8.decode(tail, allowMalformed: true);
  }

  Future<int> _fileSize(SSHClient ssh, String path) async {
    try {
      final out = await ssh
          .run('wc -c < ${_shellQuote(path)} 2>/dev/null')
          .timeout(const Duration(seconds: 15));
      return int.tryParse(utf8.decode(out).trim()) ?? -1;
    } catch (_) {
      return -1;
    }
  }


  /// Set when the last path lookup failed on the wire rather than finding
  /// nothing, which is worth another try rather than an empty chat.
  bool _lookupFailed = false;

  Future<String?> _resolveTranscriptPath(Pane pane) async {
    _lookupFailed = false;
    final session = pane.agentSession;
    // Herdr resolves the session for Pi and Claude and reports none for
    // Codex, whose rollouts are filed by date rather than by anything the
    // pane knows. The file says which directory it was started in, which is
    // the one thing that ties it back to this pane.
    if (session == null || session.value.isEmpty) {
      return pane.agent == 'codex' ? _findCodexRollout(pane) : null;
    }
    if (session.isPath) return session.value;
    if (pane.agent == 'opencode') return _mirrorOpencode(pane, session.value);

    // kind == "id": locate the file rather than reproducing the agent's own
    // cwd-encoding rules, which differ per agent and change over time.
    final ssh = _ssh;
    if (ssh == null) return null;
    final id = session.value;
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id)) return null;
    try {
      final out = await HerdrClient.run(ssh, 
        "find ~/.claude/projects ~/.codex/sessions -maxdepth 3 "
        "-name '*$id*.jsonl' 2>/dev/null | head -1",
      );
      final path = utf8.decode(out).trim();
      return path.isEmpty ? null : path;
    } catch (e) {
      transcriptDiagnostic = 'Search failed on this host: $e';
      _lookupFailed = true;
      return null;
    }
  }

  /// A question an agent is waiting on, and the answers it will accept.
  ///
  /// Agents ask with a numbered menu — "1. Yes / 2. Yes, and don't ask again
  /// / 3. No" — which takes keys, not prose. The choices are read off the
  /// screen so the phone can offer them.
  @visibleForTesting
  static ({String question, List<Choice> choices}) parsePrompt(String raw) {
    // The selection marker differs by agent: Claude draws `❯`, Codex `›`,
    // and OpenCode draws none — its selected option is only a colour.
    final option = RegExp(r'^[\s❯›>▸▶→*•]*(\d)[.)]\s+(.+)$');
    final styles = <String>[];
    final gutter = <bool>[];
    final lines = <String>[];
    final rawLines = raw.split(RegExp(r'\r?\n'));
    final plain = <String>[];
    for (var line in rawLines) {
      // The screen may come with its colours; they are kept only as the
      // style an option's number is drawn in.
      styles.add(RegExp(r'((?:\x1b\[[0-9;]*m)+)[\s❯›>▸▶→*•]*\d[.)]')
              .firstMatch(line)
              ?.group(1) ??
          '');
      line = line.replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '');
      plain.add(line);
      // OpenCode draws its question panel behind a `┃` gutter.
      final inPanel = RegExp(r'^\s*┃').hasMatch(line);
      gutter.add(inPanel);
      if (inPanel) line = line.replaceFirst(RegExp(r'^\s*┃'), '');
      // When the options carry a preview, Claude draws it as a box to their
      // right, on the same lines: "2. Breakdown object   │   subtotal:
      // number,". Everything from the box edge on belongs to the preview.
      // omp draws its menu inside a box; its left border is not the edge of
      // a preview.
      line = line.replaceFirst(RegExp(r'^\s*[│├╭╰]'), '');
      line = line.split(RegExp(r'[│┌└┐┘]')).first;
      // OpenCode's sidebar shares the lines too, past a wide gap — or alone
      // on a line, far to the right.
      line = line.replaceFirst(RegExp(r'(?<=\S) {6,}\S.*$'), '');
      if (RegExp(r'^ {20,}\S').hasMatch(line)) line = '';
      lines.add(line.trimRight());
    }

    // Find the menu first: a run of options numbered from one, each on its
    // own line. Anything numbered that does not continue the run is not part
    // of it — a diff above the menu has line numbers too.
    final choices = <Choice>[];
    var menuStart = -1;
    for (var i = 0; i < lines.length; i++) {
      final match = option.firstMatch(lines[i].trim());
      if (match == null) continue;
      if (int.parse(match.group(1)!) != choices.length + 1) continue;
      if (choices.isEmpty) menuStart = i;
      choices.add(Choice(
        label: _withoutKeyHint(match.group(2)!.trim()),
        selected: RegExp(r'^\s*[❯›>▸▶→]').hasMatch(lines[i]),
      ));
      // Claude writes the explanation under the option, indented. It is the
      // only place that text exists, and it is what tells you what you are
      // agreeing to.
      final detail = <String>[];
      for (var j = i + 1; j < lines.length; j++) {
        final next = lines[j];
        final trimmed = next.trim();
        if (trimmed.isEmpty) break;
        if (option.hasMatch(trimmed)) break;
        // Indented further than the option itself, and words rather than
        // rules: a box edge below the last option is not its description.
        final indent = next.length - next.trimLeft().length;
        if (indent < 4 || _chrome(trimmed)) break;
        // A label too long for its column wraps, and what wraps is usually
        // "(Recommended)". That is part of the option's name, not what the
        // agent had to say about it.
        if (detail.isEmpty && RegExp(r'^\(.*\)$').hasMatch(trimmed)) {
          choices[choices.length - 1] = Choice(
            label: '${choices.last.label} $trimmed',
            selected: choices.last.selected,
          );
          i = j;
          continue;
        }
        detail.add(trimmed);
        i = j;
      }
      if (detail.isNotEmpty) {
        choices[choices.length - 1] = Choice(
          label: choices.last.label,
          detail: detail.join(' '),
          selected: choices.last.selected,
        );
      }
    }

    if (choices.isEmpty) menuStart = _bulletMenu(lines, choices);
    if (choices.isEmpty) {
      final cursor = _cursorMenu(lines);
      if (cursor != null) return cursor;
    }
    if (choices.isEmpty) {
      return _buttonRow(rawLines, plain, lines, gutter) ??
          (question: _liveOutputOnly(lines.join('\n')),
              choices: const <Choice>[]);
    }
    _markSelectedByStyle(choices, lines, styles, option);

    // The question is in the block directly above the menu: everything up to
    // the rule, the agent's last bullet, or the prompt line that closes it
    // off. Within that block the first line that ends in a question mark is
    // the question; Codex follows it with a "Reason: …?" line.
    final block = <String>[];
    for (var i = menuStart - 1; i >= 0 && i >= menuStart - 16; i--) {
      // A panel with a gutter holds its own question.
      if (gutter[menuStart] && !gutter[i]) break;
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty) continue;
      // omp rules its question off from its options inside one box.
      if (block.isEmpty && RegExp(r'^[─━┤╮╯]+$').hasMatch(trimmed)) continue;
      if (_chrome(trimmed) || _endsBlock(trimmed)) break;
      block.insert(0, trimmed);
    }
    final at = block.indexWhere((l) => l.endsWith('?'));
    if (at < 0) return (question: '', choices: choices);
    // A command waiting for approval is the thing being agreed to; it goes
    // with the question rather than being left behind on the desktop.
    final command = block
        .skip(at + 1)
        .where((l) => l.startsWith(r'$ '))
        .join('\n');
    final question =
        command.isEmpty ? block[at] : '${block[at]}\n$command';
    return (question: question, choices: choices);
  }

  /// A menu of unnumbered options, each behind a radio mark: omp's
  /// "❯ ○ Round to cents". Fills [choices] and returns where the menu
  /// starts, or -1. The last menu on screen is the live one; omp leaves the
  /// options of an earlier question drawn above it.
  static int _bulletMenu(List<String> lines, List<Choice> choices) {
    final bullet = RegExp(r'^([\s❯›>]*)[○●◉◯]\s+(.+)$');
    var found = <Choice>[];
    var foundAt = -1;
    var run = <Choice>[];
    var runAt = -1;
    void close() {
      if (run.length >= 2) {
        found = run;
        foundAt = runAt;
      }
      run = <Choice>[];
      runAt = -1;
    }

    for (var i = 0; i < lines.length; i++) {
      final match = bullet.firstMatch(lines[i]);
      if (match != null) {
        if (run.isEmpty) runAt = i;
        run.add(Choice(
          label: match.group(2)!.trim(),
          selected: RegExp(r'[❯›>]').hasMatch(match.group(1)!),
        ));
        continue;
      }
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty) continue;
      // The explanation under an option, indented past its mark.
      if (run.isNotEmpty &&
          !_chrome(trimmed) &&
          lines[i].length - lines[i].trimLeft().length >= 4) {
        final last = run.removeLast();
        run.add(Choice(
          label: last.label,
          detail: last.detail.isEmpty ? trimmed : '${last.detail} $trimmed',
          selected: last.selected,
        ));
        continue;
      }
      close();
    }
    close();
    choices.addAll(found);
    return foundAt;
  }

  /// Options that are plain lines with a cursor beside one of them, as omp
  /// draws its approvals: "❯ Approve" over "  Deny", above an "enter select"
  /// hint. The question is the box title and whatever the box says above.
  static ({String question, List<Choice> choices})? _cursorMenu(
      List<String> lines) {
    final hint = lines.lastIndexWhere(
        (l) => RegExp(r'enter (select|to select|confirm)', caseSensitive: false)
            .hasMatch(l));
    if (hint < 0) return null;
    final marked = RegExp(r'^(\s*)[❯›]\s+(\S.*)$');
    for (var i = hint - 1; i >= 0 && i >= hint - 12; i--) {
      final m = marked.firstMatch(lines[i]);
      if (m == null) continue;
      final column = lines[i].length - m.group(2)!.length;
      bool sibling(String l) =>
          l.trim().isNotEmpty &&
          l.length - l.trimLeft().length == column &&
          !_chrome(l.trim());
      var top = i, bottom = i;
      while (top > 0 && sibling(lines[top - 1])) {
        top--;
      }
      while (bottom + 1 < hint && sibling(lines[bottom + 1])) {
        bottom++;
      }
      if (bottom == top) return null;
      final choices = [
        for (var j = top; j <= bottom; j++)
          Choice(
            label: j == i ? m.group(2)!.trim() : lines[j].trim(),
            selected: j == i,
          )
      ];
      final asked = <String>[];
      for (var j = top - 1; j >= 0 && j >= top - 12; j--) {
        final text = lines[j].trim();
        if (text.isEmpty) continue;
        // The box's title rule: "─ Allow tool: bash ────".
        final title = RegExp(r'^─+\s+(.*?)\s+─+[╮┐]?$').firstMatch(text);
        if (title != null) {
          asked.insert(0, title.group(1)!);
          break;
        }
        if (_chrome(text)) break;
        asked.insert(0, text);
      }
      return (question: asked.join('\n'), choices: choices);
    }
    return null;
  }

  /// A question answered from a row of buttons: OpenCode's permission prompt
  /// ends "Allow once   Allow always   Reject", with a `⇆ select` hint beside
  /// it. The button in a style of its own is the selected one; the lines
  /// above it, in the same panel, say what is being asked.
  static ({String question, List<Choice> choices})? _buttonRow(
      List<String> raw, List<String> plain, List<String> lines,
      List<bool> gutter) {
    for (var i = lines.length - 1; i >= 0; i--) {
      if (!plain[i].contains('⇆')) continue;
      final labels = lines[i].trim().split(RegExp(r' {3,}'));
      if (labels.length < 2 ||
          labels.length > 4 ||
          labels.any((l) => l.isEmpty || l.length > 30)) {
        continue;
      }
      // The style each label is drawn in, read from the escape codes that
      // start it.
      final styles = [
        for (final label in labels)
          RegExp('((?:\x1b\\[[0-9;]*m)+)${RegExp.escape(label)}')
                  .firstMatch(raw[i])
                  ?.group(1) ??
              ''
      ];
      var selected = -1;
      for (var k = 0; k < styles.length; k++) {
        final others = [
          for (var j = 0; j < styles.length; j++)
            if (j != k) styles[j]
        ];
        if (others.every((s) => s == others.first) &&
            styles[k] != others.first) {
          selected = k;
        }
      }
      final asked = <String>[];
      for (var j = i - 1; j >= 0 && j >= i - 12; j--) {
        if (gutter[i] && !gutter[j]) break;
        final text = lines[j].trim().replaceFirst(RegExp(r'^[△←→⚠]\s*'), '');
        if (text.isEmpty) continue;
        asked.insert(0, text);
      }
      return (
        question: asked.join('\n'),
        choices: [
          for (var k = 0; k < labels.length; k++)
            Choice(label: labels[k], selected: k == selected, sideways: true)
        ],
      );
    }
    return null;
  }

  /// With no marker on any option, the selected one is the option line drawn
  /// in a style none of the others share.
  static void _markSelectedByStyle(List<Choice> choices, List<String> lines,
      List<String> styles, RegExp option) {
    if (choices.any((c) => c.selected)) return;
    final optionStyles = <String>[];
    for (var i = 0, n = 0; i < lines.length && n < choices.length; i++) {
      final match = option.firstMatch(lines[i].trim());
      if (match == null || int.parse(match.group(1)!) != n + 1) continue;
      optionStyles.add(styles[i]);
      n++;
    }
    if (optionStyles.length != choices.length || choices.length < 2) return;
    for (var i = 0; i < optionStyles.length; i++) {
      final others = [
        for (var j = 0; j < optionStyles.length; j++)
          if (j != i) optionStyles[j]
      ];
      if (others.every((s) => s == others.first) &&
          optionStyles[i] != others.first) {
        final c = choices[i];
        choices[i] = Choice(label: c.label, detail: c.detail, selected: true);
        return;
      }
    }
  }

  /// Lines that close off the block a question lives in: an agent's own
  /// bullets (`•`, `⏺`, `✻`) and the prompt it echoes what you typed after.
  static bool _endsBlock(String trimmed) =>
      RegExp(r'^[•⏺✻⎿└]').hasMatch(trimmed) ||
      RegExp(r'^[❯›>]\s').hasMatch(trimmed);

  /// "Yes, proceed (y)" — the letter is the shortcut on a keyboard. On a
  /// phone it is noise, and it makes a sentence read like a code.
  static String _withoutKeyHint(String label) => label
      .replaceAll(RegExp(r'\s*\((?:esc|shift\+tab|tab|enter|[a-z])\)$'), '')
      .trim();

  /// Lines that are the terminal talking, not the agent.
  static bool _chrome(String trimmed) {
    final letters = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (letters.length < trimmed.length * 0.3) return true;
    if (RegExp(r'ctx:\d|bypass permissions|shift\+tab|tokens\)|^[>❯›]')
        .hasMatch(trimmed)) {
      return true;
    }
    if (RegExp(r'^(Model:|Price:|Effort:)').hasMatch(trimmed)) return true;
    // "Esc to cancel · Tab to amend" and friends.
    if (RegExp(r'^(Esc|Enter|Tab|Press enter) to ').hasMatch(trimmed)) {
      return true;
    }
    return false;
  }

  /// The keys that pick option [choice] (numbered from one) in a menu.
  ///
  /// Moving the cursor from wherever it is to the option and pressing Enter
  /// is what every one of these menus answers to — Claude's permission
  /// prompts, its questions in both layouts, and Codex's approvals. A digit
  /// does not work in all of them: Claude's question with a preview beside
  /// it takes only the arrow keys and Enter.
  @visibleForTesting
  static List<String> menuKeys(
      ({String question, List<Choice> choices})? asked, int choice) {
    final choices = asked?.choices ?? const <Choice>[];
    // Where the cursor is now. It starts on the first option, but somebody
    // at the desktop may have moved it before the phone was looked at.
    final at = choices.indexWhere((c) => c.selected);
    final from = at < 0 ? 0 : at;
    final to = choice - 1;
    final across = choices.isNotEmpty && choices.first.sideways;
    return [
      for (var i = from; i < to; i++) across ? 'right' : 'down',
      for (var i = from; i > to; i--) across ? 'left' : 'up',
      'enter',
    ];
  }

  /// Answer a question by moving to its option and pressing Enter.
  Future<void> answerPrompt(String paneId, int choice) async {
    touchActivity();
    try {
      // One key at a time: OpenCode drops a second arrow that arrives in the
      // same burst, and the cursor stops one short of the answer.
      for (final key in menuKeys(_blockedPrompts[paneId], choice)) {
        await _rpc?.sendKeys(paneId, [key]);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } catch (_) {}
    // The menu closes on the keypress; ask again rather than leaving a stale
    // question on the screen.
    _blockedPrompts.remove(paneId);
    _lastBlockedRead = DateTime.fromMillisecondsSinceEpoch(0);
    notifyListeners();
  }

  /// `agent.read` returns the agent's whole rendered screen, not its in-flight
  /// prose: box rules, the status line, and the composer echoing whatever the
  /// human is typing at the keyboard. Shown raw it reads as a terminal rather
  /// than a chat, so keep only lines that carry actual output.
  static String _liveOutputOnly(String raw) {
    final kept = <String>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // Box drawing and rules: mostly punctuation, no words.
      final letters = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      if (letters.length < trimmed.length * 0.3) continue;
      // The agent's own status line and input affordances.
      if (RegExp(r'ctx:\d|bypass permissions|shift\+tab|tokens\)|^[>❯]')
          .hasMatch(trimmed)) {
        continue;
      }
      if (RegExp(r'^(Model:|Price:|Effort:)').hasMatch(trimmed)) continue;
      kept.add(trimmed);
    }
    // A few lines of context, not a screenful.
    const maxLines = 6;
    final tail = kept.length <= maxLines
        ? kept
        : kept.sublist(kept.length - maxLines);
    return tail.join('\n');
  }

  Future<void> send(String text) async {
    final pane = selectedPane;
    final rpc = _rpc;
    if (pane == null || rpc == null || text.trim().isEmpty) return;
    sending = true;
    touchActivity();
    // Show it now. The agent writes the message to its transcript when it
    // gets to it, which is immediately when idle and not for minutes when it
    // is mid-turn.
    _pending.add(_PendingSend(text.trim(), _adapter?.turns.length ?? 0));
    _publish();
    notifyListeners();
    try {
      await rpc.sendText(pane.paneId, text);
      // A beat before the return key: Codex ignores an Enter that arrives
      // while it is still taking in the pasted text. Claude and Pi do not
      // need it and do not mind it.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await rpc.sendKeys(pane.paneId, const ['enter']);
    } catch (e) {
      error = 'send failed: $e';
      _pending.removeWhere((p) => p.text == text.trim());
      _publish();
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  final List<_PendingSend> _pending = [];

  /// Turns as the thread should see them: what the transcript says, plus
  /// anything sent that has not landed in it yet.
  void _publish() {
    final base = _adapter?.turns ?? const <Turn>[];
    if (_pending.isEmpty) {
      turns = List.unmodifiable(base);
      return;
    }
    // A message is confirmed when the transcript has grown past where it was
    // when we sent, not by matching its text: an agent does not have to
    // record what you typed verbatim. Claude writes an attached image as
    // "[Image #5]…" and a second record for the file.
    final now = DateTime.now();
    _pending.removeWhere((p) =>
        base.length > p.turnsAtSend ||
        base.any((t) => t.userText.trim().contains(p.text)) ||
        now.difference(p.at) > const Duration(minutes: 10));
    turns = List.unmodifiable([
      ...base,
      for (final p in _pending)
        Turn(id: 'pending-${p.at.microsecondsSinceEpoch}',
            userText: p.text,
            pending: true),
    ]);
  }

  /// Open a throwaway session just to prove the credentials and socket work.
  /// Returns a short result line for the editor.
  Future<String> testConnection(
    Machine machine, {
    String? privateKeyPem,
    String? password,
  }) async {
    final hasKey = privateKeyPem != null && privateKeyPem.isNotEmpty;
    final hasPassword = password != null && password.isNotEmpty;
    if (!hasKey && !hasPassword) {
      // Distinguish "we never had a credential" from "the host said no" —
      // otherwise both surface as an opaque auth abort.
      return machine.useKey
          ? 'FAILED · NO KEY YET — GENERATE ONE'
          : 'FAILED · NO PASSWORD SET';
    }
    SSHClient? ssh;
    try {
      final socket = await SSHSocket.connect(machine.host, machine.port,
          timeout: const Duration(seconds: 10));
      ssh = SSHClient(
        socket,
        username: machine.user,
        identities: hasKey ? SSHKeyPair.fromPem(privateKeyPem) : null,
        onPasswordRequest: hasPassword ? () => password : null,
      );
      await ssh.authenticated;
      final path = await _resolveSocketPath(ssh);
      final probe = HerdrClient(ssh, path);
      final pong = await probe.call('ping');
      final version = pong['version'] ?? '?';
      return 'OK · HERDR $version';
    } on SSHAuthFailError {
      return 'FAILED · AUTH REJECTED';
    } catch (e) {
      final text = e.toString();
      if (text.contains('No such file') || text.contains('herdr.sock')) {
        return 'FAILED · NO HERDR SOCKET';
      }
      return 'FAILED · ${text.split('(').first.trim().toUpperCase()}';
    } finally {
      ssh?.close();
    }
  }

  /// Coming back to a dead session should not need a tap. Waking networks
  /// settle slowly, so give it a few tries before admitting defeat.
  bool _reconnecting = false;

  Future<void> reconnect({int attempts = 3}) async {
    final machine = _lastMachine ?? activeMachine;
    if (machine == null) return;
    // Two chains would each call connect(), and connect() begins by
    // disconnecting — so the second tears down the connection the first just
    // built, and whichever finishes last decides what the UI believes.
    if (_reconnecting) return;
    _reconnecting = true;
    try {
    for (var i = 0; i < attempts; i++) {
      await connect(machine,
          privateKeyPem: _lastKey, password: _lastPassword);
      if (conn == ConnState.connected) return;
      if (i < attempts - 1) {
        conn = ConnState.connecting;
        notifyListeners();
        await Future<void>.delayed(Duration(seconds: 2 * (i + 1)));
      }
      }
      conn = ConnState.failed;
      notifyListeners();
    } finally {
      _reconnecting = false;
    }
  }

  /// True while the app is quietly getting a dropped connection back. The
  /// screens keep what they show and say so in a corner, rather than
  /// clearing themselves.
  bool get reconnecting => _reconnecting;

  Future<void> renamePane(String paneId, String label) async {
    try {
      await _rpc?.renamePane(paneId, label.trim().isEmpty ? null : label.trim());
      await refreshNow();
    } catch (_) {}
  }

  Future<void> stopPane(String paneId) async {
    try {
      await _rpc?.sendKeys(paneId, const ['esc']);
    } catch (_) {}
  }

  /// Refresh the question text for every blocked pane.
  ///
  /// Throttled: events arrive in bursts, and each blocked pane costs its own
  /// SSH round trip. The question text does not change faster than a human
  /// reads it.
  Future<void> _refreshBlockedPrompts() async {
    final rpc = _rpc;
    if (rpc == null) return;
    final now = DateTime.now();
    if (now.difference(_lastBlockedRead) < const Duration(seconds: 3)) return;
    _lastBlockedRead = now;
    // Pi and omp may be asking while Herdr says they are working, so their
    // screens are read too; only a menu with its selection hint counts.
    final candidates = _host.panes
        .where((p) =>
            p.agentStatus == 'blocked' ||
            (p.isWorking && const {'pi', 'omp'}.contains(p.agent)))
        .toList();
    _blockedPrompts.removeWhere(
        (id, _) => !candidates.any((p) => p.paneId == id));
    for (final pane in candidates) {
      try {
        // The rendered screen, not the scrollback: a permission menu is drawn
        // over the pane and never becomes output.
        final text = await rpc.readPane(pane.paneId,
            source: 'visible', lines: 30, ansi: true);
        final asked = parsePrompt(text);
        if (pane.isWorking) {
          final asking = asked.choices.isNotEmpty &&
              RegExp(r'Enter to select|↑↓ navigate').hasMatch(text);
          final was = _screenBlocked.contains(pane.paneId);
          if (asking != was) {
            asking
                ? _screenBlocked.add(pane.paneId)
                : _screenBlocked.remove(pane.paneId);
            _hostView = null;
            notifyListeners();
          }
          if (!asking) {
            _blockedPrompts.remove(pane.paneId);
            continue;
          }
        }
        if (asked.question.isEmpty && asked.choices.isEmpty) continue;
        final held = _blockedPrompts[pane.paneId];
        if (held == null ||
            held.question != asked.question ||
            held.choices.toString() != asked.choices.toString()) {
          _blockedPrompts[pane.paneId] = asked;
          notifyListeners();
        }
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    final pane = selectedPane;
    if (pane == null || _rpc == null) return;
    try {
      await _rpc!.sendKeys(pane.paneId, const ['esc']);
    } catch (_) {}
  }

  final _prefs = MachineStore();

  final _cache = TranscriptCache();
  Timer? _cacheSave;

  Future<bool> _registerForPush(SSHClient? ssh) async {
    if (ssh == null || !Push.available) return false;
    try {
      return await Push.register(ssh, await _prefs.deviceId());
    } catch (_) {
      // Push is a convenience; the app works without it.
      return false;
    }
  }

  Future<void> loadPreferences() async {
    // Restore what was read last time before anything else: opening a chat
    // then has something to show while the delta is fetched.
    await _cache.load();
    _cache.entries.forEach((path, entry) {
      _cachedTurns[path] = List.unmodifiable(entry.turns);
      _consumed[path] = entry.consumed;
      if (entry.anchor.isNotEmpty) _anchors[path] = entry.anchor;
    });
    showThinking = await _prefs.showThinking();
    showTools = await _prefs.showTools();
    notifyMode = await _prefs.notifyMode();
    quietMinutes = await _prefs.quietMinutes();
    notifyListeners();
    // The service outlives the app, so a previous session may have left it
    // running after the setting changed elsewhere.
    if (notifyMode == 'poll') {
      await Watch.start();
    } else {
      await Watch.stop();
    }
  }

  /// Switch how you are told. Returns having applied whatever actually took:
  /// both modes need a permission the user can refuse, so this reflects the
  /// answer rather than the request.
  Future<void> setNotifyMode(String mode) async {
    if (mode == 'poll') {
      notifyMode = await Watch.start() ? 'poll' : 'off';
      await _dropPushToken();
    } else if (mode == 'push') {
      await Watch.stop();
      notifyMode = await _registerForPush(_ssh) ? 'push' : 'off';
    } else {
      await Watch.stop();
      await _dropPushToken();
      notifyMode = 'off';
    }
    notifyListeners();
    await _prefs.setNotifyMode(notifyMode);
  }

  /// True while a picture is on its way to the host.
  bool uploading = false;

  /// The attachment going up right now: what it is called, and how far along.
  String uploadingName = '';
  double uploadProgress = 0;

  /// Put a file where the agent can read it, and return its path there.
  ///
  /// The path is what gets typed into the message: the agent reads the file
  /// from disk, exactly as it would one pasted into Herdr on the desktop.
  Future<String?> uploadAttachment(File file, String name) async {
    final ssh = _ssh;
    final machine = activeMachine;
    if (ssh == null || machine == null) return null;
    uploading = true;
    uploadingName = name;
    uploadProgress = 0;
    notifyListeners();
    try {
      return await Uploads.send(
        ssh,
        host: machine.host,
        port: machine.port,
        user: machine.user,
        privateKeyPem: _lastKey,
        password: _lastPassword,
        file: file,
        name: name,
        onProgress: (sent, total) {
          if (total <= 0) return;
          final fraction = sent / total;
          // A repaint per chunk is a repaint per 64KB; the eye cannot use
          // them and the thread has better things to do.
          if (fraction - uploadProgress < 0.02 && fraction < 1) return;
          uploadProgress = fraction;
          notifyListeners();
        },
      );
    } catch (_) {
      return null;
    } finally {
      uploading = false;
      uploadingName = '';
      uploadProgress = 0;
      notifyListeners();
    }
  }

  /// Record that you are using the app, so the host can keep quiet while you
  /// are. Called where the app knows you did something deliberate.
  void touchActivity() {
    final ssh = _ssh;
    if (ssh == null || quietMinutes <= 0) return;
    unawaited(() async {
      await Push.touch(ssh, await _prefs.deviceId());
    }());
  }

  Future<void> setQuietMinutes(int minutes) async {
    quietMinutes = minutes;
    notifyListeners();
    await _prefs.setQuietMinutes(minutes);
    final ssh = _ssh;
    if (ssh != null) await Push.setQuietMinutes(ssh, minutes);
    // The watcher runs in its own isolate and reads this when it starts.
    await Watch.setQuietMinutes(minutes);
  }

  /// Stop the host pushing to this device. Left behind, the token would keep
  /// delivering notifications the setting says are off.
  Future<void> _dropPushToken() async {
    final ssh = _ssh;
    if (ssh == null || !Push.available) return;
    try {
      await Push.unregister(ssh, await _prefs.deviceId());
    } catch (_) {}
  }

  Future<void> setShowThinking(bool value) async {
    showThinking = value;
    notifyListeners();
    await _prefs.setShowThinking(value);
  }

  Future<void> setShowTools(bool value) async {
    showTools = value;
    notifyListeners();
    await _prefs.setShowTools(value);
  }

  Future<void> disconnect({bool keepScreen = false}) async {
    // Stop the timers, or the poll would reconnect to a machine the user
    // has left.
    _poll?.cancel();
    _poll = null;
    _cacheSave?.cancel();
    _cacheSave = null;
    _connectGeneration++;
    _resnapshot?.cancel();
    _tailSession?.close();
    _tailSession = null;
    await _eventConn?.close();
    _rpc = null;
    _eventConn = null;
    _ssh?.close();
    _ssh = null;
    conn = ConnState.idle;
    // A reconnect keeps what is on screen, so coming back to the app does not
    // blank the list and the open chat while the connection is re-made.
    if (!keepScreen) {
      host = const HostState();
      turns = const [];
    }
    notifyListeners();
  }

  @override
  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _cacheSave?.cancel();
    _resnapshot?.cancel();
    _tailSession?.close();
    _ssh?.close();
    super.dispose();
  }

  bool _disposed = false;

  /// Every path here is asynchronous, and any of them can land after the
  /// screen that owned this went away.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }
}

/// Length of the longest prefix of [bytes] that ends on a character boundary.
@visibleForTesting
int completeUtf8(List<int> bytes) => _completeUtf8(bytes);

int _completeUtf8(List<int> bytes) {
  var end = bytes.length;
  // A UTF-8 sequence is at most four bytes, so look back at most three.
  for (var back = 1; back <= 3 && back <= bytes.length; back++) {
    final byte = bytes[bytes.length - back];
    if (byte < 0x80) break;
    if (byte >= 0xC0) {
      final needed = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : 2);
      if (back < needed) end = bytes.length - back;
      break;
    }
  }
  return end;
}

String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Enough escaping for `pkill -f`, whose pattern is an extended regex.
String _regexEscape(String s) =>
    s.replaceAllMapped(RegExp(r'[.\\+*?\[\]^$(){}|]'), (m) => '\\${m[0]}');

/// Branch and uncommitted-file count for an agent's working directory.
class GitState {
  final String branch;
  final int dirty;

  const GitState({required this.branch, required this.dirty});

  bool get isDirty => dirty > 0;

  @override
  bool operator ==(Object other) =>
      other is GitState && other.branch == branch && other.dirty == dirty;

  @override
  int get hashCode => Object.hash(branch, dirty);
}

class _PendingSend {
  final String text;

  /// How many turns the transcript held when this was sent. One more means
  /// the agent has written it down, whatever it chose to call it.
  final int turnsAtSend;
  final DateTime at = DateTime.now();

  _PendingSend(this.text, this.turnsAtSend);
}
