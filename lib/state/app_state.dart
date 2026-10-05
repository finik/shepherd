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

  /// A box to tick, when the question takes several answers: whether it is
  /// ticked now. Null for an option that is simply picked.
  final bool? checked;

  const Choice({
    required this.label,
    this.detail = '',
    this.selected = false,
    this.sideways = false,
    this.checked,
  });

  /// "Type something": a tickable answer that is written rather than chosen.
  bool get typed => RegExp(r'^Type something\.?$').hasMatch(label);

  @override
  bool operator ==(Object other) =>
      other is Choice &&
      other.label == label &&
      other.detail == detail &&
      other.checked == checked;

  @override
  int get hashCode => Object.hash(label, detail, checked);

  @override
  String toString() =>
      '${selected ? '> ' : ''}${detail.isEmpty ? label : '$label — $detail'}';
}

/// How much transcript tail to pull on a pane switch.
const _backfillBytes = 512 * 1024;

/// Widen the history window until it holds at least this many turns. One
/// record can be tens of KB, so a fixed window covers wildly different
/// amounts of conversation depending on how the agent has been working.
const _minBackfillTurns = 5;

/// Ceiling on that widening; past this the wire cost is not worth it.
const _maxBackfillBytes = 2 * 1024 * 1024;

/// How much conversation the phone holds: the last turns, and within a long
/// turn its last thinking and tool steps. Older history stays on the host.
const _maxLiveTurns = 10;
const _maxStepsPerTurn = 60;

/// [turns] cut to what the phone holds.
List<Turn> _trimHistory(List<Turn> turns) {
  final kept =
      turns.length <= _maxLiveTurns ? turns : turns.sublist(turns.length - _maxLiveTurns);
  for (final turn in kept) {
    turn.trimSteps(_maxStepsPerTurn);
  }
  return kept;
}

/// Where Herdr's default session socket lives, relative to the login home.
const _defaultSocketSuffix = '.config/herdr/herdr.sock';

class AppState extends ChangeNotifier {
  ConnState conn = ConnState.idle;
  String? error;
  HostState host = const HostState();
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

  /// Where in each transcript the history on screen begins, and how many
  /// turns were fetched from before that on request.
  final Map<String, int> _windowStart = {};
  final Map<String, int> _olderTurns = {};

  /// How full the open agent's context is, as of its latest model call.
  ContextUsage? get contextUsage => _usage;
  ContextUsage? _usage;

  /// The model's context window for [contextUsage]: written by the agent,
  /// listed with its models, or — for a Claude model no catalog lists —
  /// assumed, which [contextWindowAssumed] says.
  int? contextWindow;
  bool contextWindowAssumed = false;

  /// Windows already worked out, by agent and model.
  final Map<String, ({int? window, bool assumed})> _windows = {};

  /// The share of the window in use, 0 to 1; null while either is unknown.
  double? get contextFraction {
    final u = _usage, w = contextWindow;
    if (u == null || w == null || w <= 0) return null;
    return (u.used / w).clamp(0.0, 1.0);
  }

  /// What the open session has cost so far, once [refreshCost] has read it.
  SessionCost? get sessionCost => _costs[_boundPath ?? ''];
  final Map<String, SessionCost> _costs = {};
  final Map<String, Future<void>> _costing = {};

  /// Whether a reading of the open session's cost is under way.
  bool get costLoading => _costing.containsKey(_boundPath);

  /// Read the open session's cost on the host, where the whole transcript
  /// is: the phone holds only its last few turns. A reading under half a
  /// minute old stands.
  Future<void> refreshCost() {
    final path = _boundPath, agent = selectedPane?.agent, ssh = _ssh;
    if (path == null || agent == null || ssh == null) return Future.value();
    unawaited(_checkPlans());
    final known = _costs[path];
    if (known != null &&
        DateTime.now().difference(known.at) < const Duration(seconds: 30)) {
      return Future.value();
    }
    return _costing[path] ??= () async {
      notifyListeners();
      try {
        final out = await HerdrClient.run(
          ssh,
          'python3 - ${_shellQuote(path)} ${_shellQuote(agent)} '
          '<<\'SHEPHERD_COST\'\n'
          '$_costPython\n'
          'SHEPHERD_COST',
          timeout: const Duration(seconds: 60),
        );
        final cost = SessionCost.parse(utf8.decode(out, allowMalformed: true));
        if (cost != null) _costs[path] = cost;
      } catch (_) {
        // Unread; the next look asks again.
      } finally {
        _costing.remove(path);
        notifyListeners();
      }
    }();
  }

  /// Whether the host has anything that reads subscriptions: the
  /// herdr-agent-usage plugin or CodexBar. Asked once per connection.
  bool get hasPlans => _hasPlans == true || planList != null;
  bool? _hasPlans;
  bool _checkingPlans = false;

  Future<void> _checkPlans() async {
    final ssh = _ssh;
    if (ssh == null || _hasPlans != null || _checkingPlans) return;
    _checkingPlans = true;
    try {
      final out = await _runPlans(ssh, 'check');
      _hasPlans = out == true;
      notifyListeners();
    } catch (_) {
      // Unknown; asked again next time.
    } finally {
      _checkingPlans = false;
    }
  }

  Future<Object?> _runPlans(SSHClient ssh, [String mode = '']) async {
    final out = await HerdrClient.run(
      ssh,
      'python3 - $mode <<\'SHEPHERD_PLANS\'\n$_plansPython\nSHEPHERD_PLANS',
      timeout: const Duration(seconds: 60),
    );
    final line = utf8
        .decode(out, allowMalformed: true)
        .split('\n')
        .lastWhere((l) => l.startsWith('@@@'), orElse: () => '');
    return line.isEmpty ? null : jsonDecode(line.substring(3));
  }

