import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'client.dart';
import 'host_client.dart';
import 'models.dart';

/// herdr-core over one SSH channel: `hc connect` speaks its JSON-RPC on
/// stdin and stdout, requests and pushed events on the same line.
///
/// The Herdr app keeps its spaces and tabs in the core, as a document named
/// `herdr-app`, and labels each terminal with the space and tab it is in.
/// A space is what the app shows as a workspace; a terminal is a pane.
class CoreClient implements HostClient {
  final Stream<List<int>> _out;
  final StreamSink<List<int>> _in;
  final void Function() _hangUp;

  /// Another channel to the same core. A connection that subscribes to
  /// events carries only events from then on, so they get one of their own.
  final Future<CoreClient?> Function()? _another;

  /// The login home on the host, where Claude Code keeps its sessions.
  late final String home;

  final _home = Completer<void>();
  final _head = <int>[];
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _lines = JsonLines();
  late final StreamSubscription _sub;
  int _nextId = 1;
  bool _closed = false;

  CoreClient._(this._out, this._in, this._hangUp, this._another) {
    _sub = _out.listen(_read, onDone: _end, onError: (_) => _end());
  }

  /// The core's own shell line: it prints the home first, so the client can
  /// find Claude's files without a second channel, and says nothing at all
  /// when there is no `hc`. The installer puts `hc` in ~/.local/bin, which a
  /// non-interactive SSH session does not have on its PATH.
  @visibleForTesting
  static const launch = "sh -c '"
      r'PATH="$HOME/.local/bin:$PATH"; '
      'command -v hc >/dev/null 2>&1 || exit 127; '
      r'printf "%s\n" "$HOME"; '
      "exec hc connect'";

  /// The core on this host, or null when it has none.
  static Future<CoreClient?> connect(SSHClient ssh) async {
    final SSHSession session;
    try {
      session = await HerdrClient.execute(ssh, launch);
    } catch (_) {
      return null;
    }
    return over(session.stdout, session.stdin, session.close,
        another: () => connect(ssh));
  }

  /// The core at the other end of [out] and [into], a channel already
  /// running [launch]; null when no core answers there.
  @visibleForTesting
  static Future<CoreClient?> over(Stream<List<int>> out,
      StreamSink<List<int>> into, void Function() hangUp,
      {Future<CoreClient?> Function()? another}) async {
    final client = CoreClient._(out, into, hangUp, another);
    try {
      await client._home.future.timeout(const Duration(seconds: 10));
      await client._call('hello', {'generation': 1});
      return client;
    } catch (_) {
      await client.close();
      return null;
    }
  }

  /// The first line is the home; JSON follows.
  void _read(List<int> data) {
    if (_home.isCompleted) return _take(data);
    _head.addAll(data);
    final nl = _head.indexOf(0x0a);
    if (nl < 0) return;
    home = utf8.decode(_head.sublist(0, nl), allowMalformed: true).trim();
    _home.complete();
    final rest = _head.sublist(nl + 1);
    _head.clear();
    if (rest.isNotEmpty) _take(rest);
  }

  void _take(List<int> data) {
    for (final msg in _lines.add(data)) {
      final id = msg['id'];
      if (id is int) {
        final waiting = _pending.remove(id);
        if (waiting == null) continue;
        final error = msg['error'];
        if (error is Map) {
          final kind = (error['data'] as Map?)?['kind'] as String?;
          waiting.completeError(HerdrError(
              kind ?? '${error['code']}', '${error['message'] ?? error}'));
        } else {
          waiting.complete(
              (msg['result'] as Map?)?.cast<String, dynamic>() ?? const {});
        }
      } else if (msg['method'] == 'event' && !_events.isClosed) {
        _events.add((msg['params'] as Map?)?.cast<String, dynamic>() ?? {});
      }
    }
  }

  void _end() {
    _closed = true;
    if (!_home.isCompleted) _home.completeError(StateError('no hc'));
    for (final waiting in _pending.values) {
      waiting.completeError(const HerdrError('closed', 'herdr-core went away'));
    }
    _pending.clear();
    if (!_events.isClosed) _events.close();
  }

  Future<Map<String, dynamic>> _call(String method,
      [Map<String, dynamic> params = const {}]) {
    if (_closed) {
      return Future.error(const HerdrError('closed', 'herdr-core went away'));
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _in.add(Uint8List.fromList(utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})}\n')));
    return completer.future.timeout(const Duration(seconds: 20), onTimeout: () {
      _pending.remove(id);
      throw HerdrError('timeout', '$method did not answer');
    });
  }

  @override
  Future<String> ping() async {
    final status = await _call('server.status');
    return 'HERDR-CORE ${status['version'] ?? '?'}';
  }

