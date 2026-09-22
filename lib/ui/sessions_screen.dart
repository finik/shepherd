import 'package:flutter/material.dart';

import '../herdr/models.dart';
import '../state/app_state.dart';
import 'agent_glyph.dart';
import 'chat_screen.dart';
import 'design.dart';
import 'machines_screen.dart';
import 'settings_screen.dart';

/// Home. Answers "is anything waiting on me?" in one frame.
///
/// Opening on the list rather than the last conversation is deliberate: the
/// glance is the most frequent job, and it's the only one a screen can answer
/// without reading.
class SessionsScreen extends StatefulWidget {
  final AppState state;
  final ThemeMode themeMode;
  final ValueChanged<String> onThemeChanged;

  const SessionsScreen({
    super.key,
    required this.state,
    this.themeMode = ThemeMode.system,
    required this.onThemeChanged,
  });

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  void _openPane(Pane pane) {
    widget.state.selectPane(pane.paneId);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(state: widget.state),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final state = widget.state;
    final width = MediaQuery.of(context).size.width;
    final sidePad = width < 340 ? 12.0 : 16.0;

    final panes = state.host.agentPanes;
    final blocked = panes.where((p) => p.agentStatus == 'blocked').toList();
    final working = panes.where((p) => p.agentStatus == 'working').toList();
    final done = panes.where((p) => p.agentStatus == 'done').toList();
    final quiet = panes
        .where((p) => !const {'blocked', 'working', 'done'}
            .contains(p.agentStatus))
        .toList();

    return Scaffold(
      backgroundColor: d.ground,
      body: SafeArea(
        child: Column(
          children: [
            _header(d, state, sidePad, panes.length),
            // A connection that dropped while the app was away is being got
            // back; the agents it last showed are still the best thing to
            // look at. Only with nothing to show, or once it has truly
            // failed with nothing to show, does the screen become about the
            // connection itself.
            if (state.conn == ConnState.failed && panes.isNotEmpty)
              _lostStrip(d, state, sidePad),
            Expanded(
              child: state.conn != ConnState.connected && panes.isEmpty
                  ? _connectionState(d, state, sidePad)
                  : ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        // The field is the reason the screen exists. Its
                        // absence is itself the answer to "anything waiting?".
                        if (blocked.isNotEmpty)
                          _blockedField(d, blocked.first, sidePad),
                        _group(d, 'WAITING ON YOU', blocked, sidePad,
                            skipFirst: true),
                        _group(d, 'WORKING', working, sidePad),
                        _group(d, 'FINISHED SINCE YOU LOOKED', done, sidePad),
                        _group(d, 'QUIET', quiet, sidePad),
                        const SizedBox(height: 8),
                      ],
                    ),
            ),
            _footer(d, state, sidePad),
          ],
        ),
      ),
    );
  }

  Widget _header(D d, AppState state, double pad, int count) {
    final machine = state.activeMachine?.display;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 14, pad, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: Text('SHEPHERD', style: d.label.copyWith(
              fontSize: 13, color: d.ink, letterSpacing: 0.14 * 13))),
          Text(
            switch (state.conn) {
              ConnState.connected => '$count AGENT${count == 1 ? '' : 'S'}',
              // Same corner, same size: saying so costs no layout.
              ConnState.connecting when count > 0 => 'RECONNECTING',
              ConnState.idle when count > 0 => 'RECONNECTING',
              _ => (machine ?? '').toUpperCase(),
            },
            style: d.label,
          ),
        ],
      ),
    );
  }

  /// A blocked agent gets accent-filled screen, the question verbatim, and two
  /// actions where the thumb already is. Nothing else in the app is ever
  /// filled with accent.
  Widget _blockedField(D d, Pane pane, double pad) {
    final question = widget.state.blockedPrompt(pane.paneId);
    return Container(
      width: double.infinity,
      color: d.accentField,
      padding: EdgeInsets.fromLTRB(pad, 18, pad, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WAITING ON YOU',
              style: d.label.copyWith(color: Colors.white.withValues(alpha: 0.85))),
          const SizedBox(height: 10),
          Text(pane.sessionName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: d.rowTitle.copyWith(color: Colors.white, fontSize: 17)),
          const SizedBox(height: 6),
          Text(
            question?.question.isNotEmpty == true
                ? question!.question
                : 'Waiting for your answer.',
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: D.mono,
                fontSize: 12.5,
                height: 19 / 12.5,
                color: Colors.white.withValues(alpha: 0.92)),
          ),
          const SizedBox(height: 14),
          // Stack the actions when the labels can't both hold at 13px.
          LayoutBuilder(builder: (context, c) {
            final stack = c.maxWidth < 260;
            final children = [
              _fieldButton('ANSWER', () => _openPane(pane), primary: true),
              SizedBox(width: stack ? 0 : 8, height: stack ? 8 : 0),
              _fieldButton('STOP', () => widget.state.stopPane(pane.paneId)),
            ];
            return stack
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children)
                : Row(children: [
                    Expanded(child: children[0]),
                    children[1],
                    Expanded(child: children[2]),
                  ]);
          }),
        ],
      ),
    );
  }

  Widget _fieldButton(String label, VoidCallback onTap, {bool primary = false}) {
    return SizedBox(
      height: 48,
      child: Material(
        color: primary ? Colors.white : Colors.transparent,
        shape: primary
            ? null
            : Border.all(color: Colors.white.withValues(alpha: 0.6), width: 2),
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Text(label,
                style: TextStyle(
                  fontFamily: D.mono,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.12 * 13,
                  color: primary ? const Color(0xFFAE1800) : Colors.white,
                )),
          ),
        ),
      ),
    );
  }

  Widget _group(D d, String title, List<Pane> panes, double pad,
      {bool skipFirst = false}) {
    final rows = skipFirst && panes.isNotEmpty ? panes.sublist(1) : panes;
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: ValueKey('group-$title'),
          height: 30,
          color: d.fill,
          padding: EdgeInsets.symmetric(horizontal: pad),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Expanded(child: Text(title, style: d.label)),
              Text('${rows.length}', style: d.label),
            ],
          ),
        ),
        ...rows.map((p) => AgentRow(
              pane: p,
              sidePad: pad,
              preview: widget.state.preview(p.paneId),
              onTap: () => _openPane(p),
              onStop: p.isWorking || p.isBlocked
                  ? () => _confirmStop(p)
                  : null,
            )),
      ],
    );
  }

  /// A connection that could not be got back, over a list that is still
  /// worth reading — it is the last thing the host said.
  Widget _lostStrip(D d, AppState state, double pad) => InkWell(
        onTap: () => state.reconnect(),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(pad, 10, pad, 10),
          color: d.divider,
          child: Text('CONNECTION LOST · TAP TO RETRY',
              style: d.label.copyWith(color: d.ink2)),
        ),
      );

  Widget _connectionState(D d, AppState state, double pad) {
    final (title, body, action) = switch (state.conn) {
      ConnState.connecting => (
          'CONNECTING',
          'Opening a session on ${state.activeMachine?.display ?? 'the host'}.',
          null,
        ),
      ConnState.failed => (
          'CONNECTION FAILED',
          state.error ?? 'The host did not answer.',
          ('RETRY', () => state.reconnect()),
        ),
      _ => (
          'NO MACHINE',
          'Nothing to shepherd yet. Add the host that runs Herdr.',
          ('ADD MACHINE', () => _openMachines()),
        ),
    };
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: d.label.copyWith(color: d.ink)),
          const SizedBox(height: 10),
          Text(body, style: d.prose.copyWith(color: d.ink2)),
          if (action != null) ...[
            const SizedBox(height: 20),
            _outlineButton(d, action.$1, action.$2),
          ],
        ],
      ),
    );
  }

  Widget _outlineButton(D d, String label, VoidCallback onTap) => SizedBox(
        height: 48,
        child: Material(
          color: Colors.transparent,
          shape: Border.all(color: d.ink, width: 2),
          child: InkWell(
            onTap: onTap,
            child: Center(
                child: Text(label,
                    style: d.label.copyWith(fontSize: 13, color: d.ink))),
          ),
        ),
      );

  void _openMachines() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MachinesScreen(state: widget.state),
    ));
  }

  Widget _footer(D d, AppState state, double pad) {
    final machine = state.activeMachine;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: d.divider, width: 2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: _openMachines,
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, 12, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('MACHINES', style: d.label.copyWith(color: d.ink)),
                    const SizedBox(height: 4),
                    Text(
                      machine == null
                          ? 'NONE'
                          : '${machine.display.toUpperCase()} · '
                              '${state.conn == ConnState.connected ? 'ONLINE' : 'OFFLINE'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: d.label.copyWith(color: d.ink3),
                    ),
                  ],
                ),
              ),
            ),
          ),
          InkWell(
            onTap: _openSettings,
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 14, pad, 14),
              child: Icon(Icons.settings_outlined, size: 22, color: d.ink),
            ),
          ),
        ],
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(
        state: widget.state,
        themeMode: widget.themeMode,
        onThemeChanged: widget.onThemeChanged,
      ),
    ));
  }

  Future<void> _confirmStop(Pane p) async {
    final d = D.of(context);
    final stop = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: d.ground,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
              child: Text(p.sessionName, style: d.rowTitle),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Text('Sends ESC to the pane.',
                  style: d.prose.copyWith(fontSize: 14, color: d.ink2)),
            ),
            ListTile(
              title: Text('STOP AGENT',
                  style: d.label.copyWith(fontSize: 13, color: d.accentText)),
              onTap: () => Navigator.of(context).pop(true),
            ),
            ListTile(
              title: Text('CANCEL', style: d.label.copyWith(fontSize: 13)),
              onTap: () => Navigator.of(context).pop(false),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (stop == true) await widget.state.stopPane(p.paneId);
  }
}