  /// What is left of each subscription; null when it could not be asked.
  /// A reading under a minute old stands.
  Future<List<PlanUsage>?> plans() {
    final at = _plansAt;
    if (_plans != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 1)) {
      return _plans!;
    }
    _plansAt = DateTime.now();
    return _plans = _fetchPlans().then((found) {
      // A failed ask is not kept; the next look asks again.
      if (found == null) {
        _plans = null;
      } else {
        planList = found;
        notifyListeners();
      }
      return found;
    });
  }

  /// The latest subscriptions read, for drawing without waiting, and the
  /// machine they were read on.
  List<PlanUsage>? planList;
  String? _plansMachine;

  /// The provider each pane was last matched to: while a chat reloads its
  /// model is not known, and the bars should not blink out for it.
  final Map<String, String> _planProvider = {};

  /// Read the subscriptions again if the last reading is a minute old, after
  /// first finding out whether the host can read them at all.
  Future<void> refreshPlans() async {
    if (_hasPlans == null) await _checkPlans();
    if (hasPlans) await plans();
  }

  /// The subscription [pane] is drawing on, as the subscriptions name
  /// providers: told by its model where the agent runs others' models.
  PlanUsage? planFor(Pane? pane) {
    final list = planList;
    if (pane == null || list == null) return null;
    final model = (pane.paneId == selectedPaneId ? _usage?.model : null) ?? '';
    final ids = <String>[
      if (model.contains('claude')) 'claude',
      if (model.startsWith('gpt') || model.contains('codex')) 'codex',
      if (model.contains('grok')) ...['grok', 'xai'],
      if (model.startsWith('muse')) 'muse',
      if (pane.agent case final agent?) agent,
    ];
    if (model.isEmpty) {
      if (_planProvider[pane.paneId] case final known?) ids.insert(0, known);
    }
    for (final id in ids) {
      for (final p in list) {
        if (p.provider == id && p.windows.isNotEmpty) {
          if (model.isNotEmpty) _planProvider[pane.paneId] = id;
          return p;
        }
      }
    }
    return null;
  }

  Future<List<PlanUsage>?>? _plans;
  DateTime? _plansAt;

  Future<List<PlanUsage>?> _fetchPlans() async {
    final ssh = _ssh;
    if (ssh == null) return null;
    try {
      final found = await _runPlans(ssh);
      return found is List ? PlanUsage.fromList(found) : null;
    } catch (_) {
      return null;
    }
  }

  static const _plansPython = r'''import glob, json, os, shutil, subprocess, sys, time
# What is left of each subscription, from whichever readers the host has:
# the herdr-agent-usage plugin's saved snapshots, then CodexBar for any
# provider the plugin has nothing for. Either may be missing; with neither,
# the list is empty. `check` only says whether there is anything to ask.
home = os.path.expanduser('~')


def plugin_dirs():
    state = os.environ.get('XDG_STATE_HOME') or os.path.join(home, '.local/state')
    return [os.path.join(state, 'herdr/plugins/herdr-agent-usage'),
            os.path.join(home, 'Library/Application Support/dev.herdr.herdr-agent-usage'),
            os.path.join(home, '.local/share/herdr-agent-usage')]


def codexbar_path():
    return shutil.which('codexbar', path=os.pathsep.join([
        os.environ.get('PATH', ''), '/opt/homebrew/bin', '/usr/local/bin',
        '/home/linuxbrew/.linuxbrew/bin', os.path.join(home, '.local/bin'),
        '/Applications/CodexBar.app/Contents/Helpers']))


def snapshots():
    for folder in plugin_dirs():
        for path in glob.glob(os.path.join(folder, '*.json')):
            try:
                with open(path) as handle:
                    data = json.load(handle)
            except Exception:
                continue
            if not isinstance(data, dict):
                continue
            snap = data.get('snapshot', data)
            if isinstance(snap, dict) and isinstance(snap.get('windows'), list) \
                    and snap.get('provider'):
                yield snap


if sys.argv[1:] == ['check']:
    print('@@@' + json.dumps(bool(codexbar_path() or any(True for _ in snapshots()))))
    sys.exit()

# The plugin's windows by length; the length is what the phone names them by.
KINDS = {'five_hour': 300, 'weekly': 10080, 'monthly': 43200, 'daily': 1440}


def iso(unix):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(unix)) if unix else None


# Each window by itself: the plugin writes a provider's quota from whichever
# session spoke last, and one session may report the week but not the five
# hours. The newest reading of each window stands.
plans = {}
for snap in snapshots():
    provider = snap['provider']
    at = snap.get('fetched_at_unix') or 0
    plan = plans.setdefault(provider, {'provider': provider, 'plan': '',
                                       'windows': {}, '_at': 0})
    for w in snap['windows']:
        if not isinstance(w, dict) or not isinstance(w.get('used_percent'), (int, float)):
            continue
        minutes = w['duration_seconds'] // 60 if w.get('duration_seconds') \
            else KINDS.get(w.get('kind'))
        key = minutes or w.get('source_label') or w.get('kind')
        if key in plan['windows'] and plan['windows'][key][0] >= at:
            continue
        reset = w.get('resets_at')
        if isinstance(reset, dict):
            reset = reset.get('unix') or reset.get('at')
        plan['windows'][key] = (at, {
            'label': w.get('source_label'), 'usedPercent': w['used_percent'],
            'minutes': minutes,
            'resetsAt': iso(reset) if isinstance(reset, (int, float)) else reset})
        plan['_at'] = max(plan['_at'], at)
for provider in list(plans):
    plan = plans[provider]
    if not plan['windows']:
        del plans[provider]
        continue
    plan['at'] = iso(plan['_at'])

codexbar = codexbar_path()
if codexbar:
    try:
        out = subprocess.run([codexbar, 'usage', '--json-only', '--no-color'],
                             capture_output=True, text=True, timeout=50).stdout
        entries = json.loads(out[out.index('['):])
    except Exception:
        entries = []
    for e in entries:
        provider = e.get('provider') if isinstance(e, dict) else None
        if not provider or provider == 'cli':
            continue
        usage = e.get('usage')
        if provider in plans:
            # The plugin's readings stand; CodexBar knows the plan's name and
            # gives any window the plugin has not seen.
            if isinstance(usage, dict):
                if usage.get('loginMethod'):
                    plans[provider]['plan'] = usage['loginMethod']
                pace = e.get('pace') or {}
                for key in ('primary', 'secondary', 'tertiary'):
                    w = usage.get(key)
                    if isinstance(w, dict) and isinstance(w.get('usedPercent'), (int, float)) \
                            and w.get('windowMinutes') not in plans[provider]['windows']:
                        plans[provider]['windows'][w.get('windowMinutes') or key] = (0, {
                            'label': None, 'usedPercent': w['usedPercent'],
                            'minutes': w.get('windowMinutes'), 'resetsAt': w.get('resetsAt'),
                            'pace': (pace.get(key) or {}).get('summary')})
            continue
        if not isinstance(usage, dict):
            error = e.get('error')
            plans[provider] = {'provider': provider, 'plan': '', 'windows': [],
                               'error': (error or {}).get('message') if isinstance(error, dict) else None}
            continue
        labels = e.get('rateWindowLabels') or {}
        pace = e.get('pace') or {}
        windows = []
        for key in ('primary', 'secondary', 'tertiary'):
            w = usage.get(key)
            if isinstance(w, dict) and isinstance(w.get('usedPercent'), (int, float)):
                windows.append({'label': labels.get(key), 'usedPercent': w['usedPercent'],
                                'minutes': w.get('windowMinutes'), 'resetsAt': w.get('resetsAt'),
                                'pace': (pace.get(key) or {}).get('summary')})
        plans[provider] = {'provider': provider, 'plan': usage.get('loginMethod') or '',
                           'windows': windows, 'at': usage.get('updatedAt')}

for p in plans.values():
    p.pop('_at', None)
    if isinstance(p['windows'], dict):
        # Shortest window first: the five hours, then the week.
        p['windows'] = [w for _, w in sorted(
            p['windows'].values(),
            key=lambda pair: pair[1].get('minutes') or 1 << 30)]
print('@@@' + json.dumps(list(plans.values())))''';

  @visibleForTesting
  static String get plansScript => _plansPython;

  @visibleForTesting
  void setPlansForTest(List<PlanUsage> plans) {
    _hasPlans = true;
    planList = plans;
    _plans = Future.value(plans);
    _plansAt = DateTime.now();
  }

  @visibleForTesting
  void setCostForTest(SessionCost cost) {
    _costs[_boundPath ?? ''] = cost;
    notifyListeners();
  }

  @visibleForTesting
  void setContextForTest(ContextUsage usage, int window) {
    _usage = usage;
    contextWindow = window;
    notifyListeners();
  }

  void _setUsage(ContextUsage? usage, Pane? pane) {
    final sameModel = usage?.model == _usage?.model;
    _usage = usage;
    if (usage == null) {
      contextWindow = null;
      contextWindowAssumed = false;
      notifyListeners();
      return;
    }
    if (usage.window != null) {
      contextWindow = usage.window;
      contextWindowAssumed = false;
      notifyListeners();
      return;
    }
    final agent = pane?.agent ?? '';
    final key = '$agent|${usage.model}';
    final known = _windows[key];
    if (known != null) {
      contextWindow = _claudeFallback(agent, known.window, usage);
      contextWindowAssumed = known.assumed || known.window == null;
      notifyListeners();
      return;
    }
    if (!sameModel) contextWindow = null;
    notifyListeners();
    unawaited(_resolveWindow(agent, usage).then((found) {
      _windows[key] = found;
      if (_usage?.model != usage.model) return;
      contextWindow = _claudeFallback(agent, found.window, _usage!);
      contextWindowAssumed = found.assumed || found.window == null;
      notifyListeners();
    }));
  }

  /// A Claude model no catalog lists: 200K unless the context is already
  /// past it, which only a 1M window allows.
  static int? _claudeFallback(String agent, int? window, ContextUsage usage) =>
      window ??
      (agent == 'claude' ? (usage.used > 200000 ? 1000000 : 200000) : null);

  Future<({int? window, bool assumed})> _resolveWindow(
      String agent, ContextUsage usage) async {
    int? find(List<ModelOption> models, String id) {
      for (final m in models) {
        if (m.context == null) continue;
        if (m.id == id || m.id.endsWith('/$id') || m.label == id) {
          return m.context;
        }
      }
      return null;
    }

    final own = find(await listModels(agent), usage.model);
    if (own != null) return (window: own, assumed: false);
    // Claude lists no windows of its own; Pi and omp keep a catalog of
    // Anthropic's models that does.
    if (agent == 'claude') {
      for (final other in const ['pi', 'omp']) {
        final w = find(await listModels(other), 'anthropic/${usage.model}');
        if (w != null) return (window: w, assumed: false);
      }
      return (window: null, assumed: true);
    }
    return (window: null, assumed: false);
  }

  /// Ask the agent to summarise its conversation to free up context.
  Future<void> compact(Pane pane) => _command(pane, '/compact');

  /// Start the agent on a fresh conversation. The old one stays in its
  /// transcript on the host.
  Future<void> clearContext(Pane pane) => _command(
      pane,
      const {'opencode', 'omp', 'pi'}.contains(pane.agent) ? '/new' : '/clear');

  Future<void> _command(Pane pane, String command) async {
    final rpc = _rpc;
    if (rpc == null) return;
    touchActivity();
    try {
      await rpc.sendText(pane.paneId, command);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await rpc.sendKeys(pane.paneId, const ['enter']);
    } catch (e) {
      error = '$command failed: $e';
      notifyListeners();
    }
  }

  /// Whether the open conversation has history before what is on screen.
  bool get hasOlder => (_windowStart[_boundPath] ?? 0) > 0;

  /// Whether earlier history is being fetched.
  bool loadingOlder = false;

  /// Fetch the turns before what is on screen, from the host, and put them
  /// ahead of it. The phone keeps only the recent end of a conversation;
  /// this is how the rest is read, when somebody scrolls back for it.
  Future<void> loadOlder() async {
    final ssh = _ssh;
    final path = _boundPath;
    final adapter = _adapter;
    final pane = selectedPane;
    final end = _windowStart[path] ?? 0;
    if (ssh == null || path == null || adapter == null || pane == null ||
        loadingOlder || end <= 0) {
      return;
    }
    loadingOlder = true;
    notifyListeners();
    final epoch = _bindEpoch;
    try {
      final raw = await HerdrClient.run(
        ssh,
        'python3 - ${_shellQuote(path)} $_backfillBytes $_minBackfillTurns $end '
        '<<\'SHEPHERD_WINDOW\'\n'
        '$_thumbnailPython\n$_windowPython\n'
        'SHEPHERD_WINDOW',
        timeout: const Duration(seconds: 45),
      );
      if (epoch != _bindEpoch || _boundPath != path) return;
      final text = utf8.decode(raw, allowMalformed: true);
      final start = RegExp(r'^ST (\d+)$', multiLine: true).firstMatch(text);
      final parsed = await compute(parseTranscript, {
        'text': text,
        'agent': pane.agent ?? '',
        'base': '0',
      });
      if (epoch != _bindEpoch || _boundPath != path) return;
      final older = turnsFromMaps(parsed);
      // Ids from a second parse would repeat the first one's.
      final stamp = _olderTurns[path] ?? 0;
      final renamed = [
        for (var i = 0; i < older.length; i++)
          Turn(id: 'o$stamp.$i', userText: older[i].userText)
            ..steps.addAll(older[i].steps)
            ..earlierSteps = older[i].earlierSteps
            ..trimSteps(_maxStepsPerTurn)
      ];
      adapter.turns.insertAll(0, renamed);
      _olderTurns[path] = stamp + renamed.length;
      _windowStart[path] = start == null ? 0 : int.parse(start.group(1)!);
      _publish();
    } catch (_) {
      // Nothing lost: the history is still on the host for the next try.
    } finally {
      loadingOlder = false;
      notifyListeners();
    }
  }

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
      // Another host, or the same one after a while: its agents and what
      // reads its subscriptions may differ, so both are asked again. The
      // last subscriptions read stay on screen meanwhile, unless they were
      // another machine's.
      _models.clear();
      _hasPlans = null;
      _plans = null;
      if (_plansMachine != machine.id) {
        planList = null;
        _planProvider.clear();
      }
      _plansMachine = machine.id;
      _startPolling();
      selectedPaneId ??= host.focusedPaneId;
      conn = ConnState.connected;
      notifyListeners();
      unawaited(_refreshBlockedPrompts());
      unawaited(checkForUpdate());
      if (_chatVisible) unawaited(refreshPlans());
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
      final changed = _statusesDiffer(host, snap);
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
      final muse = <(String, String)>[];
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
          if (cwd != null && cwd.isNotEmpty) {
            if (pane.agent == 'codex') codex.add((pane.paneId, cwd));
            if (pane.agent == 'muse') muse.add((pane.paneId, cwd));
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
      if (muse.isNotEmpty) {
        final args = muse
            .map((p) => '${_shellQuote(p.$1)} ${_shellQuote(p.$2)}')
            .join(' ');
        script.writeln('python3 - $args >> "\$SHEPHERD_LIST" '
            '<<\'SHEPHERD_MUSE\'\n'
            '$_musePython\n'
            'SHEPHERD_MUSE');
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


def muse_bits(record):
    # Muse: an event log; the conversation is runtime.session run events.
    if record.get('payload_type') != 'runtime.session':
        return None
    payload = record.get('payload') or {}
    event = payload.get('event') if isinstance(payload, dict) else None
    if payload.get('kind') != 'run' or not isinstance(event, dict):
        return None
    kind = event.get('kind')
    if kind == 'assistant_message_committed':
        return ('reply', (event.get('text') or '').strip())
    if kind == 'reasoning_summary_committed':
        return ('live', (event.get('text') or '').strip())
    if kind == 'assistant_tool_calls_committed':
        calls = event.get('tool_calls') or []
        if calls and isinstance(calls[-1], dict):
            call = calls[-1]
            try:
                args = json.loads(call.get('args') or '{}')
            except ValueError:
                args = {}
            detail = ''
            if isinstance(args, dict):
                detail = (args.get('description') or args.get('path') or
                          args.get('command') or '')
                detail = str(detail).strip().splitlines()[0] if str(detail).strip() else ''
                if args.get('path') and not args.get('description'):
                    detail = detail.rsplit('/', 1)[-1]
            return ('live', (call.get('name') or 'tool') +
                    (' - ' + detail if detail else ''))
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
            if ('"assistant"' not in entry and '"response_item"' not in entry
                    and '"runtime.session"' not in entry):
                continue
            try:
                record = json.loads(entry)
            except ValueError:
                continue
            bits = codex_bits(record) or muse_bits(record)
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
    if (!silent) _setUsage(null, pane);
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
        // Then where the window begins, which is where reading further back
        // would stop.
        final second = raw.indexOf(10, newline + 1);
        final startLine = second < 0
            ? ''
            : utf8.decode(raw.sublist(newline + 1, second), allowMalformed: true);
        final windowStart = startLine.startsWith('ST ')
            ? int.tryParse(startLine.substring(3).trim())
            : null;
        if (endOffset == null) {
          if (_retryBind(epoch, silent, attempt)) return;
          transcriptDiagnostic = 'Could not measure:\n$path\n$header';
          _finishLoading(epoch);
          return;
        }
        final bytes =
            raw.sublist(windowStart != null ? second + 1 : newline + 1);
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
          adapter.turns.addAll(_trimHistory(silent
              ? _mergeHistory(_cachedTurns[path] ?? const [], historyTurns)
              : historyTurns));
          _windowStart[path] = windowStart ?? 0;
          _olderTurns[path] = 0;
          // Without this the first live turn reuses the first history turn's
          // id, which is a loaded gun for anything that keys by it.
          adapter.seed(adapter.turns.length);
          adapter.usage = usageFromMaps(parsed) ?? _usage;
          _setUsage(adapter.usage, pane);
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

  /// The newest session started in this pane's directory, for an agent that
  /// tells Herdr nothing about its session. [script] is the agent's own
  /// lookup; [what] names what it looks for, for the diagnostic.
  Future<String?> _findByFolder(Pane pane, String script, String what) async {
    final ssh = _ssh;
    final cwd = pane.cwd;
    if (ssh == null || cwd == null || cwd.isEmpty) return null;
    try {
      final out = await HerdrClient.run(
        ssh,
        'python3 - ${_shellQuote(pane.paneId)} ${_shellQuote(cwd)} '
        '<<\'SHEPHERD_FIND\'\n'
        '$script\n'
        'SHEPHERD_FIND',
        timeout: const Duration(seconds: 25),
      );
      final line = utf8.decode(out, allowMalformed: true).trim();
      final space = line.indexOf(' ');
      final path = space < 0 ? '' : line.substring(space + 1).trim();
      if (path.isEmpty) transcriptDiagnostic = 'No $what found for\n$cwd';
      return path.isEmpty ? null : path;
    } catch (e) {
      transcriptDiagnostic = 'Could not look for $what: $e';
      _lookupFailed = true;
      return null;
    }
  }

  /// Muse files a session as `~/.local/share/muse/sessions/YYYY/MM/DD/ID/`
  /// session.jsonl; its metadata, a few lines in, names the folder it was
  /// started in. Subagents keep files of their own below it. Arguments are
  /// pane id and working directory, in pairs; newest wins.
  static const _musePython = r'''import json, os, sys
wanted = {}
for i in range(1, len(sys.argv) - 1, 2):
    wanted[os.path.realpath(sys.argv[i + 1])] = sys.argv[i]
best = {}
root = os.path.expanduser('~/.local/share/muse/sessions')
for base, dirs, names in os.walk(root):
    dirs[:] = [d for d in dirs if d != 'subagent' and not d.startswith('.')]
    if 'session.jsonl' not in names:
        continue
    path = os.path.join(base, 'session.jsonl')
    cwd = None
    try:
        with open(path) as handle:
            for _ in range(20):
                line = handle.readline()
                if not line:
                    break
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                inner = (record.get('payload') or {}).get('record') or {}
                cwd = inner.get('workspace_root') or inner.get('cwd')
                if cwd:
                    break
    except OSError:
        continue
    pane = wanted.get(os.path.realpath(cwd)) if cwd else None
    if not pane:
        continue
    stamp = os.path.getmtime(path)
    if pane not in best or stamp > best[pane][0]:
        best[pane] = (stamp, path)
for pane, (_, path) in best.items():
    sys.stdout.write('%s %s\n' % (pane, path))''';

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

  static const _followPython = r'''import json, os, sys, time
# Follows a transcript from a byte position, as `tail -c +FROM -F` would, but
# sends a line too big for a phone link trimmed: pictures reduced to their
# size, long text cut, and the line's place in the file stamped on it.
# After each batch it reports how far into the file it has read.
path, start = sys.argv[2], max(0, int(sys.argv[3]) - 1)
LIMIT = 16 * 1024
PICTURE = (b'base64', b'data:image', b'mimeType', b'"image"')
# What the phone never reads and Claude Code writes on every record.
UNREAD = {'input_transformations', 'toolUseResult', 'wireToolInputs'}
UNREAD_MARKS = tuple(b'"%s"' % k.encode() for k in UNREAD)
TEXT = 8192
out = sys.stdout.buffer
parent = os.getppid()


def shrink(value, depth=0):
    if depth > 14:
        return value
    if isinstance(value, str):
        return value if len(value) <= TEXT else value[:TEXT] + '…'
    if isinstance(value, list):
        return [shrink(v, depth + 1) for v in value]
    if isinstance(value, dict):
        kept = {}
        for key, item in value.items():
            if key in UNREAD:
                continue
            if key in ('data', 'base64_data') and isinstance(item, str) and len(item) > 256:
                kept[key] = ''
                kept['__bytes'] = (len(item) * 3) // 4
            elif key in ('image_url', 'url') and isinstance(item, str) and item.startswith('data:'):
                head, _, body = item.partition(',')
                kept[key] = head + ','
                kept['__bytes'] = (len(body) * 3) // 4
            elif key == 'encrypted_content' and isinstance(item, str):
                kept[key] = ''
            else:
                kept[key] = shrink(item, depth + 1)
        return kept
    return value


position = start
pending = b''
handle = None
while os.getppid() == parent:
    if handle is None:
        try:
            handle = open(path, 'rb')
            handle.seek(position)
        except OSError:
            time.sleep(0.5)
            continue
    chunk = handle.read(1 << 20)
    if not chunk:
        time.sleep(0.3)
        continue
    pending += chunk
    wrote = False
    while True:
        cut = pending.find(b'\n')
        if cut < 0:
            break
        line, pending = pending[:cut], pending[cut + 1:]
        at = position
        position += len(line) + 1
        # A picture is fetched by where its line sits in the file, which the
        # phone cannot count from a stream that is no longer the file; any
        # line with one is stamped, however small.
        picture = any(mark in line for mark in PICTURE)
        unread = any(mark in line for mark in UNREAD_MARKS)
        if len(line) <= LIMIT and not picture and not unread:
            out.write(line + b'\n')
        else:
            try:
                record = shrink(json.loads(line))
            except ValueError:
                continue
            if isinstance(record, dict):
                record['__abs'] = at
                out.write(json.dumps(record).encode() + b'\n')
        wrote = True
    if wrote:
        out.write(json.dumps({'__at': position}).encode() + b'\n')
        try:
            out.flush()
        except BrokenPipeError:
            break''';

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
        # The call's context size, in Pi's usage shape, on what the agent
        # said: the latest one says how full the context is.
        tokens = message.get('tokens') if role == 'assistant' else None
        if isinstance(tokens, dict) and msg.get('role') == 'assistant':
            cache = tokens.get('cache') or {}
            msg['usage'] = {'input': tokens.get('input') or 0,
                            'cacheRead': cache.get('read') or 0,
                            'cacheWrite': cache.get('write') or 0}
            msg['model'] = message.get('modelID') or ''
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
# Reading back through history: stop where what the phone holds begins.
end = min(int(sys.argv[4]), size) if len(sys.argv) > 4 else size
cap = 64 << 20


def records(start):
    with open(path, 'rb') as handle:
        handle.seek(start)
        data = handle.read(end - start)
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
found = records(max(0, end - window))
while conversation(found) < wanted and window < cap and window < end:
    window *= 4
    found = records(max(0, end - window))

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
# Fields the phone never reads that dwarf the ones it does: Claude Code
# writes its input transformations and a second copy of every tool's output
# into each record — most of a window's bytes, and every byte of it
# decrypted on the phone.
UNREAD = {'input_transformations', 'toolUseResult', 'wireToolInputs'}
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
            if k in UNREAD:
                continue
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
            elif k in ('data', 'base64_data') and isinstance(v, str) and v:
                # Say how big the picture is before dropping it: the reader
                # decides whether it is worth fetching over a phone link.
                out[k] = ''
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

# Pi writes its thinking level once, near the top, and again only when it
# changes: a window that starts later would not know it. Send the one in
# force ahead of the window. Only Pi and omp write it, early, so a file
# without it in its first stretch is not searched.
LEVEL = b'"type":"thinking_level_change"'


def level_before(start):
    step = 4 << 20
    with open(path, 'rb') as handle:
        if LEVEL not in handle.read(64 << 10):
            return None
        hi = start
        while hi > 0:
            lo = max(0, hi - step)
            handle.seek(lo)
            at = handle.read(hi - lo).rfind(LEVEL)
            if at >= 0:
                at += lo
                near_start = max(0, at - 4096)
                handle.seek(near_start)
                near = handle.read(8192)
                rel = at - near_start
                line = near[near.rfind(b'\n', 0, rel) + 1:].split(b'\n', 1)[0]
                try:
                    return json.loads(line)
                except ValueError:
                    return None
            if lo == 0:
                return None
            # Overlap by the mark, in case it straddles two reads.
            hi = lo + len(LEVEL)
    return None


if len(sys.argv) <= 4 and found[cut:] and found[cut][0] > 0:
    level = level_before(found[cut][0])
    if level:
        prepared.insert(0, level)

# The size, then where in the file the first record sent begins: the place a
# read further back stops.
sys.stdout.write('SZ %d\n' % size)
sys.stdout.write('ST %d\n' % (found[cut][0] if found[cut:] else end))
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
    # Muse: {kind: image, media_type, base64_data}.
    if node.get('kind') == 'image' and node.get('base64_data'):
        out.append((node.get('media_type') or '', node['base64_data']))
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
    // A host-side follower rather than `tail`: a picture is a megabyte of
    // base64 on one line, and the phone gets it trimmed to what it shows.
    final tail = 'python3 - shepherd-follow ${_shellQuote(path)} $from '
        '<<\'SHEPHERD_FOLLOW\'\n'
        '$_followPython\n'
        'SHEPHERD_FOLLOW';
    final command = opencode == null
        ? tail
        : 'python3 - follow $opencode >/dev/null 2>&1 '
            '<<\'SHEPHERD_OPENCODE\' &\n'
            '$_opencodePython\n'
            'SHEPHERD_OPENCODE\n'
            '$tail';
    // The pattern has to match the process as ps sees it — the command after
    // the shell ate the quotes, not the string we sent — and pkill reads it
    // as a regex. Match the file, not the offset: a re-bind can start from
    // the same offset.
    final pattern = 'shepherd-follow ${_regexEscape(path)} ';
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
      _rememberAnchor(path, bytes);
      var changed = false;
      final buffered = carry.isEmpty ? bytes : [...carry, ...bytes];
      final whole = _completeUtf8(buffered);
      carry = buffered.sublist(whole);
      for (final record in framer.add(decoder.convert(buffered, 0, whole))) {
        // The follower says how far into the file it has read: what lets
        // the next visit ask only for what arrived since.
        final at = record['__at'];
        if (at is num) {
          _consumed[path] = at.toInt();
          continue;
        }
        if (adapter.addRecord(record)) changed = true;
      }
      if (adapter.usage != _usage) _setUsage(adapter.usage, selectedPane);
      if (changed) {
        // Hold no more turns than the isolate path keeps.
        final hold = _maxLiveTurns + (_olderTurns[path] ?? 0);
        if (adapter.turns.length > hold) {
          adapter.turns.removeRange(0, adapter.turns.length - hold);
        }
        adapter.turns.last.trimSteps(_maxStepsPerTurn);
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
      return switch (pane.agent) {
        'codex' => _findByFolder(pane, _codexPython, 'a Codex rollout'),
        'muse' => _findByFolder(pane, _musePython, 'a muse session'),
        _ => null,
      };
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
    // Muse leaves the dot out: "> 1  Trust and continue". Without one, a
    // numbered line is a menu only when the cursor opens the run — a diff
    // has "1  todo" too.
    final bare = RegExp(r'^([\s❯›>▸▶→*•]*)(\d) {2,}(\S.*)$');
    final styles = <String>[];
    final gutter = <bool>[];
    final lines = <String>[];
    final rawLines = raw.split(RegExp(r'\r?\n'));
    final plain = <String>[];
    // Only OpenCode draws a sidebar, and only it draws the `┃` panel.
    final sidebar = raw.contains('┃');
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
      if (sidebar) {
        line = line.replaceFirst(RegExp(r'(?<=\S) {6,}\S.*$'), '');
        if (RegExp(r'^ {20,}\S').hasMatch(line)) line = '';
      }
      lines.add(line.trimRight());
    }

    // Find the menu first: a run of options numbered from one, each on its
    // own line. Anything numbered that does not continue the run is not part
    // of it — a diff above the menu has line numbers too.
    final choices = <Choice>[];
    var menuStart = -1;
    var bareRun = false;
    for (var i = 0; i < lines.length; i++) {
      var match = option.firstMatch(lines[i].trim());
      if (match == null) {
        final loose = bare.firstMatch(lines[i]);
        final opens = loose != null &&
            choices.isEmpty &&
            loose.group(2) == '1' &&
            RegExp(r'[❯›>]').hasMatch(loose.group(1)!);
        if (loose != null && (opens || (bareRun && choices.isNotEmpty))) {
          match = option.firstMatch('${loose.group(2)}. ${loose.group(3)}');
          if (opens) bareRun = true;
        }
      }
      if (match == null) continue;
      if (int.parse(match.group(1)!) != choices.length + 1) continue;
      if (choices.isEmpty) menuStart = i;
      // Claude asks for several answers with a box before each: "[ ] Apple",
      // "[✔] Cherry".
      var label = _withoutKeyHint(match.group(2)!.trim());
      bool? checked;
      final box = RegExp(r'^\[([ ✔✓xX×])\]\s+').firstMatch(label);
      if (box != null) {
        checked = box.group(1) != ' ';
        label = label.substring(box.end);
      }
      choices.add(Choice(
        label: label,
        selected: RegExp(r'^\s*[❯›>▸▶→]').hasMatch(lines[i]),
        checked: checked,
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
        // Below the boxes, "Next" moves on to the following question; it is a
        // control, not something the last option says.
        if (choices.last.checked != null && trimmed == 'Next') break;
        // A label too long for its column wraps, and what wraps is usually
        // "(Recommended)". That is part of the option's name, not what the
        // agent had to say about it.
        if (detail.isEmpty && RegExp(r'^\(.*\)$').hasMatch(trimmed)) {
          choices[choices.length - 1] = Choice(
            label: '${choices.last.label} $trimmed',
            selected: choices.last.selected,
            checked: choices.last.checked,
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
          checked: choices.last.checked,
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
    _splitColumns(choices);

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
    // Claude ends a set of questions with a review — each question, then
    // what was answered — before "Ready to submit your answers?". The
    // answers are what is being submitted, so they go with it.
    final review = block.indexOf('Review your answers');
    final at = review >= 0
        ? block.lastIndexWhere((l) => l.endsWith('?'))
        : block.indexWhere((l) => l.endsWith('?'));
    if (at < 0) return (question: '', choices: choices);
    if (review >= 0 && at > review) {
      final answers = [
        for (final l in block.sublist(review + 1, at))
          l.replaceFirst(RegExp(r'^[●•]\s*'), '')
      ];
      return (
        question: '${answers.join('\n')}\n${block[at]}',
        choices: choices
      );
    }
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
    final marked = RegExp(r'^(\s*)[❯›→]\s+(\S.*)$');
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

  /// Muse sets each option's explanation beside it, in a column of its own:
  /// "1. Yes (Recommended)  Round the total…". When every option has text
  /// after a gap at the same place, that text is the explanation.
  static void _splitColumns(List<Choice> choices) {
    if (choices.length < 2 || choices.any((c) => c.detail.isNotEmpty)) return;
    final gap = RegExp(r'^(.*?\S) {2,}(\S.*)$');
    final matches = [for (final c in choices) gap.firstMatch(c.label)];
    if (matches.any((m) => m == null)) return;
    final column = {for (final m in matches) m!.start + m.group(0)!.length - m.group(2)!.length};
    if (column.length != 1) return;
    for (var i = 0; i < choices.length; i++) {
      choices[i] = Choice(
        label: matches[i]!.group(1)!.trim(),
        detail: matches[i]!.group(2)!.trim(),
        selected: choices[i].selected,
      );
    }
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

  /// The keys that leave exactly [wanted] ticked — option numbers, counted
  /// from one — in a question that takes several answers, and then move on.
  /// Enter ticks or unticks the box under the cursor, so only the boxes that
  /// differ are visited; "Next" sits just below the last box.
  @visibleForTesting
  static List<String> checkKeys(
      ({String question, List<Choice> choices})? asked, Set<int> wanted) {
    final choices = asked?.choices ?? const <Choice>[];
    final boxes = [
      for (var i = 0; i < choices.length; i++)
        if (choices[i].checked != null) i
    ];
    if (boxes.isEmpty) return const [];
    var at = choices.indexWhere((c) => c.selected);
    if (at < 0) at = boxes.first;
    final keys = <String>[];
    void moveTo(int to) {
      for (; at < to; at++) {
        keys.add('down');
      }
      for (; at > to; at--) {
        keys.add('up');
      }
    }

    for (final i in boxes) {
      // A written answer cannot be given from here.
      if (choices[i].typed) continue;
      if (wanted.contains(i + 1) != choices[i].checked) {
        moveTo(i);
        keys.add('enter');
      }
    }
    moveTo(boxes.last + 1);
    keys.add('enter');
    return keys;
  }

  /// Answer a question by moving to its option and pressing Enter.
  Future<void> answerPrompt(String paneId, int choice) =>
      _answerWith(paneId, menuKeys(_blockedPrompts[paneId], choice));

  /// Answer a question that takes several answers: tick [wanted], then Next.
  Future<void> answerChecks(String paneId, Set<int> wanted) =>
      _answerWith(paneId, checkKeys(_blockedPrompts[paneId], wanted));

  Future<void> _answerWith(String paneId, List<String> keys) async {
    touchActivity();
    try {
      // One key at a time: OpenCode drops a second arrow that arrives in the
      // same burst, and the cursor stops one short of the answer.
      for (final key in keys) {
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
      // A beat before the return key: Codex and muse ignore an Enter that
      // arrives while they are still taking in the pasted text. The others do
      // not need it and do not mind it.
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
    // Only panes the agent itself reports as waiting are read: the screen is
    // where the question is, not where Shepherd learns that there is one.
    final blocked =
        host.panes.where((p) => p.agentStatus == 'blocked').toList();
    _blockedPrompts.removeWhere(
        (id, _) => !blocked.any((p) => p.paneId == id));
    for (final pane in blocked) {
      try {
        // The rendered screen, not the scrollback: a permission menu is drawn
        // over the pane and never becomes output.
        final text = await rpc.readPane(pane.paneId,
            source: 'visible', lines: 30, ansi: true);
        final asked = parsePrompt(text);
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

  /// The flag each agent takes to start on a given model.
  static const modelFlags = <String, String>{
    'claude': '--model',
    'codex': '-m',
    'pi': '--model',
    'omp': '--model',
    'opencode': '-m',
    'muse': '--model',
  };

  /// Each agent's models, asked for once per connection: the list changes
  /// when an agent is updated or logged in again, not while it is in use.
  final Map<String, Future<List<ModelOption>>> _models = {};

  /// The models [harness] offers on this host, from wherever that agent keeps
  /// them: a command it has for listing them, or the catalog it caches.
  Future<List<ModelOption>> listModels(String harness) =>
      _models[harness] ??= _fetchModels(harness).then((found) {
        // An empty answer is more likely a hiccup than an agent with no
        // models; ask again next time.
        if (found.isEmpty) _models.remove(harness);
        return found;
      });

  Future<List<ModelOption>> _fetchModels(String harness) async {
    final ssh = _ssh;
    if (ssh == null || !harnesses.containsKey(harness)) return const [];
    try {
      final out = await HerdrClient.run(
        ssh,
        'python3 - ${_shellQuote(harness)} <<\'SHEPHERD_MODELS\'\n'
        '$_modelsPython\n'
        'SHEPHERD_MODELS',
        timeout: const Duration(seconds: 90),
      );
      return parseModels(utf8.decode(out, allowMalformed: true));
    } catch (_) {
      return const [];
    }
  }

  /// The models in the listing script's output: its last `@@@` line, JSON.
  @visibleForTesting
  static List<ModelOption> parseModels(String output) {
    final line = output
        .split('\n')
        .lastWhere((l) => l.startsWith('@@@'), orElse: () => '');
    if (line.isEmpty) return const [];
    final decoded = jsonDecode(line.substring(3));
    if (decoded is! List) return const [];
    return [
      for (final m in decoded.whereType<Map>())
        if (m['id'] is String)
          ModelOption(
            id: m['id'] as String,
            label: (m['label'] as String?) ?? m['id'] as String,
            detail: (m['detail'] as String?) ?? '',
            context: (m['context'] as num?)?.toInt(),
            efforts: [
              for (final e in (m['efforts'] as List? ?? const []))
                if (e is String) e
            ],
          )
    ];
  }

  static const _costPython = r'''import glob, json, os, sqlite3, sys, time
path, agent = sys.argv[1], sys.argv[2]

# What a session has cost, in dollars at API rates. Where the agent writes
# the cost itself, that is what counts; otherwise tokens are priced from
# LiteLLM's public table, fetched here on the host and kept for a day.
PRICES_URL = ('https://raw.githubusercontent.com/BerriAI/litellm/main/'
              'model_prices_and_context_window.json')
PRICES = os.path.expanduser('~/.shepherd/prices.json')


def load_prices():
    try:
        fresh = time.time() - os.path.getmtime(PRICES) < 86400
    except OSError:
        fresh = False
    if not fresh:
        try:
            try:
                import urllib.request
                with urllib.request.urlopen(PRICES_URL, timeout=10) as reply:
                    data = reply.read()
            except Exception:
                # A Python without certificates cannot open HTTPS; curl can.
                import subprocess
                data = subprocess.run(
                    ['curl', '-fsSL', '--max-time', '15', PRICES_URL],
                    capture_output=True, check=True).stdout
            json.loads(data)
            os.makedirs(os.path.dirname(PRICES), exist_ok=True)
            with open(PRICES + '.tmp', 'wb') as handle:
                handle.write(data)
            os.replace(PRICES + '.tmp', PRICES)
        except Exception:
            pass
    try:
        with open(PRICES) as handle:
            return json.load(handle)
    except Exception:
        return {}


table = None
found_price = {}


def muse_prices():
    """muse lists what each of its models costs, per million tokens; the
    public table has no price for its discounted models."""
    root = os.path.expanduser('~/.local/share/muse/model-catalog')
    for name in os.listdir(root) if os.path.isdir(root) else []:
        try:
            with open(os.path.join(root, name)) as handle:
                rows = json.load(handle).get('rows') or []
        except Exception:
            continue
        for row in rows:
            cost = row.get('cost') or {}
            try:
                found_price[row['model_id']] = {
                    'input_cost_per_token': float(cost['input']) / 1e6,
                    'output_cost_per_token': float(cost['output']) / 1e6,
                    'cache_read_input_token_cost':
                        float(cost.get('cached') or cost['input']) / 1e6,
                }
            except (KeyError, TypeError, ValueError):
                continue


def price(model, provider=''):
    """Per-token prices for a model, matched loosely: the table names it
    with and without a provider, and agents add date or plan suffixes."""
    global table
    if model in found_price:
        return found_price[model]
    if table is None:
        table = load_prices()
    hit = None
    name = model.split('/')[-1]
    while name and hit is None:
        for key in ([provider + '/' + name] if provider else []) + [name]:
            if isinstance(table.get(key), dict) and \
                    'input_cost_per_token' in table[key]:
                hit = table[key]
                break
        if hit is None:
            ends = sorted((k for k in table
                           if k.endswith('/' + name) and isinstance(
                               table[k], dict)
                           and 'input_cost_per_token' in table[k]), key=len)
            if ends:
                hit = table[ends[0]]
        if hit is None:
            # "claude-haiku-4-5-20251001", "muse-spark-1.3-contributor"
            cut = name.rfind('-')
            name = name[:cut] if cut > 0 else ''
    found_price[model] = hit
    return hit


usd_exact = 0.0
usd_estimated = 0.0
unpriced = set()


def charge(model, fresh=0, cache_read=0, cache_write=0, cache_write_1h=0,
           output=0, provider=''):
    global usd_estimated
    if not (fresh or cache_read or cache_write or cache_write_1h or output):
        return
    p = price(model, provider) if model else None
    if not p:
        unpriced.add(model or '?')
        return
    inp = p.get('input_cost_per_token') or 0
    usd_estimated += (
        fresh * inp
        + cache_read * (p.get('cache_read_input_token_cost') or inp)
        + cache_write * (p.get('cache_creation_input_token_cost') or inp)
        + cache_write_1h * inp * 2
        + output * (p.get('output_cost_per_token') or 0))


def lines(file, start=0, marks=()):
    with open(file, 'rb') as handle:
        handle.seek(start)
        for line in handle:
            if all(m in line for m in marks):
                try:
                    yield json.loads(line)
                except ValueError:
                    pass


def last_mark(file, mark):
    """Where the last line holding `mark` begins, or -1."""
    step = 4 << 20
    with open(file, 'rb') as handle:
        hi = os.path.getsize(file)
        while hi > 0:
            lo = max(0, hi - step)
            handle.seek(lo)
            data = handle.read(hi - lo)
            at = data.rfind(mark)
            if at >= 0:
                begin = data.rfind(b'\n', 0, at)
                if begin >= 0 or lo == 0:
                    return lo + begin + 1
                # The line starts in an earlier read.
                hi = lo + at
                while hi > 0:
                    lo = max(0, hi - 65536)
                    handle.seek(lo)
                    chunk = handle.read(hi - lo)
                    nl = chunk.rfind(b'\n')
                    if nl >= 0:
                        return lo + nl + 1
                    hi = lo
                return 0
            if lo == 0:
                return -1
            hi = lo + len(mark)
    return -1


def claude():
    """Claude Code writes the session's cost from time to time; calls after
    the latest one are priced from their tokens. A reply spans several
    records carrying the same message, so each message counts once."""
    global usd_exact
    since = ''
    start = last_mark(path, b'"type":"cost-state"')
    if start >= 0:
        for record in lines(path, start):
            if record.get('type') == 'cost-state':
                usd_exact = float(record.get('totalCostUSD') or 0)
            break
        # Subagents write their own files; their calls after the mark count.
        with open(path, 'rb') as handle:
            handle.seek(max(0, start - 65536))
            before = handle.read(start - max(0, start - 65536))
        for line in reversed(before.split(b'\n')):
            try:
                since = json.loads(line).get('timestamp') or ''
            except ValueError:
                continue
            if since:
                break
    files = [(path, max(start, 0), '')]
    folder = path[:-len('.jsonl')] + '/subagents'
    files += [(f, 0, since) for f in glob.glob(folder + '/*.jsonl')]
    for file, offset, after in files:
        calls = {}
        for record in lines(file, offset, (b'"assistant"', b'"usage"')):
            if record.get('type') != 'assistant':
                continue
            if after and (record.get('timestamp') or '') <= after:
                continue
            message = record.get('message') or {}
            usage = message.get('usage')
            if not isinstance(usage, dict):
                continue
            calls[message.get('id') or id(record)] = (
                message.get('model') or '', usage)
        for model, u in calls.values():
            if model == '<synthetic>':
                continue
            split = u.get('cache_creation') or {}
            hour = split.get('ephemeral_1h_input_tokens') or 0
            charge(model,
                   fresh=u.get('input_tokens') or 0,
                   cache_read=u.get('cache_read_input_tokens') or 0,
                   cache_write=(u.get('cache_creation_input_tokens') or 0)
                   - hour,
                   cache_write_1h=hour,
                   output=u.get('output_tokens') or 0)


def pi():
    """Pi and omp price every reply themselves."""
    global usd_exact
    for record in lines(path, 0, (b'"assistant"', b'"usage"')):
        message = record.get('message') or {}
        if record.get('type') != 'message' or \
                message.get('role') != 'assistant':
            continue
        u = message.get('usage') or {}
        cost = u.get('cost')
        if isinstance(cost, dict) and isinstance(cost.get('total'),
                                                 (int, float)):
            usd_exact += cost['total']
        else:
            charge(message.get('model') or '',
                   fresh=u.get('input') or 0,
                   cache_read=u.get('cacheRead') or 0,
                   cache_write=u.get('cacheWrite') or 0,
                   output=u.get('output') or 0,
                   provider=message.get('provider') or '')


def opencode():
    """OpenCode prices every reply in its database; the transcript is a
    mirror named after the session."""
    global usd_exact
    sid = os.path.basename(path)[:-len('.jsonl')]
    db = sqlite3.connect('file:%s?mode=ro' % os.path.expanduser(
        '~/.local/share/opencode/opencode.db'), uri=True, timeout=5)
    for (data,) in db.execute(
            'select data from message where session_id = ?', (sid,)):
        try:
            message = json.loads(data)
        except ValueError:
            continue
        if message.get('role') == 'assistant':
            usd_exact += float(message.get('cost') or 0)


def codex():
    """Codex keeps a running token count; each rise goes to the model the
    turn was on."""
    model, last = '', None
    for record in lines(path, 0, (b'"type":"t',)):
        payload = record.get('payload') or {}
        if record.get('type') == 'turn_context':
            model = payload.get('model') or model
            continue
        info = payload.get('info')
        if payload.get('type') != 'token_count' or not isinstance(info, dict):
            continue
        total = info.get('total_token_usage')
        if not isinstance(total, dict):
            continue
        keys = ('input_tokens', 'cached_input_tokens', 'output_tokens')
        now = {k: total.get(k) or 0 for k in keys}
        if last is None or any(now[k] < last[k] for k in keys):
            rise = now
        else:
            rise = {k: now[k] - last[k] for k in keys}
        last = now
        charge(model,
               fresh=rise['input_tokens'] - rise['cached_input_tokens'],
               cache_read=rise['cached_input_tokens'],
               output=rise['output_tokens'])


def muse():
    muse_prices()
    for record in lines(path, 0, (b'"model_completed"',)):
        event = ((record.get('payload') or {}).get('event')) or {}
        if event.get('kind') != 'model_completed':
            continue
        u = event.get('usage') or {}
        # The same cached count, under either name.
        cached = max(u.get('cached_tokens') or 0,
                     u.get('cache_read_tokens') or 0)
        charge(event.get('model') or '',
               fresh=max(0, (u.get('input_tokens') or 0) - cached),
               cache_read=cached,
               cache_write=u.get('cache_write_tokens') or 0,
               output=u.get('output_tokens') or 0)


{'claude': claude, 'pi': pi, 'omp': pi, 'opencode': opencode,
 'codex': codex, 'muse': muse}.get(agent, lambda: None)()
print(json.dumps({'usd': usd_exact + usd_estimated,
                  'estimated': usd_estimated > 0,
                  'unpriced': sorted(unpriced)}))''';

  static const _modelsPython = r'''import json, os, re, subprocess, sys
# Prints one JSON list of {id, label, detail, context, efforts} for the agent
# named in argv[1]; efforts are the levels the model can be asked to think at.
CLAUDE_EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
PI_EFFORTS = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']
harness = sys.argv[1]
home = os.path.expanduser('~')
out = []


def shell(command):
    # The agent's own command, found the way its pane's shell finds it.
    try:
        return subprocess.run(
            [os.environ.get('SHELL') or '/bin/sh', '-lic', command],
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=60).stdout
    except Exception:
        return ''


def load(path):
    try:
        with open(os.path.join(home, path)) as handle:
            return json.load(handle)
    except Exception:
        return None


if harness == 'claude':
    for alias, detail in (('opus', 'Latest Opus'), ('sonnet', 'Latest Sonnet'),
                          ('haiku', 'Latest Haiku'), ('fable', 'Latest Fable')):
        out.append({'id': alias, 'label': alias, 'detail': detail,
                    'efforts': [] if alias == 'haiku' else CLAUDE_EFFORTS})
    for option in (load('.claude.json') or {}).get('additionalModelOptionsCache') or []:
        if isinstance(option, dict) and option.get('value'):
            out.append({'id': option['value'], 'label': option.get('label') or option['value'],
                        'detail': option.get('description') or '',
                        'context': 1000000 if '[1m]' in option['value'] else None,
                        'efforts': [] if 'haiku' in option['value'] else CLAUDE_EFFORTS})
elif harness == 'codex':
    for model in (load('.codex/models_cache.json') or {}).get('models') or []:
        if model.get('visibility') == 'list' and model.get('slug'):
            out.append({'id': model['slug'], 'label': model.get('display_name') or model['slug'],
                        'detail': model.get('description') or '',
                        'context': model.get('context_window'),
                        'efforts': [level.get('effort') for level in
                                    model.get('supported_reasoning_levels') or []
                                    if isinstance(level, dict) and level.get('effort')]})
elif harness == 'muse':
    root = os.path.join(home, '.local/share/muse/model-catalog')
    for name in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        catalog = load(os.path.join(root, name)) or {}
        for row in catalog.get('rows') or []:
            if row.get('visibility') == 'visible' and row.get('model_id'):
                out.append({'id': row['model_id'], 'label': row.get('display_label') or row['model_id'],
                            'detail': row.get('description') or '',
                            'context': row.get('context_limit'),
                            'efforts': [v.get('tier') for v in
                                        row.get('reasoning_effort_variants') or []
                                        if isinstance(v, dict) and v.get('tier')]})
elif harness == 'pi':
    for line in shell('pi --list-models').splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] != 'provider' and not line.startswith('['):
            size = None
            if len(parts) > 2:
                found = re.match(r'^([\d.]+)([KM])$', parts[2])
                if found:
                    size = int(float(found.group(1)) * (1000 if found.group(2) == 'K' else 1000000))
            thinks = len(parts) > 4 and parts[4] == 'yes'
            out.append({'id': parts[0] + '/' + parts[1], 'label': parts[1], 'detail': parts[0],
                        'context': size, 'efforts': PI_EFFORTS if thinks else []})
elif harness == 'omp':
    text = shell('omp models --json')
    try:
        models = json.loads(text[text.index('{'):]).get('models') or []
    except ValueError:
        models = []
    for model in models:
        if model.get('kind', 'chat') == 'chat' and model.get('selector'):
            out.append({'id': model['selector'], 'label': model.get('name') or model['id'],
                        'detail': model.get('provider') or '',
                        'context': model.get('contextWindow')})
elif harness == 'opencode':
    # Windows from the catalog OpenCode caches, keyed by provider and model.
    catalog = load('.cache/opencode/models.json') or {}
    for line in shell('opencode models').splitlines():
        line = line.strip()
        if re.match(r'^[\w.-]+/[\w.:-]+$', line):
            provider, _, model = line.partition('/')
            limit = (((catalog.get(provider) or {}).get('models') or {}).get(model) or {}).get('limit') or {}
            out.append({'id': line, 'label': model, 'detail': provider,
                        'context': limit.get('context')})
seen = set()
unique = [m for m in out if not (m['id'] in seen or seen.add(m['id']))]
print('@@@' + json.dumps(unique))''';

  /// Whether a running [harness] can be switched to another model, or
  /// another effort, from the phone. omp and OpenCode pick both in browsers
  /// of their own that are not driven blind; they take them at start.
  static bool canSwitchModel(String? harness) =>
      const {'claude', 'pi', 'codex', 'muse'}.contains(harness);

  /// The effort levels an agent offers when the model is left as it is, in
  /// its own words.
  static List<String> effortsFor(String? harness, List<ModelOption> models) =>
      switch (harness) {
        'claude' => const ['low', 'medium', 'high', 'xhigh', 'max'],
        'pi' => const ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'],
        _ => [
            for (final e in {for (final m in models) ...m.efforts}) e,
          ],
      };

  /// Codex's reasoning levels as its list shows them; max and ultra sit a
  /// level down, under "More reasoning…".
  static const _codexEfforts = {
    'none': 'None',
    'minimal': 'Minimal',
    'low': 'Low',
    'medium': 'Medium',
    'high': 'High',
    'xhigh': 'Extra high',
  };
  static const _codexMore = 'More reasoning…';

  /// Switch a running agent to [model], to [effort], or both; null leaves
  /// that one as it is. Claude, Pi and muse take either with a command;
  /// Codex opens a list, whose rows are found on screen and moved to.
  /// Neither is saved as the agent's default for new sessions.
  Future<bool> switchModel(Pane pane,
      {ModelOption? model,
      String? effort,
      List<ModelOption> options = const []}) async {
    final rpc = _rpc;
    if (rpc == null || (model == null && effort == null)) return false;
    touchActivity();
    Future<void> pause(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));
    Future<void> type(String text) async {
      await rpc.sendText(pane.paneId, text);
      await pause(250);
      await rpc.sendKeys(pane.paneId, const ['enter']);
    }

    Future<String> screen() =>
        rpc.readPane(pane.paneId, source: 'visible', lines: 40);

    // Move to [target] in the list on screen and choose it with [confirm].
    // Not found, the list is closed: [depth] lists deep.
    Future<bool> pick(List<String> labels, String target,
        {String confirm = 'enter', int depth = 1}) async {
      final keys = pickerKeys(await screen(), labels, target, confirm: confirm);
      if (keys == null) {
        for (var i = 0; i < depth; i++) {
          await rpc.sendKeys(pane.paneId, const ['esc']);
          await pause(200);
        }
        return false;
      }
      for (final key in keys) {
        await rpc.sendKeys(pane.paneId, [key]);
        await pause(120);
      }
      return true;
    }

    try {
      switch (pane.agent) {
        case 'claude':
          // Claude saves what /model and /effort pick as the defaults for
          // every new session, so what it had saved is read first and put
          // back after.
          final before = await _claudeDefault('read');
          if (model != null) {
            await type('/model ${model.id}');
            await pause(1500);
          }
          if (effort != null) {
            await type('/effort $effort');
            await pause(1500);
          }
          if (before != null) await _claudeDefault('restore', before);
          return true;
        case 'pi':
          // The first Enter takes the completion Pi offers; the second runs
          // the command. Pi keeps both to this session.
          if (model != null) {
            await type('/model ${model.id}');
            await pause(400);
            await rpc.sendKeys(pane.paneId, const ['enter']);
            await pause(800);
          }
          if (effort != null) {
            await type('/thinking $effort');
            await pause(400);
            await rpc.sendKeys(pane.paneId, const ['enter']);
          }
          return true;
        case 'muse':
          // muse saves both as its defaults for new sessions; its settings
          // are kept aside and put back once the switch is done.
          final saved = await _museSettings('save');
          var ok = true;
          if (model != null) {
            await type('/model');
            await pause(1500);
            ok = await pick([
              for (final o in options.isEmpty ? [model] : options) o.id
            ], model.id);
            await pause(1000);
            // Some models ask for a level next, the cursor on the current
            // one.
            if (ok && _listShown(await screen(), _museLevels)) {
              await rpc.sendKeys(pane.paneId, const ['enter']);
              await pause(1000);
            }
          }
          if (ok && effort != null) {
            await type('/effort $effort');
            await pause(1000);
          }
          if (saved != null) await _museSettings('restore', saved);
          return ok;
        case 'codex':
          await type('/model');
          await pause(1500);
          if (model != null) {
            if (!await pick([
              for (final o in options.isEmpty ? [model] : options) o.label
            ], model.label)) {
              return false;
            }
          } else {
            // The list opens on the model in use.
            await rpc.sendKeys(pane.paneId, const ['enter']);
          }
          await pause(1000);
          // Codex then asks for a reasoning level: Enter would save it as the
          // default for new sessions, `s` keeps it to this one.
          if (effort == null) {
            await rpc.sendText(pane.paneId, 's');
            return true;
          }
          const levels = [..._codexEffortLabels, _codexMore];
          final label = _codexEfforts[effort];
          if (label != null) {
            return await pick(levels, label, confirm: 's', depth: 2);
          }
          if (!await pick(levels, _codexMore, depth: 2)) return false;
          await pause(800);
          final more = effort[0].toUpperCase() + effort.substring(1);
          return await pick(const ['Max', 'Ultra'], more, confirm: 's', depth: 3);
      }
    } catch (e) {
      error = 'could not switch: $e';
      notifyListeners();
    }
    return false;
  }

  static const _codexEffortLabels = [
    'None', 'Minimal', 'Low', 'Medium', 'High', 'Extra high'
  ];
  static const _museLevels = [
    'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'
  ];

  /// Whether a list of [labels] with a cursor in it is on [screen].
  static bool _listShown(String screen, List<String> labels) =>
      labels.any((l) => pickerKeys(screen, labels, l) != null);

  /// Keep muse's settings file aside, or put a kept copy back. The copy is
  /// base64, or empty when there was no file.
  Future<String?> _museSettings(String mode, [String? kept]) async {
    final ssh = _ssh;
    if (ssh == null) return null;
    const path = r'"$HOME/.config/muse/settings.json"';
    try {
      if (mode == 'save') {
        final out = await HerdrClient.run(
            ssh,
            'if [ -f $path ]; then printf "@@@"; base64 < $path | tr -d "\\n"; '
            'else printf "@@@"; fi',
            timeout: const Duration(seconds: 15));
        final text = utf8.decode(out, allowMalformed: true);
        final at = text.lastIndexOf('@@@');
        return at < 0 ? null : text.substring(at + 3).trim();
      }
      await HerdrClient.run(
          ssh,
          (kept ?? '').isEmpty
              ? 'rm -f $path'
              : 'printf %s ${_shellQuote(kept!)} | base64 -d > $path.shepherd '
                  '&& mv $path.shepherd $path',
          timeout: const Duration(seconds: 15));
      return 'ok';
    } catch (_) {
      return null;
    }
  }

  /// Read Claude's saved default model, or put [value] back as it. The value
  /// is JSON: the model, or null when none was saved.
  Future<String?> _claudeDefault(String mode, [String? value]) async {
    final ssh = _ssh;
    if (ssh == null) return null;
    try {
      final out = await HerdrClient.run(
        ssh,
        'python3 - $mode ${_shellQuote(value ?? '')} '
        '<<\'SHEPHERD_CLAUDE\'\n'
        '$_claudeDefaultPython\n'
        'SHEPHERD_CLAUDE',
        timeout: const Duration(seconds: 15),
      );
      final line = utf8
          .decode(out, allowMalformed: true)
          .split('\n')
          .lastWhere((l) => l.startsWith('@@@'), orElse: () => '');
      return line.isEmpty ? null : line.substring(3);
    } catch (_) {
      return null;
    }
  }

  static const _claudeDefaultPython = r'''import json, os, sys
path = os.path.expanduser('~/.claude/settings.json')
# What /model and /effort save: the model, and the effort for all models
# and for each one.
KEYS = ('model', 'effortLevel', 'modelSettings')
try:
    with open(path) as handle:
        settings = json.load(handle)
except (OSError, ValueError):
    settings = None
if sys.argv[1] == 'read':
    if isinstance(settings, dict):
        print('@@@' + json.dumps({k: settings[k] for k in KEYS if k in settings}))
elif isinstance(settings, dict):
    before = json.loads(sys.argv[2])
    changed = False
    for key in KEYS:
        if key in before:
            if settings.get(key) != before[key]:
                settings[key] = before[key]
                changed = True
        elif key in settings:
            del settings[key]
            changed = True
    if changed:
        with open(path + '.shepherd', 'w') as handle:
            handle.write(json.dumps(settings, indent=2) + '\n')
        os.replace(path + '.shepherd', path)
    print('@@@ok')''';

  /// The keys that move a list's cursor to [target] and choose it with
  /// [confirm], given the list on [screen] and every label it may show. Null when the list, its
  /// cursor or the target is not on screen.
  @visibleForTesting
  static List<String>? pickerKeys(
      String screen, List<String> labels, String target,
      {String confirm = 'enter'}) {
    final rows = <String>[];
    int? cursor;
    for (final line in screen.split(RegExp(r'\r?\n'))) {
      final m = RegExp(r'^\s*([›❯⟩>])?\s*(?:\d+\.\s+)?(\S.*)$').firstMatch(line);
      if (m == null) continue;
      final text = m.group(2)!;
      // The longest label the row begins with: "muse-spark-1.3" is also the
      // start of "muse-spark-1.3-contributor".
      String? label;
      for (final l in labels) {
        final follows = text.length == l.length ||
            (text.length > l.length && text.startsWith(RegExp(r'[\s(]'), l.length));
        if (text.startsWith(l) && follows && (label == null || l.length > label.length)) {
          label = l;
        }
      }
      if (label == null) continue;
      if (m.group(1) != null) cursor = rows.length;
      rows.add(label);
    }
    final to = rows.indexOf(target);
    if (cursor == null || to < 0) return null;
    return [
      for (var i = cursor; i < to; i++) 'down',
      for (var i = cursor; i > to; i--) 'up',
      confirm,
    ];
  }

  /// The agents Shepherd can start, with the command that starts each.
  static const harnesses = <String, String>{
    'claude': 'claude',
    'codex': 'codex',
    'pi': 'pi',
    'omp': 'omp',
    'opencode': 'opencode',
    'muse': 'muse',
  };

  /// Which of [harnesses] are installed on the host, looked up the way the
  /// pane's own shell would find them: an interactive login shell, so the
  /// PATH additions in the user's profile apply.
  Future<List<String>> installedHarnesses() async {
    final ssh = _ssh;
    if (ssh == null) return const [];
    final names = harnesses.values.join(' ');
    try {
      final out = await HerdrClient.run(
        ssh,
        '"\${SHELL:-/bin/sh}" -lic \'for c in $names; do '
        'command -v "\$c" >/dev/null 2>&1 && echo "@@@\$c"; done\' '
        '</dev/null 2>/dev/null',
        timeout: const Duration(seconds: 20),
      );
      final found = {
        for (final line in utf8.decode(out, allowMalformed: true).split('\n'))
          if (line.trim().startsWith('@@@')) line.trim().substring(3)
      };
      return [
        for (final e in harnesses.entries)
          if (found.contains(e.value)) e.key
      ];
    } catch (_) {
      return const [];
    }
  }

  /// A folder on the host and the folders in it, hidden ones left out, for
  /// choosing where to start an agent. An empty [path] means the home folder.
  Future<({String path, List<String> folders})?> listFolders(
      String path) async {
    final ssh = _ssh;
    if (ssh == null) return null;
    try {
      final out = await HerdrClient.run(
        ssh,
        'python3 - ${_shellQuote(path)} <<\'SHEPHERD_DIRS\'\n'
        '$_foldersPython\n'
        'SHEPHERD_DIRS',
        timeout: const Duration(seconds: 20),
      );
      final lines = utf8
          .decode(out, allowMalformed: true)
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      final at = lines.indexWhere((l) => l.startsWith('@@@'));
      if (at < 0) return null;
      return (
        path: lines[at].substring(3),
        folders: lines.sublist(at + 1),
      );
    } catch (_) {
      return null;
    }
  }

  static const _foldersPython = r'''import os, sys
path = os.path.realpath(os.path.expanduser(sys.argv[1] or '~'))
if not os.path.isdir(path):
    path = os.path.expanduser('~')
print('@@@' + path)
try:
    names = sorted(os.listdir(path), key=str.lower)
except OSError:
    names = []
for name in names:
    if name.startswith('.'):
        continue
    if os.path.isdir(os.path.join(path, name)):
        print(name)''';

  /// The folders agents already run in, for starting another one beside
  /// them without browsing.
  List<String> get agentFolders {
    final seen = <String>{};
    return [
      for (final p in host.agentPanes)
        if (p.cwd != null && p.cwd!.isNotEmpty && seen.add(p.cwd!)) p.cwd!
    ];
  }

  /// Start [harness] in a new Herdr workspace in [cwd]. Herdr has no call
  /// that runs a command, so the command is typed into the new pane's shell,
  /// as its own CLI does.
  Future<bool> startAgent(String cwd, String harness, {String? model}) async {
    final rpc = _rpc;
    final base = harnesses[harness];
    final command = model == null || base == null
        ? base
        : '$base ${modelFlags[harness]} ${_shellQuote(model)}';
    if (rpc == null || command == null) return false;
    touchActivity();
    try {
      final label = cwd.split('/').where((s) => s.isNotEmpty).lastOrNull;
      final paneId = await rpc.createWorkspace(cwd, label: label);
      if (paneId == null) return false;
      await rpc.sendText(paneId, command);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await rpc.sendKeys(paneId, const ['enter']);
      await refreshNow();
      return true;
    } catch (e) {
      error = 'could not start $harness: $e';
      notifyListeners();
      return false;
    }
  }

  /// Close an agent's pane on the host. The agent stops; its transcript
  /// stays on disk. Returns whether Herdr accepted it.
  Future<bool> closePane(String paneId) async {
    final rpc = _rpc;
    if (rpc == null) return false;
    try {
      await rpc.closePane(paneId);
    } catch (e) {
      error = 'close failed: $e';
      notifyListeners();
      return false;
    }
    if (selectedPaneId == paneId) selectedPaneId = null;
    _blockedPrompts.remove(paneId);
    host = HostState(
      workspaces: host.workspaces,
      tabs: host.tabs,
      panes: host.panes.where((p) => p.paneId != paneId).toList(),
      agents: host.agents.where((p) => p.paneId != paneId).toList(),
      focusedWorkspaceId: host.focusedWorkspaceId,
      focusedTabId: host.focusedTabId,
      focusedPaneId: host.focusedPaneId,
    );
    notifyListeners();
    return true;
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

/// What a session has cost, in dollars at API rates: written by the agent,
/// or — [estimated] — its tokens priced from a public table. Models the
/// table does not list are [unpriced] and left out of [usd].
class SessionCost {
  final double usd;
  final bool estimated;
  final List<String> unpriced;
  final DateTime at;

  SessionCost({
    required this.usd,
    this.estimated = false,
    this.unpriced = const [],
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// The script's answer: its last line, JSON.
  static SessionCost? parse(String output) {
    final line = output.trim().split('\n').last;
    try {
      final m = jsonDecode(line);
      if (m is! Map || m['usd'] is! num) return null;
      return SessionCost(
        usd: (m['usd'] as num).toDouble(),
        estimated: m['estimated'] == true,
        unpriced: [for (final u in (m['unpriced'] as List? ?? [])) '$u'],
      );
    } catch (_) {
      return null;
    }
  }

  /// "$12.34", "≈ $750", or why there is no figure.
  String get label {
    if (usd <= 0 && unpriced.isNotEmpty) return 'cost unknown';
    final amount = usd == 0
        ? r'$0'
        : usd < 0.01
            ? r'<$0.01'
            : usd < 100
                ? '\$${usd.toStringAsFixed(2)}'
                : '\$${usd.round()}';
    return '${estimated ? '≈ ' : ''}$amount${unpriced.isEmpty ? '' : '+'}';
  }
}

/// One subscription as the host reads it: whose, which plan, and how much
/// of each of its limits is used; or why it could not be read.
class PlanUsage {
  final String provider;
  final String plan;
  final List<PlanWindow> windows;
  final String? error;

  const PlanUsage(
      {required this.provider,
      this.plan = '',
      this.windows = const [],
      this.error})
      : _at = null;

  const PlanUsage._(
      {required this.provider,
      required this.plan,
      required this.windows,
      this.error,
      DateTime? at})
      : _at = at;

  /// When this reading was taken, when the reader says.
  DateTime? get at => _at;
  final DateTime? _at;

  /// The host script's answer: one entry per provider, already in one shape
  /// whichever reader it came from.
  static List<PlanUsage> fromList(List found) => [
        for (final p in found.whereType<Map>())
          if (p['provider'] is String)
            PlanUsage._(
              provider: p['provider'] as String,
              plan: (p['plan'] as String?) ?? '',
              error: p['error'] as String?,
              at: DateTime.tryParse('${p['at'] ?? ''}'),
              windows: [
                for (final w in (p['windows'] as List? ?? const [])
                    .whereType<Map>())
                  if (w['usedPercent'] is num)
                    PlanWindow(
                      label: w['label'] as String?,
                      usedPercent: (w['usedPercent'] as num).toDouble(),
                      minutes: (w['minutes'] as num?)?.toInt(),
                      resetsAt: DateTime.tryParse('${w['resetsAt'] ?? ''}'),
                      pace: w['pace'] as String?,
                    ),
              ],
            ),
      ];
}

/// One limit of a plan: a session, a week, a month.
class PlanWindow {
  final String? label;
  final double usedPercent;
  final int? minutes;
  final DateTime? resetsAt;

  /// CodexBar's reading of the rate you are going at, e.g. "Runs out in
  /// 22h 31m".
  final String? pace;

  const PlanWindow(
      {this.label,
      required this.usedPercent,
      this.minutes,
      this.resetsAt,
      this.pace});
}

/// A model an agent can run on: the id its flag and command take, and what
/// to call it.
class ModelOption {
  final String id;
  final String label;
  final String detail;

  /// The model's context window in tokens, when the agent lists it.
  final int? context;

  /// The levels the model can be asked to think at, in the agent's words;
  /// empty when it has none.
  final List<String> efforts;

  const ModelOption(
      {required this.id,
      required this.label,
      this.detail = '',
      this.context,
      this.efforts = const []});
}