  @override
  Future<HostState> snapshot() async {
    final results = await Future.wait([
      _call('terminal.list'),
      _call('doc.get', {'name': 'herdr-app'}),
    ]);
    final terminals = [
      for (final t in (results[0]['terminals'] as List? ?? const []))
        if (t is Map) t.cast<String, dynamic>()
    ];
    final layout = (results[1]['value'] as Map?)?.cast<String, dynamic>();
    final sessions = <int, Map<String, dynamic>>{};
    await Future.wait([
      for (final t in terminals)
        if (agentOf(t) == 'claude' && _foregroundPid(t) != null)
          _claudeSession(_foregroundPid(t)!).then((s) {
            if (s != null) sessions[_foregroundPid(t)!] = s;
          }),
    ]);
    return hostState(terminals, layout, sessions);
  }

  static int? _foregroundPid(Map<String, dynamic> t) =>
      ((t['foreground'] as Map?)?['pid'] as num?)?.toInt();

  /// What Claude Code says about the process: the session it has open, and
  /// the name you gave it. It rewrites the file when either changes.
  Future<Map<String, dynamic>?> _claudeSession(int pid) async {
    try {
      final res = await _call(
          'file.read', {'path': '$home/.claude/sessions/$pid.json'});
      final value = jsonDecode(res['text'] as String? ?? '');
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// What the core reports, as the app reads a host: each space a workspace,
  /// each tab a tab, each terminal a pane.
  @visibleForTesting
  static HostState hostState(List<Map<String, dynamic>> terminals,
      Map<String, dynamic>? layout, Map<int, Map<String, dynamic>> sessions) {
    final spaceNames = <String, String>{};
    final tabNames = <String, String>{};
    final order = <String>[];
    for (final space in (layout?['spaces'] as List? ?? const [])) {
      if (space is! Map) continue;
      final id = space['id'] as String?;
      if (id == null) continue;
      order.add(id);
      spaceNames[id] = (space['name'] as String?) ?? '';
      for (final tab in (space['tabs'] as List? ?? const [])) {
        if (tab is Map && tab['id'] is String) {
          tabNames[tab['id'] as String] = (tab['name'] as String?) ?? '';
        }
      }
    }

    final panes = <Pane>[];
    final workspaces = <String, Workspace>{};
    final tabs = <String, TabInfo>{};
    for (final t in terminals) {
      if (t['state'] != 'live') continue;
      final address = t['address'] as String?;
      if (address == null) continue;
      final labels = (t['labels'] as Map?)?.cast<String, dynamic>() ?? const {};
      final spaceId = (labels['herdr.space'] as String?) ?? 'space:$address';
      final tabId = (labels['herdr.tab'] as String?) ?? 'tab:$address';
      // "ledger / 1": what the app calls the space and the tab, its own
      // name when nobody gave one.
      final where = (labels['where'] as String?) ?? '';
      final cut = where.lastIndexOf(' / ');
      final spaceShown = cut < 0 ? where : where.substring(0, cut);
      final tabShown = cut < 0 ? '' : where.substring(cut + 3);

      final foreground = (t['foreground'] as Map?)?.cast<String, dynamic>();
      final pid = _foregroundPid(t);
      final session = pid == null ? null : sessions[pid];
      final agent = agentOf(t);
      final named = [
        tabNames[tabId] ?? '',
        spaceNames[spaceId] ?? '',
        if (session?['nameSource'] == 'user') (session?['name'] as String?) ?? '',
      ].firstWhere((n) => n.trim().isNotEmpty, orElse: () => '');

      panes.add(Pane(
        paneId: address,
        tabId: tabId,
        workspaceId: spaceId,
        agent: agent,
        agentStatus: agent == null ? null : statusOf(t),
        cwd: (foreground?['cwd'] as String?) ?? (t['cwd'] as String?),
        title: t['title'] as String?,
        label: named.isEmpty ? null : named,
        agentSession: session?['sessionId'] is String
            ? AgentSession(
                agent: 'claude',
                kind: 'id',
                value: session!['sessionId'] as String)
            : null,
        stateSeq: (t['status_ms'] as num?)?.toInt() ?? 0,
      ));
      workspaces.putIfAbsent(
          spaceId,
          () => Workspace(
              workspaceId: spaceId,
              label: spaceShown.isEmpty ? address : spaceShown));
      tabs.putIfAbsent(
          tabId,
          () => TabInfo(
              tabId: tabId,
              workspaceId: spaceId,
              label: tabNames[tabId]?.isNotEmpty == true
                  ? tabNames[tabId]!
                  : tabShown));
    }

    // The app's order, then any terminal it does not show.
    int rank(String spaceId) {
      final i = order.indexOf(spaceId);
      return i < 0 ? order.length : i;
    }

    final spaces = workspaces.values.toList()
      ..sort((a, b) => rank(a.workspaceId).compareTo(rank(b.workspaceId)));
    return HostState(
      workspaces: spaces,
      tabs: tabs.values.toList(),
      panes: panes,
      agents: [for (final p in panes) if (p.agent != null) p],
    );
  }

  /// The agents the app knows, by the name each reports itself under or the
  /// program running in the terminal.
  static const _agents = {
    'claude-code': 'claude',
    'claude': 'claude',
    'codex': 'codex',
    'pi': 'pi',
    'omp': 'omp',
    'opencode': 'opencode',
    'muse': 'muse',
  };

  @visibleForTesting
  static String? agentOf(Map<String, dynamic> t) {
    final app = (t['status'] as Map?)?['app'] as String?;
    if (app != null) return _agents[app] ?? app;
    final argv = ((t['foreground'] as Map?)?['argv'] as List?) ?? const [];
    if (argv.isEmpty) return null;
    return _agents[(argv.first as String).split('/').last];
  }

  /// The agent's own word for its state. One that stopped on an error has
  /// finished its turn as far as you are concerned: it wants a look.
  @visibleForTesting
  static String statusOf(Map<String, dynamic> t) {
    final state = (t['status'] as Map?)?['state'] as String?;
    return switch (state) {
      null => 'unknown',
      'error' => 'done',
      _ => state,
    };
  }

  @override
  Future<HostEvents> subscribe() async {
    final channel = await _another?.call();
    if (channel == null) {
      throw const HerdrError('events', 'no second channel to the core');
    }
    try {
      await channel._call('events.subscribe');
    } catch (_) {
      await channel.close();
      rethrow;
    }
    return _CoreEvents(channel);
  }

  /// The app's own command line, run by the core on the host. A host
  /// without the app just has no window to change.
  Future<void> _app(List<String> args) async {
    await _call('machine.exec', {
      'argv': [
        'sh',
        '-c',
        r'PATH="$HOME/.local/bin:$PATH"; exec herdr-app "$@"',
        'herdr-app',
        ...args,
      ],
      'timeout': 10,
    });
  }

  @override
  Future<void> focusPane(Pane pane) async {
    try {
      await _app(['do', 'pane.focus', '--terminal', pane.paneId]);
    } catch (_) {}
  }

  /// The name is the space's: the app's spaces are what you name, and a
  /// session moved over from Herdr took its pane's name to its space.
  @override
  Future<void> renamePane(String paneId, String? label) async {
    final t = await _call('terminal.get', {'terminal': paneId});
    final space = ((t['labels'] as Map?)?['herdr.space']) as String?;
    if (space == null) return;
    await _app(['do', 'space.rename', '--id', space, '--name', label ?? '']);
  }

  /// Typed even when the agent is waiting on a question: the answer may be
  /// what you are typing.
  @override
  Future<void> submit(String paneId, String text) =>
      _call('terminal.send', {'terminal': paneId, 'text': text, 'force': true});

  @override
  Future<void> sendKeys(String paneId, List<String> keys) =>
      _call('terminal.keys', {'terminal': paneId, 'keys': keys});

  /// A space of its own, as the app makes one: the labels name a space and
  /// a tab nobody has yet, which the app takes as new ones. The agent runs
  /// in the login shell, which stays when the agent exits.
  @override
  Future<String?> startAgent(String cwd, String command,
      {String? label}) async {
    String id(String prefix) =>
        '$prefix${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    final run = await _call('terminal.run', {
      'cwd': cwd,
      'keep': true,
      'no_parent': true,
      'labels': ['herdr.space=${id('sp')}', 'herdr.tab=${id('tb')}'],
    });
    final address = run['address'] as String?;
    if (address == null) return null;
    await submit(address, command);
    return address;
  }

