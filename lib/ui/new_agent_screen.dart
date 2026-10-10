import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'agent_glyph.dart';
import 'design.dart';

/// Start an agent: a folder on the host, and which agent to run in it.
///
/// Folders agents already work in come first, since the next agent usually
/// joins one of them; below them the host's folders can be browsed from the
/// home folder down. Only agents installed on the host are offered.
class NewAgentScreen extends StatefulWidget {
  final AppState state;

  const NewAgentScreen({super.key, required this.state});

  @override
  State<NewAgentScreen> createState() => _NewAgentScreenState();
}

class _NewAgentScreenState extends State<NewAgentScreen> {
  String? _folder;
  String? _harness;
  List<String>? _installed;

  /// The chosen agent's models, null while they load; and the one picked,
  /// null for the agent's own default.
  List<ModelOption>? _models;
  ModelOption? _model;

  /// The folder being browsed and what is in it; null while it loads.
  ({String path, List<String> folders})? _listing;

  /// The home folder on the host: where browsing starts and stops, and what
  /// every path is shown relative to.
  String? _home;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _browse('');
    widget.state.installedHarnesses().then((found) {
      if (!mounted) return;
      setState(() {
        _installed = found;
      });
      if (found.length == 1) _choose(found.single);
    });
  }

  void _choose(String harness) {
    if (harness == _harness) return;
    setState(() {
      _harness = harness;
      _models = null;
      _model = null;
    });
    widget.state.listModels(harness).then((models) {
      if (!mounted || _harness != harness) return;
      setState(() => _models = models);
    });
  }

  Future<void> _browse(String path) async {
    setState(() => _listing = null);
    final listing = await widget.state.listFolders(path);
    if (!mounted) return;
    setState(() {
      _listing = listing ?? (path: path, folders: const []);
      // The first listing is of the home folder.
      if (path.isEmpty && listing != null) _home ??= listing.path;
    });
  }

  String _parent(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  /// A path as it reads from home: `~/work/cart`.
  String _short(String path) {
    final home = _home;
    if (home != null && (path == home || path.startsWith('$home/'))) {
      return '~${path.substring(home.length)}';
    }
    return path;
  }

  Future<void> _start() async {
    final folder = _folder, harness = _harness;
    if (folder == null || harness == null || _starting) return;
    setState(() => _starting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok =
        await widget.state.startAgent(folder, harness, model: _model?.id);
    if (!mounted) return;
    if (ok) {
      navigator.pop();
    } else {
      setState(() => _starting = false);
      messenger.showSnackBar(SnackBar(
          content: Text(widget.state.error ?? 'Could not start $harness')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final pad = MediaQuery.of(context).size.width < 340 ? 12.0 : 16.0;
    final recent = widget.state.agentFolders;
    final listing = _listing;
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
                      Text('NEW AGENT',
                          style: d.meta.copyWith(fontSize: 11, color: d.ink3)),
                    ]),
                    const SizedBox(height: 6),
                    Text(_folder == null ? 'Choose a folder' : _short(_folder!),
                        style: d.screenTitle),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _label(d, 'AGENT', pad),
                  _harnesses(d, pad),
                  _label(d, 'MODEL', pad),
                  _modelPulldown(d, pad),
                  if (recent.isNotEmpty) ...[
                    _label(d, 'WHERE AGENTS ARE WORKING', pad),
                    for (final folder in recent)
                      _folderRow(d, _short(folder), pad,
                          selected: folder == _folder,
                          onTap: () => setState(() => _folder = folder)),
                  ],
                  _label(d, 'BROWSE', pad),
                  if (listing == null)
                    Padding(
                      padding: EdgeInsets.all(pad),
                      child: Text('Reading the host…',
                          style: d.prose.copyWith(color: d.ink3)),
                    )
                  else ...[
                    _folderRow(d, _short(listing.path), pad,
                        selected: listing.path == _folder,
                        trailing: 'USE',
                        onTap: () => setState(() => _folder = listing.path)),
                    if (listing.path != '/' && listing.path != _home)
                      _folderRow(d, '..', pad,
                          onTap: () => _browse(_parent(listing.path))),
                    for (final name in listing.folders)
                      _folderRow(d, '$name/', pad,
                          onTap: () => _browse(listing.path == '/'
                              ? '/$name'
                              : '${listing.path}/$name')),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(pad, 8, pad, 12),
              child: SizedBox(
                height: 48,
                width: double.infinity,
                child: Material(
                  color: _folder != null && _harness != null
                      ? d.ink
                      : d.ink3,
                  child: InkWell(
                    key: const ValueKey('start-agent'),
                    onTap: _start,
                    child: Center(
                      child: Text(
                        _starting
                            ? 'STARTING…'
                            : _harness == null
                                ? 'CHOOSE AN AGENT'
                                : _folder == null
                                    ? 'CHOOSE A FOLDER'
                                    : 'START ${AgentGlyph.nameOf(_harness!).toUpperCase()}',
                        style: d.label.copyWith(fontSize: 13, color: d.ground),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A pull-down in the app's own square style.
  Widget _pulldown<T>(D d, double pad,
      {required Key key,
      required T? value,
      required List<DropdownMenuItem<T?>> items,
      required ValueChanged<T?>? onChanged,
      String? hint}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(border: Border.all(color: d.ink, width: 2)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T?>(
            key: key,
            value: value,
            isExpanded: true,
            itemHeight: null,
            dropdownColor: d.ground,
            icon: onChanged == null
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: d.ink3))
                : Icon(Icons.expand_more, color: d.ink),
            hint: hint == null
                ? null
                : Text(hint, style: d.rowTitle.copyWith(fontSize: 15, color: d.ink3)),
            disabledHint: hint == null
                ? null
                : Text(hint, style: d.rowTitle.copyWith(fontSize: 15, color: d.ink3)),
            items: items,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  Widget _modelPulldown(D d, double pad) {
    // On screen at once; usable when the list has arrived.
    final models = _models ?? const <ModelOption>[];
    final loading = _harness != null && _models == null;
    final idle = _harness == null;
    DropdownMenuItem<String?> item(String? id, String title, String detail,
            {bool enabled = true}) =>
        DropdownMenuItem<String?>(
          value: id,
          enabled: enabled,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: d.rowTitle.copyWith(fontSize: 15)),
                if (detail.isNotEmpty)
                  Text(detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: d.label.copyWith(color: d.ink3)),
              ],
            ),
          ),
        );
    return _pulldown<String>(
      d,
      pad,
      key: const ValueKey('model-pulldown'),
      value: loading || idle ? null : _model?.id,
      hint: idle
          ? 'Choose an agent first'
          : loading
              ? 'Loading models…'
              : null,
      items: loading || idle
          ? const []
          : [
        item(null, 'Default', 'Whatever ${AgentGlyph.nameOf(_harness!)} is set to use'),
        for (final m in models)
          item(m.id, m.label,
              m.detail.isEmpty || m.detail == m.label ? m.id : m.detail),
      ],
      onChanged: loading || idle
          ? null
          : (id) => setState(() => _model =
              id == null ? null : models.firstWhere((m) => m.id == id)),
    );
  }

  Widget _label(D d, String text, double pad) => Padding(
        padding: EdgeInsets.fromLTRB(pad, 20, pad, 8),
        child: Text(text, style: d.label.copyWith(color: d.ink3)),
      );

  Widget _harnesses(D d, double pad) {
    final installed = _installed;
    final loading = installed == null;
    return _pulldown<String>(
      d,
      pad,
      key: const ValueKey('agent-pulldown'),
      value: _harness,
      hint: loading
          ? 'Looking for agents…'
          : installed.isEmpty
              ? 'No agent found on the host'
              : 'Choose an agent',
      items: [
        for (final h in installed ?? const <String>[])
          DropdownMenuItem<String?>(
            value: h,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                AgentGlyph(agent: h, size: 16),
                const SizedBox(width: 10),
                Text(AgentGlyph.nameOf(h),
                    style: d.rowTitle.copyWith(fontSize: 15)),
              ]),
            ),
          ),
      ],
      onChanged: loading || installed.isEmpty
          ? null
          : (h) {
              if (h != null) _choose(h);
            },
    );
  }

  Widget _folderRow(D d, String text, double pad,
          {bool selected = false, String? trailing, required VoidCallback onTap}) =>
      InkWell(
        onTap: onTap,
        child: Container(
          color: selected ? d.fill : null,
          padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
          child: Row(children: [
            Icon(selected ? Icons.check : Icons.folder_outlined,
                size: 18, color: selected ? d.ink : d.ink3),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: d.rowTitle.copyWith(fontSize: 15)),
            ),
            if (trailing != null)
              Text(trailing, style: d.label.copyWith(color: d.ink2)),
          ]),
        ),
      );
}
