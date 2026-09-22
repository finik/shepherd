import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A saved SSH host. Secrets never live here — they go to the platform
/// keystore under this machine's id.
class Machine {
  final String id;
  final String label;
  final String host;
  final int port;
  final String user;
  final bool useKey;

  /// Which Herdr session on that host: empty for the default one, or the
  /// name given to `herdr --session <name>`. Each session is its own server
  /// with its own socket, so one host can run several independent sets of
  /// agents and a phone can follow whichever it is pointed at.
  final String session;

  const Machine({
    required this.id,
    required this.label,
    required this.host,
    this.port = 22,
    required this.user,
    this.useKey = true,
    this.session = '',
  });

  /// Where the session's socket lives, relative to the user's home.
  ///
  /// Herdr keeps the default session at `.config/herdr/herdr.sock` and a
  /// named one under `.config/herdr/sessions/<name>/`. A name outside a
  /// conservative set is ignored rather than put into a path.
  String get socketSuffix {
    final name = session.trim();
    if (name.isEmpty ||
        name == 'default' ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) ||
        name.startsWith('.')) {
      return '.config/herdr/herdr.sock';
    }
    return '.config/herdr/sessions/$name/herdr.sock';
  }

  Machine copyWith({
    String? label,
    String? host,
    int? port,
    String? user,
    bool? useKey,
    String? session,
  }) =>
      Machine(
        id: id,
        label: label ?? this.label,
        host: host ?? this.host,
        port: port ?? this.port,
        user: user ?? this.user,
        useKey: useKey ?? this.useKey,
        session: session ?? this.session,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'port': port,
        'user': user,
        'useKey': useKey,
        'session': session,
      };

  factory Machine.fromJson(Map<String, dynamic> j) => Machine(
        id: j['id'] as String,
        label: (j['label'] as String?) ?? (j['host'] as String? ?? ''),
        host: (j['host'] as String?) ?? '',
        port: (j['port'] as num?)?.toInt() ?? 22,
        user: (j['user'] as String?) ?? '',
        useKey: j['useKey'] as bool? ?? true,
        session: (j['session'] as String?) ?? '',
      );

  String get display => label.isNotEmpty ? label : '$user@$host';
}

class MachineStore {
  static const _secure = FlutterSecureStorage();
  static const _listKey = 'machines';
  static const _activeKey = 'activeMachine';
  static const _themeKey = 'themeMode';
  static const _thinkingKey = 'showThinking';
  static const _toolsKey = 'showTools';
  static const _notifyKey = 'notifyAgents';
  static const _notifyModeKey = 'notifyMode';
  static const _quietKey = 'quietMinutes';
  static const _deviceKey = 'deviceId';

  Future<bool> showThinking() async =>
      (await SharedPreferences.getInstance()).getBool(_thinkingKey) ?? true;

  Future<bool> showTools() async =>
      (await SharedPreferences.getInstance()).getBool(_toolsKey) ?? true;

  /// 'off' | 'push' | 'poll'. Off by default: both modes cost something the
  /// user has to agree to — a permanent notification, or a token on the host.
  Future<String> notifyMode() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(_notifyModeKey);
    if (mode != null) return mode;
    // An older boolean setting: true means the in-app watcher.
    return (prefs.getBool(_notifyKey) ?? false) ? 'poll' : 'off';
  }

  /// Minutes of recent activity on the host that count as "you are there";
  /// 0 means always notify.
  Future<int> quietMinutes() async =>
      (await SharedPreferences.getInstance()).getInt(_quietKey) ?? 0;

  Future<void> setQuietMinutes(int minutes) async =>
      (await SharedPreferences.getInstance()).setInt(_quietKey, minutes);

  Future<void> setNotifyMode(String mode) async =>
      (await SharedPreferences.getInstance()).setString(_notifyModeKey, mode);

  /// A stable name for this install, so the token file it writes on the host
  /// is replaced rather than duplicated when the app is reinstalled.
  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = 'device-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await prefs.setString(_deviceKey, id);
    return id;
  }

  Future<void> setShowThinking(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_thinkingKey, v);

  Future<void> setShowTools(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_toolsKey, v);

  /// 'system' | 'light' | 'dark'. The system setting is not always reachable
  /// on every device, so the app carries its own override.
  Future<String> themeMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_themeKey) ?? 'system';
  }

  Future<void> setThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode);
  }

  Future<List<Machine>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_listKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => Machine.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(Machine machine) async {
    final all = await list();
    final i = all.indexWhere((m) => m.id == machine.id);
    if (i >= 0) {
      all[i] = machine;
    } else {
      all.add(machine);
    }
    await _write(all);
  }

  Future<void> delete(String id) async {
    final all = await list()
      ..removeWhere((m) => m.id == id);
    await _write(all);
    try {
      await _secure.delete(key: 'key_$id');
      await _secure.delete(key: 'pw_$id');
    } catch (_) {}
    if (await activeId() == id) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeKey);
    }
  }

  Future<void> _write(List<Machine> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _listKey, jsonEncode(all.map((m) => m.toJson()).toList()));
  }

  Future<String?> activeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey);
  }

  Future<void> setActive(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, id);
  }

  Future<Machine?> active() async {
    final all = await list();
    if (all.isEmpty) return null;
    final id = await activeId();
    for (final m in all) {
      if (m.id == id) return m;
    }
    return all.first;
  }

  Future<String?> privateKey(String id) => _read('key_$id');
  Future<String?> publicKey(String id) => _read('pub_$id');
  Future<String?> password(String id) => _read('pw_$id');

  Future<String?> _read(String key) async {
    try {
      return await _secure.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> setIdentity(String id, String privatePem, String publicLine) =>
      _writeSecret({'key_$id': privatePem, 'pub_$id': publicLine});

  Future<void> setPassword(String id, String password) =>
      _writeSecret({'pw_$id': password});

  Future<void> _writeSecret(Map<String, String> entries) async {
    for (final e in entries.entries) {
      try {
        await _secure.write(key: e.key, value: e.value);
      } catch (_) {}
    }
  }
}
