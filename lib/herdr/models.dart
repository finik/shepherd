/// Herdr session topology, as returned by `session.snapshot`.
class HostState {
  final List<Workspace> workspaces;
  final List<TabInfo> tabs;
  final List<Pane> panes;
  final List<Pane> agents;
  final String? focusedWorkspaceId;
  final String? focusedTabId;
  final String? focusedPaneId;

  const HostState({
    this.workspaces = const [],
    this.tabs = const [],
    this.panes = const [],
    this.agents = const [],
    this.focusedWorkspaceId,
    this.focusedTabId,
    this.focusedPaneId,
  });

  factory HostState.fromSnapshot(Map<String, dynamic> snap) {
    // The `agents` array repeats the agent-hosting panes and adds
    // `state_change_seq` — the only recency signal Herdr gives us, and what
    // orders rows within a group.
    final panes = (snap['panes'] as List? ?? [])
        .map((e) => Pane.fromJson(e as Map<String, dynamic>))
        .toList();
    // The two arrays describe the same panes and disagree about what they
    // carry: only `agents` has state_change_seq, and only `panes` has the
    // label you set. Take each from whichever side has it.
    final labels = {
      for (final p in panes)
        if ((p.label ?? '').isNotEmpty) p.paneId: p.label!
    };
    final agents = (snap['agents'] as List? ?? [])
        .map((e) => Pane.fromJson(e as Map<String, dynamic>))
        .map((p) => labels.containsKey(p.paneId)
            ? p.withLabel(labels[p.paneId]!)
            : p)
        .toList();
    return HostState(
      agents: agents,
      workspaces: (snap['workspaces'] as List? ?? [])
          .map((e) => Workspace.fromJson(e as Map<String, dynamic>))
          .toList(),
      tabs: (snap['tabs'] as List? ?? [])
          .map((e) => TabInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
      panes: panes,
      focusedWorkspaceId: snap['focused_workspace_id'] as String?,
      focusedTabId: snap['focused_tab_id'] as String?,
      focusedPaneId: snap['focused_pane_id'] as String?,
    );
  }

  Pane? get focusedPane => paneById(focusedPaneId);

  Pane? paneById(String? id) {
    if (id == null) return null;
    for (final p in panes) {
      if (p.paneId == id) return p;
    }
    return null;
  }

  List<TabInfo> tabsOf(String workspaceId) =>
      tabs.where((t) => t.workspaceId == workspaceId).toList();

  List<Pane> panesOf(String tabId) =>
      panes.where((p) => p.tabId == tabId).toList();

  /// Agent-hosting panes, ordered the way Sessions reads them: whatever needs
  /// a human first, and most-recently-changed first within each state.
  List<Pane> get agentPanes {
    final list = agents.isNotEmpty
        ? List<Pane>.from(agents)
        : panes.where((p) => p.agent != null).toList();
    list.sort((a, b) {
      final byState = a.statusRank.compareTo(b.statusRank);
      return byState != 0 ? byState : b.stateSeq.compareTo(a.stateSeq);
    });
    return list;
  }
}

class Workspace {
  final String workspaceId;
  final String label;
  final String? agentStatus;
  final int paneCount;
  final bool focused;

  const Workspace({
    required this.workspaceId,
    required this.label,
    this.agentStatus,
    this.paneCount = 0,
    this.focused = false,
  });

  factory Workspace.fromJson(Map<String, dynamic> j) => Workspace(
        workspaceId: j['workspace_id'] as String,
        label: (j['label'] as String?) ?? (j['workspace_id'] as String),
        agentStatus: j['agent_status'] as String?,
        paneCount: (j['pane_count'] as num?)?.toInt() ?? 0,
        focused: j['focused'] as bool? ?? false,
      );
}

class TabInfo {
  final String tabId;
  final String workspaceId;
  final String label;
  final bool focused;

  const TabInfo({
    required this.tabId,
    required this.workspaceId,
    required this.label,
    this.focused = false,
  });

  factory TabInfo.fromJson(Map<String, dynamic> j) => TabInfo(
        tabId: j['tab_id'] as String,
        workspaceId: j['workspace_id'] as String,
        label: (j['label'] as String?) ?? '',
        focused: j['focused'] as bool? ?? false,
      );
}

class Pane {
  final String paneId;
  final String tabId;
  final String workspaceId;
  final String? agent;
  final String? agentStatus;
  final String? cwd;
  final String? title;

  /// A name you gave this pane, which Herdr keeps. It outranks the terminal
  /// title because the title is whatever the program in the pane last wrote —
  /// Pi rewrites it as the session goes on, and a session called "ledger"
  /// can end up called "Downloads,-read-it · Off".
  final String? label;
  final AgentSession? agentSession;
  final bool focused;

  /// Monotonic counter of when this agent's state last changed. Only the
  /// snapshot's `agents` entries carry it; plain panes report 0.
  final int stateSeq;

  const Pane({
    required this.paneId,
    required this.tabId,
    required this.workspaceId,
    this.agent,
    this.agentStatus,
    this.cwd,
    this.title,
    this.label,
    this.agentSession,
    this.focused = false,
    this.stateSeq = 0,
  });