/// Four facts, two lines, one hit target.
class AgentRow extends StatelessWidget {
  final Pane pane;
  final double sidePad;
  final VoidCallback onTap;
  final VoidCallback? onStop;
  final String? preview;

  const AgentRow({
    super.key,
    required this.pane,
    required this.sidePad,
    required this.onTap,
    this.onStop,
    this.preview,
  });

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final quiet = pane.agentStatus != 'working' &&
        pane.agentStatus != 'blocked' &&
        pane.agentStatus != 'done';
    final isPreview = preview != null && preview!.isNotEmpty;
    final secondLine = isPreview
        ? preview
        : (pane.hasMeaningfulTitle ? '~/${pane.shortCwd}' : null);
    return InkWell(
      onTap: onTap,
      onLongPress: onStop,
      child: Padding(
        padding: EdgeInsets.fromLTRB(sidePad, 12, sidePad, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              height: 26,
              child: Align(
                alignment: Alignment.centerLeft,
                child: AgentGlyph(agent: pane.agent, size: 18),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pane.sessionName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: quiet
                        ? d.rowTitleQuiet
                        : (pane.agentStatus == 'blocked'
                            ? d.rowTitle.copyWith(color: d.accentText)
                            : d.rowTitle),
                  ),
                  // What it last said beats where it lives — you already know
                  // the folder, it is the row's title.
                  if (secondLine != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      secondLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: isPreview
                          ? d.prose.copyWith(fontSize: 13, color: d.ink3)
                          : d.meta.copyWith(fontSize: 11, color: d.ink3),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusIcon(status: pane.agentStatus),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
