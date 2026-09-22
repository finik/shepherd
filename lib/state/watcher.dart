import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
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
    final paths = [
      for (final pane in snapshot.agentPanes)
        if (pane.agentSession?.isPath ?? false) pane.agentSession!.value
    ];
    try {
      final out = utf8.decode(await ssh
          .run(_lastInteractionScript(paths))
          .timeout(const Duration(seconds: 15)));
      final seconds = double.tryParse(out.trim());
      if (seconds == null) return false;
      return seconds < _quietMinutes * 60;
    } catch (_) {
      // Unmeasurable means send: silence is the worse failure.
      return false;
    }
  }

  static String _lastInteractionScript(List<String> paths) {
    final quoted = paths
        .map((p) => "'" + p.replaceAll("'", "'\\''") + "'")
        .join(' ');
    return "python3 - " + quoted + " <<'SNIPPET'\n" + _interaction + "\nSNIPPET\n";
  }

  /// Seconds since the newest user message or phone heartbeat, printed by the
  /// host. Python because reading JSON records in shell is how subtle bugs
  /// get in, and every host that runs Herdr already has it.
  static const _interaction = r'''
import json, os, sys, time
newest = None
for path in sys.argv[1:]:
    try:
        with open(path, 'rb') as handle:
            handle.seek(0, os.SEEK_END)
            handle.seek(max(0, handle.tell() - 64000))
            chunk = handle.read().decode('utf-8', 'replace')
    except OSError:
        continue
    for line in chunk.splitlines():
        if '"user"' not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        message = record.get('message')
        if not isinstance(message, dict) or message.get('role') != 'user':
            continue
        content = message.get('content')
        if isinstance(content, list) and not any(
                isinstance(b, dict) and b.get('type') == 'text'
                for b in content):
            continue
        stamp = record.get('timestamp')
        if not isinstance(stamp, str):
            continue
        try:
            import datetime
            value = datetime.datetime.fromisoformat(
                stamp.replace('Z', '+00:00')).timestamp()
        except ValueError:
            continue
        if newest is None or value > newest:
            newest = value
active = os.path.expanduser('~/.shepherd/active')
try:
    for name in os.listdir(active):
        value = os.path.getmtime(os.path.join(active, name))
        if newest is None or value > newest:
            newest = value
except OSError:
    pass
print('' if newest is None else max(0.0, time.time() - newest))
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
