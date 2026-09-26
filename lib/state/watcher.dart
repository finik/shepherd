import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../herdr/client.dart';
import '../herdr/models.dart';
import 'machines.dart';

/// Watches the host while the app is not on screen, and says when an agent
/// wants you.
///
/// This runs in the foreground service's own isolate on its own SSH
/// connection. Android stops a backgrounded app's timers within minutes, so a
/// watcher living in the UI isolate would simply go quiet — which is the one
/// failure mode a notification feature cannot have.
@pragma('vm:entry-point')
void watcherCallback() => FlutterForegroundTask.setTaskHandler(AgentWatcher());

/// Where the default Herdr socket sits, relative to the login home.
const _socketSuffix = '.config/herdr/herdr.sock';

/// What to say about a pane that moved from [before] to [now], or null to
/// stay quiet.
///
/// A first sighting is never news: an agent that finished before the service
/// started did not finish while you were away. Blocked is worth saying however
/// it was reached, because nothing proceeds until you answer; finished is only
/// worth saying if we watched it working.
String? worthSaying(String? before, String now) {
  if (before == null || before == now) return null;
  if (now == 'blocked') return 'Waiting for your answer';
  if (before == 'working' && (now == 'done' || now == 'idle')) {
    return 'Finished';
  }
  return null;
}

class AgentWatcher extends TaskHandler {
  static const channelId = 'agent_events';

  final _notifications = FlutterLocalNotificationsPlugin();
  final _store = MachineStore();

  SSHClient? _ssh;
  HerdrClient? _rpc;

  /// Last status seen per pane. The first poll only establishes this — an
  /// agent that finished before the service started is not news.
  final Map<String, String> _seen = {};

