import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'dart:async';

import 'state/app_state.dart';
import 'state/push.dart';
import 'state/machines.dart';
import 'ui/sessions_screen.dart';
import 'ui/design.dart';

ThemeMode _parseThemeMode(String mode) => switch (mode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The background watcher talks to this isolate over a port; it has to exist
  // before the service can be started.
  FlutterForegroundTask.initCommunicationPort();
  // Best effort: without google-services.json this does nothing and the app
  // falls back to the in-app watcher.
  unawaited(Push.start());
  runApp(const ShepherdApp());
}

class ShepherdApp extends StatefulWidget {
  const ShepherdApp({super.key});

  @override
  State<ShepherdApp> createState() => _ShepherdAppState();
}

class _ShepherdAppState extends State<ShepherdApp> with WidgetsBindingObserver {
  final _state = AppState();
  final _store = MachineStore();
  ThemeMode _themeMode = ThemeMode.system;

  // Build-time host config, for driving a run without hand-entering a key:
  //   flutter run --dart-define-from-file=dev_config.json
  // A saved machine always wins over these.
  static const _envHost = String.fromEnvironment('SHEPHERD_HOST');
  static const _envUser = String.fromEnvironment('SHEPHERD_USER');
  static const _envKeyB64 = String.fromEnvironment('SHEPHERD_KEY_B64');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadTheme();
    _state.loadPreferences();
    _autoConnect();
  }

  /// Coming back from the background is the moment the displayed state is
  /// most likely to be stale, and the moment the user is looking at it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _state.touchActivity();
    if (state == AppLifecycleState.resumed) _state.refreshNow();
  }

  Future<void> _loadTheme() async {
    final mode = await _store.themeMode();
    if (!mounted) return;
    setState(() => _themeMode = _parseThemeMode(mode));
  }

  Future<void> _setTheme(String mode) async {
    await _store.setThemeMode(mode);
    if (!mounted) return;
    setState(() => _themeMode = _parseThemeMode(mode));
  }

  /// Reconnect to the active machine on launch so Chat is the first screen,
  /// not a setup form.
  Future<void> _autoConnect() async {
    try {
      final machine = await _store.active();
      if (machine != null) {
        await _state.connect(
          machine,
          privateKeyPem:
              machine.useKey ? await _store.privateKey(machine.id) : null,
          password: machine.useKey ? null : await _store.password(machine.id),
        );
        return;
      }
      if (_envHost.isEmpty || _envUser.isEmpty || _envKeyB64.isEmpty) return;
      final dev = Machine(
        id: 'dev',
        label: 'dev',
        host: _envHost,
        user: _envUser,
      );
      final pem =
          utf8.decode(base64.decode(_envKeyB64), allowMalformed: true);
      await _store.save(dev);
      await _store.setActive(dev.id);
      // Persist the identity too, or the next launch finds the machine but no
      // key and fails to authenticate.
      await _store.setIdentity(dev.id, pem, '');
      await _state.connect(dev, privateKeyPem: pem);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shepherd',
      debugShowCheckedModeBanner: false,
      theme: D.theme(Brightness.light),
      darkTheme: D.theme(Brightness.dark),
      themeMode: _themeMode,
      scrollBehavior: const NoStretchScrollBehavior(),
      home: SessionsScreen(
        state: _state,
        themeMode: _themeMode,
        onThemeChanged: _setTheme,
      ),
    );
  }
}