  static const _shells = {'sh', 'bash', 'zsh', 'fish', 'dash', 'ksh', 'tcsh'};

  @override
  Future<String?> paneAgent(String paneId) async {
    final t = await _call('terminal.get', {'terminal': paneId});
    final argv = ((t['foreground'] as Map?)?['argv'] as List?) ?? const [];
    final program = argv.isEmpty
        ? ''
        : (argv.first as String).split('/').last.replaceFirst('-', '');
    if (argv.isEmpty || _shells.contains(program)) return null;
    return agentOf(t.cast<String, dynamic>()) ?? program;
  }

  @override
  Future<void> closePane(String paneId) =>
      _call('terminal.kill', {'terminal': paneId});

  /// The core reads as text, without colours.
  @override
  Future<String> readPane(String paneId,
      {String source = 'recent_unwrapped',
      int lines = 60,
      bool ansi = false}) async {
    final res = await _call('terminal.read', {
      'terminal': paneId,
      'lines': source == 'visible' ? 0 : lines,
    });
    final text = res['text'] as String? ?? '';
    if (source != 'visible') return text;
    // The visible screen, cut to the last [lines] as Herdr's is.
    final rows = text.split('\n');
    return rows.length <= lines
        ? text
        : rows.sublist(rows.length - lines).join('\n');
  }

  @override
  Future<void> close() async {
    _end();
    await _sub.cancel();
    _hangUp();
  }
}

class _CoreEvents implements HostEvents {
  final CoreClient _channel;

  _CoreEvents(this._channel);

  @override
  Stream<Map<String, dynamic>> get events => _channel._events.stream;

  @override
  Future<void> close() => _channel.close();
}