  factory Pane.fromJson(Map<String, dynamic> j) => Pane(
        paneId: j['pane_id'] as String,
        tabId: (j['tab_id'] as String?) ?? '',
        workspaceId: (j['workspace_id'] as String?) ?? '',
        agent: j['agent'] as String?,
        agentStatus: j['agent_status'] as String?,
        cwd: j['cwd'] as String?,
        title: (j['title'] ??
            j['terminal_title_stripped'] ??
            j['terminal_title']) as String?,
        label: j['label'] as String?,
        agentSession: j['agent_session'] == null
            ? null
            : AgentSession.fromJson(j['agent_session'] as Map<String, dynamic>),
        focused: j['focused'] as bool? ?? false,
        stateSeq: (j['state_change_seq'] as num?)?.toInt() ?? 0,
      );

  Pane withLabel(String value) => Pane(
        paneId: paneId,
        tabId: tabId,
        workspaceId: workspaceId,
        agent: agent,
        agentStatus: agentStatus,
        cwd: cwd,
        title: title,
        label: value,
        agentSession: agentSession,
        focused: focused,
        stateSeq: stateSeq,
      );

  Pane withStatus(String value) => Pane(
        paneId: paneId,
        tabId: tabId,
        workspaceId: workspaceId,
        agent: agent,
        agentStatus: value,
        cwd: cwd,
        title: title,
        label: label,
        agentSession: agentSession,
        focused: focused,
        stateSeq: stateSeq,
      );

  bool get isWorking => agentStatus == 'working';
  bool get isBlocked => agentStatus == 'blocked';

  int get statusRank => switch (agentStatus) {
        'blocked' => 0,
        'working' => 1,
        'done' => 2,
        'idle' => 3,
        _ => 4,
      };

  /// Words an agent puts in its title to say what state it is in, which the
  /// row already shows as a group and a marker.
  static const _statusWords = {
    'actionrequired',
    'working',
    'thinking',
    'waiting',
    'idle',
    'done',
    'ready',
  };

  /// The agent's title with the noise taken out.
  ///
  /// Agents name sessions inconsistently and often redundantly — Pi emits
  /// "π - ledger - ledger", which is the agent glyph plus the folder
  /// twice. Split on separators, drop anything that only repeats the agent or
  /// the location, and keep whatever actually says something.
  String get _cleanTitle {
    final raw = title?.trim();
    if (raw == null || raw.isEmpty) return '';
    String norm(String v) =>
        v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final folder = norm(shortCwd);
    final agentName = norm(agent ?? '');
    // "HA-Dashboard" for ~/ha-dashboard is one name, not two segments, so
    // settle whole-title duplication before splitting anything.
    if (norm(raw) == folder) return '';
    final seen = <String>{};
    final kept = <String>[];
    // Only spaced separators divide segments; hyphens inside a word do not.
    for (final part in raw.split(RegExp(r'\s+[-·|—>!]\s+'))) {
      // Codex puts its own state at the front of the title while it waits —
      // "[ . ] Action Required | Describe tool/publish.sh". The row already
      // says the agent is waiting, in red; the title should stay the name.
      final piece = part.trim().replaceFirst(RegExp(r'^\[[^\]]{0,4}\]\s*'), '');
      if (piece.isEmpty) continue;
      final key = norm(piece);
      if (_statusWords.contains(key)) continue;
      // A leading glyph normalises to nothing; so does pure punctuation.
      if (key.isEmpty) continue;
      if (key == folder || key == agentName) continue;
      if (_agentShortNames[agent]?.contains(key) ?? false) continue;
      if (!seen.add(key)) continue;
      kept.add(piece);
    }
    return kept.join(' · ');
  }

  /// Session titles an agent keeps outside the terminal, by session id.
  /// OpenCode stores the full title in its database and writes only a
  /// truncated copy into the terminal title.
  static final Map<String, String> sessionTitles = {};

  /// What an agent calls itself at the front of its title: OpenCode writes
  /// "OC | `title`".
  static const _agentShortNames = {
    'opencode': {'oc'},
  };

  bool get hasMeaningfulTitle => _cleanTitle.isNotEmpty;

  /// What the agent named this session, or where it is working when the name
  /// carries nothing extra.
  String get sessionName {
    final named = label?.trim();
    if (named != null && named.isNotEmpty) return named;
    final kept = sessionTitles[agentSession?.value];
    if (kept != null && kept.isNotEmpty) return kept;
    final cleaned = _cleanTitle;
    return cleaned.isEmpty ? shortCwd : cleaned;
  }

  /// Last path segment of the cwd — what the drawer and header show.
  String get shortCwd {
    final c = cwd;
    if (c == null || c.isEmpty) return paneId;
    final parts = c.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? c : parts.last;
  }
}

/// Herdr resolves the agent's transcript location itself; `kind` says whether
/// [value] is already a path or a session id we still have to locate.
class AgentSession {
  final String agent;
  final String kind;
  final String value;

  const AgentSession({
    required this.agent,
    required this.kind,
    required this.value,
  });

  factory AgentSession.fromJson(Map<String, dynamic> j) => AgentSession(
        agent: (j['agent'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? '',
        value: (j['value'] as String?) ?? '',
      );

  bool get isPath => kind == 'path';
}
