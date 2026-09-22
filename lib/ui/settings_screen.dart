import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../state/app_state.dart';
import '../state/watch.dart';
import 'design.dart';
import 'machines_screen.dart';

/// Everything that is a preference rather than a session, in one place.
class SettingsScreen extends StatefulWidget {
  final AppState state;
  final ThemeMode themeMode;
  final ValueChanged<String> onThemeChanged;

  const SettingsScreen({
    super.key,
    required this.state,
    required this.themeMode,
    required this.onThemeChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';
  String _updateStatus = '';
  bool _checking = false;
  WatchStatus? _watch;
  DateTime? _lastHeartbeat;
  int _watching = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    FlutterForegroundTask.addTaskDataCallback(_onWatcherData);
    _loadVersion();
    _loadWatchStatus();
  }

  /// Every poll the watcher makes reports back, so this screen can say the
  /// thing the switch cannot: that it is actually running, and when it last
  /// spoke to the host.
  void _onWatcherData(Object data) {
    if (data is! Map) return;
    final at = data['at'];
    if (at is! int) return;
    if (!mounted) return;
    setState(() {
      _lastHeartbeat = DateTime.fromMillisecondsSinceEpoch(at);
      _watching = (data['watching'] as int?) ?? _watching;
    });
  }

  Future<void> _loadWatchStatus() async {
    final status = await Watch.status();
    if (!mounted) return;
    setState(() => _watch = status);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    FlutterForegroundTask.removeTaskDataCallback(_onWatcherData);
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _version = '${info.version} · BUILD ${info.buildNumber}');
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _updateStatus = '';
    });
    await widget.state.checkForUpdate();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _updateStatus =
          widget.state.updateBuild == null ? 'UP TO DATE' : '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final state = widget.state;
    final pad = MediaQuery.of(context).size.width < 340 ? 12.0 : 16.0;

    return Scaffold(
      backgroundColor: d.ground,
      body: SafeArea(
        child: Column(
          children: [
            InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
                decoration: BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: d.divider, width: 2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.arrow_back, size: 15, color: d.ink3),
                      const SizedBox(width: 6),
                      Text(_version, style: d.label.copyWith(color: d.ink3)),
                    ]),
                    const SizedBox(height: 6),
                    Text('Settings', style: d.screenTitle),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(pad, 18, pad, 24),
                children: [
                  _sectionLabel(d, 'APPEARANCE'),
                  Row(
                    children: [
                      _themeOption(d, 'AUTO', ThemeMode.system, 'system'),
                      const SizedBox(width: 8),
                      _themeOption(d, 'LIGHT', ThemeMode.light, 'light'),
                      const SizedBox(width: 8),
                      _themeOption(d, 'DARK', ThemeMode.dark, 'dark'),
                    ],
                  ),
                  const SizedBox(height: 26),

                  _sectionLabel(d, 'TRANSCRIPT'),
                  _toggle(
                    d,
                    'Show chain of thought',
                    'Reasoning steps, when the agent records them. Pi writes '
                        'them; Claude Code does not, and Codex encrypts them.',
                    state.showThinking,
                    state.setShowThinking,
                  ),
                  _toggle(
                    d,
                    'Show tool calls',
                    'What the agent ran, listed under each turn.',
                    state.showTools,
                    state.setShowTools,
                  ),
                  const SizedBox(height: 26),

                  _sectionLabel(d, 'NOTIFICATIONS'),
                  Row(
                    children: [
                      _modeOption(d, state, 'OFF', 'off'),
                      const SizedBox(width: 8),
                      _modeOption(d, state, 'PUSH', 'push'),
                      const SizedBox(width: 8),
                      _modeOption(d, state, 'IN-APP', 'poll'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _modeDetail(state.notifyMode),
                    style: d.prose.copyWith(fontSize: 13, color: d.ink3),
                  ),
                  if (state.notifyMode == 'poll') ..._watchDetail(d),
                  if (state.notifyMode != 'off') ...[
                    const SizedBox(height: 18),
                    Text('NOT WHILE I AM AT THE COMPUTER',
                        style: d.label.copyWith(color: d.ink3)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (final minutes in const [0, 2, 5, 15]) ...[
                          if (minutes != 0) const SizedBox(width: 8),
                          _quietOption(d, state, minutes),
                        ],
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      state.quietMinutes == 0
                          ? 'Every agent that stops is worth telling you '
                              'about.'
                          : 'Stay quiet if the host saw a key or a click in '
                              'the last ${state.quietMinutes} minutes — you '
                              'are already watching it.',
                      style: d.prose.copyWith(fontSize: 13, color: d.ink3),
                    ),
                  ],
                  const SizedBox(height: 26),

                  _sectionLabel(d, 'HOSTS'),
                  _row(
                    d,
                    'Machines',
                    state.activeMachine?.display.toUpperCase() ?? 'NONE',
                    () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MachinesScreen(state: state),
                    )),
                  ),
                  const SizedBox(height: 26),

                  _sectionLabel(d, 'UPDATES'),
                  if (state.updateBuild != null)
                    _button(
                      d,
                      state.updating
                          ? state.updateLabel
                          : 'INSTALL BUILD ${state.updateBuild}',
                      state.updating
                          ? null
                          : () async {
                              final result = await state.installUpdate();
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(result)));
                            },
                      accent: true,
                      progress: state.updating ? state.updateProgress : null,
                    )
                  else
                    _button(
                      d,
                      _checking ? 'CHECKING…' : 'CHECK FOR UPDATES',
                      _checking ? null : _check,
                    ),
                  if (_updateStatus.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_updateStatus, style: d.label.copyWith(color: d.ink3)),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'Updates come from ~/.shepherd on the connected host, '
                    'over SSH.',
                    style: d.prose.copyWith(fontSize: 13, color: d.ink3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The two ways to be told, and what each costs.
  ///
  /// They are exclusive on purpose: with both running every finished agent
  /// arrives twice, once from the host and once from the phone.
  static String _modeDetail(String mode) => switch (mode) {
        'push' => 'Herdr tells this device directly when an agent finishes or '
            'needs an answer. Arrives with the app closed, after a reboot and '
            'while the phone sleeps, and costs no battery — but only while '
            'the host is awake.',
        'poll' => 'The app watches the host itself, every ten seconds, from a '
            'background service. Android shows a permanent notification while '
            'this runs and it costs battery. It stops if you force-quit the '
            'app or reboot.',
        _ => 'You will not be told when an agent stops.',
      };

  Widget _modeOption(D d, AppState state, String label, String mode) {
    final selected = state.notifyMode == mode;
    return Expanded(
      child: SizedBox(
        height: 44,
        child: Material(
          color: selected ? d.ink : Colors.transparent,
          shape: selected ? null : Border.all(color: d.divider, width: 2),
          child: InkWell(
            onTap: () async {
              await state.setNotifyMode(mode);
              await _loadWatchStatus();
            },
            child: Center(
              child: Text(label,
                  style:
                      d.label.copyWith(color: selected ? d.ground : d.ink2)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _quietOption(D d, AppState state, int minutes) {
    final selected = state.quietMinutes == minutes;
    return Expanded(
      child: SizedBox(
        height: 40,
        child: Material(
          color: selected ? d.ink : Colors.transparent,
          shape: selected ? null : Border.all(color: d.divider, width: 2),
          child: InkWell(
            onTap: () => state.setQuietMinutes(minutes),
            child: Center(
              child: Text(minutes == 0 ? 'ALWAYS' : '$minutes MIN',
                  style: d.label.copyWith(
                      fontSize: 12, color: selected ? d.ground : d.ink2)),
            ),
          ),
        ),
      ),
    );
  }

  /// Says what the watcher is doing, or what is stopping it.
  List<Widget> _watchDetail(D d) {
    final watch = _watch;
    final problem = watch?.problem;
    final heartbeat = _lastHeartbeat;
    return [
      const SizedBox(height: 4),
      if (problem != null)
        Text(problem, style: d.prose.copyWith(fontSize: 13, color: d.accentText))
      else if (heartbeat == null)
        Text('Waiting for the first check…',
            style: d.prose.copyWith(fontSize: 13, color: d.ink3))
      else
        Text(
          'Watching $_watching agents · checked '
          '${_ago(heartbeat)}',
          style: d.prose.copyWith(fontSize: 13, color: d.ink3),
        ),
    ];
  }

  static String _ago(DateTime at) {
    final seconds = DateTime.now().difference(at).inSeconds;
    if (seconds < 60) return '${seconds}s ago';
    final minutes = seconds ~/ 60;
    return minutes < 60 ? '${minutes}m ago' : '${minutes ~/ 60}h ago';
  }

  Widget _sectionLabel(D d, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: d.label),
      );

  Widget _themeOption(D d, String label, ThemeMode mode, String value) {
    final selected = widget.themeMode == mode;
    return Expanded(
      child: SizedBox(
        height: 44,
        child: Material(
          color: selected ? d.ink : Colors.transparent,
          shape: selected ? null : Border.all(color: d.divider, width: 2),
          child: InkWell(
            onTap: () => widget.onThemeChanged(value),
            child: Center(
              child: Text(label,
                  style: d.label
                      .copyWith(color: selected ? d.ground : d.ink2)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toggle(D d, String title, String detail, bool value,
          ValueChanged<bool> onChanged) =>
      InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: d.rowTitle),
                    const SizedBox(height: 3),
                    Text(detail,
                        style: d.prose.copyWith(fontSize: 13, color: d.ink3)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SquareToggle(value: value),
              ),
            ],
          ),
        ),
      );

  Widget _row(D d, String title, String trailing, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              Expanded(child: Text(title, style: d.rowTitle)),
              Text(trailing, style: d.label.copyWith(color: d.ink3)),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 18, color: d.ink3),
            ],
          ),
        ),
      );

  /// [progress] fills the button left to right as it runs — the button is
  /// the thing being waited on, so it is where the waiting belongs.
  Widget _button(D d, String label, VoidCallback? onTap,
          {bool accent = false, double? progress}) =>
      SizedBox(
        height: 48,
        width: double.infinity,
        child: Material(
          color: Colors.transparent,
          shape: Border.all(
              color: accent ? d.accentField : d.divider, width: 2),
          child: InkWell(
            onTap: onTap,
            child: Stack(
              children: [
                if (progress != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: progress.clamp(0.0, 1.0),
                      heightFactor: 1,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.linear,
                        color: (accent ? d.accentField : d.ink)
                            .withValues(alpha: 0.18),
                      ),
                    ),
                  ),
                Center(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: d.label.copyWith(
                          fontSize: 12,
                          color: accent ? d.accentText : d.ink)),
                ),
              ],
            ),
          ),
        ),
      );
}