  /// Minutes of recent host activity that suppress a notification. Sent by
  /// the app when the setting changes and when the service starts.
  int _quietMinutes = 0;
  int _notificationId = 1;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _connect();
  }

  @override
  void onRepeatEvent(DateTime timestamp) => _poll();

  @override
  void onReceiveData(Object data) {
    if (data is Map && data['quietMinutes'] is int) {
      _quietMinutes = data['quietMinutes'] as int;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _ssh?.close();
    _ssh = null;
    _rpc = null;
  }

  Future<void> _connect() async {
    try {
      final machine = await _store.active();
      if (machine == null) return;
      final key = await _store.privateKey(machine.id);
      final password = await _store.password(machine.id);
      final socket = await SSHSocket.connect(machine.host, machine.port,
          timeout: const Duration(seconds: 20));
      final ssh = SSHClient(
        socket,
        username: machine.user,
        identities: (key == null || key.isEmpty)
            ? null
            : SSHKeyPair.fromPem(key),
        onPasswordRequest: (password == null || password.isEmpty)
            ? null
            : () => password,
      );
      await ssh.authenticated;
      var home = '';
      try {
        home = utf8.decode(await ssh.run(r'printf %s "$HOME"')).trim();
      } catch (_) {
        // A host that will not answer this will not answer a snapshot either;
        // the poll below reports the failure.
      }
      if (home.isEmpty) home = '/home/${machine.user}';
      _ssh = ssh;
      _rpc = HerdrClient(ssh, '$home/$_socketSuffix');
    } catch (_) {
      _ssh?.close();
      _ssh = null;
      _rpc = null;
    }
  }

  Future<void> _poll() async {
    if (_rpc == null) {
      await _connect();
      if (_rpc == null) return;
    }
    HostState snapshot;
    try {
      snapshot = await _rpc!.snapshot();
    } catch (_) {
      // The connection did not survive; drop it and let the next tick dial
      // again rather than reporting silence as calm.
      _ssh?.close();
      _ssh = null;
      _rpc = null;
      return;
    }

    final agents = snapshot.agentPanes;
    final working = agents.where((p) => p.isWorking).length;
    // Tell the app the watcher is alive, so Settings can say so rather than
    // leaving a switch that may have quietly failed.
    FlutterForegroundTask.sendDataToMain({
      'watching': agents.length,
      'working': working,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    FlutterForegroundTask.updateService(
      notificationTitle: 'Shepherd',
      notificationText: working > 0
          ? '$working of ${agents.length} working'
          : 'Watching ${agents.length} agents',
    );

    for (final pane in agents) {
      final status = pane.agentStatus ?? 'unknown';
      final before = _seen[pane.paneId];
      _seen[pane.paneId] = status;
      final news = worthSaying(before, status);
      if (news == null) continue;
      // A question waits indefinitely and produces no further event, so
      // only "finished" is worth staying quiet about.
      if (status != 'blocked' && await _recentlyHere(snapshot)) continue;
      await _notify(pane.sessionName, news);
    }
  }

  /// Whether you were interacting recently enough that a notification would
  /// be telling you what you are already watching.
  ///
  /// The same two sources the Herdr plugin uses: the newest user message in
  /// any transcript, and the newest heartbeat this app left on the host. No
  /// system input is read — prompting an agent counts, reading the news does
  /// not. Asked only when something is about to be said.
  Future<bool> _recentlyHere(HostState snapshot) async {
    if (_quietMinutes <= 0) return false;
    final ssh = _ssh;
    if (ssh == null) return false;
    final panes = [
      for (final pane in snapshot.agentPanes)
        {
          'agent': pane.agent,
          'kind': pane.agentSession?.kind,
          'value': pane.agentSession?.value,
          'cwd': pane.cwd,
        }
    ];
    try {
      final out = utf8.decode(await ssh
          .run(lastInteractionScript(panes))
          .timeout(const Duration(seconds: 15)));
      final seconds = double.tryParse(out.trim());
      if (seconds == null) return false;
      return seconds < _quietMinutes * 60;
    } catch (_) {
      // Unmeasurable means send: silence is the worse failure.
      return false;
    }
  }

  /// How long ago you last prompted an agent or used the app, in seconds, or
  /// an empty line when nothing can be measured.
  @visibleForTesting
  static String lastInteractionScript(List<Map<String, String?>> panes) {
    final json = jsonEncode(panes);
    return "python3 - '${json.replaceAll("'", "'\\''")}' <<'SNIPPET'\n"
        '$_interaction\nSNIPPET\n';
  }

  /// Seconds since the newest user message or phone heartbeat, printed by the
  /// host. Python because reading JSON records in shell is how subtle bugs
  /// get in, and every host that runs Herdr already has it.
  static const _interaction = r'''
import datetime, json, os, subprocess, sys, time
# One JSON argument: the agent panes, each with agent, kind, value and cwd.
panes = json.loads(sys.argv[1])


def stamp_of(value):
    # A stamp with no offset is UTC; read as local time it lands in the
    # future and would read as "you were here just now".
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.timestamp()


def typed_by_you(record):
    message = record.get('message')
    if isinstance(message, dict) and message.get('role') == 'user':
        content = message.get('content')
        if isinstance(content, list):
            return any(isinstance(b, dict) and b.get('type') == 'text'
                       for b in content)
        return isinstance(content, str) and bool(content.strip())
    payload = record.get('payload')
    if (record.get('type') == 'response_item' and isinstance(payload, dict)
            and payload.get('type') == 'message'
            and payload.get('role') == 'user'):
        text = ' '.join(b.get('text', '') for b in payload.get('content') or []
                        if isinstance(b, dict)).strip()
        return bool(text) and not text.startswith('<')
    return False


def codex_rollout(cwd):
    want, best = os.path.realpath(cwd), None
    for base, _, names in os.walk(os.path.expanduser('~/.codex/sessions')):
        for name in names:
            if not (name.startswith('rollout-') and name.endswith('.jsonl')):
                continue
            path = os.path.join(base, name)
            try:
                with open(path) as handle:
                    meta = json.loads(handle.readline()).get('payload') or {}
            except (OSError, ValueError):
                continue
            if meta.get('cwd') and os.path.realpath(meta['cwd']) == want:
                mtime = os.path.getmtime(path)
                if best is None or mtime > best[0]:
                    best = (mtime, path)
    return best[1] if best else None


def opencode_time(ids):
    db = os.path.expanduser('~/.local/share/opencode/opencode.db')
    if not ids or not os.path.exists(db):
        return None
    import sqlite3
    try:
        conn = sqlite3.connect('file:%s?mode=ro' % db, uri=True, timeout=5)
        row = conn.execute(
            'select max(time_created) from message where session_id in (%s) '
            "and json_extract(data, '$.role') = 'user'"
            % ','.join('?' * len(ids)), ids).fetchone()
        conn.close()
    except sqlite3.Error:
        return None
    return row[0] / 1000 if row and row[0] else None


paths, opencode = [], []
for pane in panes:
    agent, kind, value = pane.get('agent'), pane.get('kind'), pane.get('value')
    if agent == 'opencode' and (value or '').startswith('ses_'):
        opencode.append(value)
    elif kind == 'path' and value:
        paths.append(value)
    elif kind == 'id' and value and all(c.isalnum() or c in '._-' for c in value):
        out = subprocess.run(
            ['find', os.path.expanduser('~/.claude/projects'),
             os.path.expanduser('~/.codex/sessions'), '-maxdepth', '3',
             '-name', '*%s*.jsonl' % value],
            capture_output=True, text=True).stdout.split()
        paths.extend(out[:1])
    elif agent == 'codex' and pane.get('cwd'):
        found = codex_rollout(pane['cwd'])
        if found:
            paths.append(found)

def last_typed(path):
    # Backwards from the end, a block at a time: one long agent turn puts
    # megabytes of tool output after the prompt that started it.
    try:
        handle = open(path, 'rb')
    except OSError:
        return None
    with handle:
        end = handle.seek(0, os.SEEK_END)
        tail = b''
        while end > 0 and len(tail) < 16 << 20:
            start = max(0, end - (256 << 10))
            handle.seek(start)
            tail = handle.read(end - start) + tail
            end = start
            lines = tail.split(b'\n')
            # The first line may be cut off unless this is the file's start.
            complete = lines if start == 0 else lines[1:]
            for line in reversed(complete):
                if b'"user"' not in line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if typed_by_you(record):
                    return stamp_of(record.get('timestamp'))
    return None


newest = opencode_time(opencode)
for path in paths:
    value = last_typed(path)
    if value is not None and (newest is None or value > newest):
        newest = value
active = os.path.expanduser('~/.shepherd/active')
try:
    for name in os.listdir(active):
        value = os.path.getmtime(os.path.join(active, name))
        if newest is None or value > newest:
            newest = value
except OSError:
    pass
if newest is None or newest - time.time() > 60:
    print('')
else:
    print(max(0.0, time.time() - newest))
''';

  Future<void> _notify(String title, String body) async {
    await _notifications.show(
      id: _notificationId++,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          'Agent events',
          channelDescription: 'When an agent finishes or needs an answer.',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
}
