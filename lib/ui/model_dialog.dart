import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'agent_glyph.dart';
import 'design.dart';

/// What was chosen: another agent, a model, an effort; null keeps that one.
class ModelChoice {
  /// Set when the choice is another agent, which replaces the running one.
  final String? harness;
  final ModelOption? model;
  final String? effort;

  const ModelChoice({this.harness, this.model, this.effort});

  bool get isEmpty => harness == null && model == null && effort == null;
}

/// Pick another model for a running agent, another effort, or another agent
/// altogether.
///
/// All three pull-downs are there from the start and begin on what runs now;
/// lists arrive as the host answers. Another agent's models and efforts are
/// its own, and picking it starts that agent in place of this one.
class ModelDialog extends StatefulWidget {
  final AppState state;
  final String? agent;
  final String? currentModel;
  final String? currentEffort;

  const ModelDialog({
    super.key,
    required this.state,
    required this.agent,
    this.currentModel,
    this.currentEffort,
  });

  @override
  State<ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<ModelDialog> {
  List<String>? _installed;
  late String? _harness = widget.agent;
  final Map<String, List<ModelOption>> _models = {};
  ModelOption? _model;
  String? _effort;

  bool get _other => _harness != null && _harness != widget.agent;

  @override
  void initState() {
    super.initState();
    widget.state.installedHarnesses().then((found) {
      if (mounted) setState(() => _installed = found);
    });
    _loadModels(widget.agent);
  }

  void _loadModels(String? harness) {
    if (harness == null || _models.containsKey(harness)) return;
    widget.state.listModels(harness).then((found) {
      if (mounted) setState(() => _models[harness] = found);
    });
  }

  List<ModelOption>? get _list => _harness == null ? null : _models[_harness];

  /// The listed model the agent runs now, when it can be told: the
  /// transcript names it in full, the list sometimes by alias.
  ModelOption? get _running {
    final now = widget.currentModel;
    if (_other || now == null || now.isEmpty) return null;
    for (final m in _list ?? const <ModelOption>[]) {
      if (m.id == now || m.label == now || m.id.endsWith('/$now')) return m;
    }
    return null;
  }

  List<String> get _efforts {
    final chosen = _model;
    if (chosen != null) return chosen.efforts;
    return _running?.efforts ??
        AppState.effortsFor(_harness, _list ?? const []);
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final models = _list;
    final efforts = _efforts;
    final running = widget.currentModel ?? '';
    final effortNow = widget.currentEffort;
    final installed = _installed;
    return AlertDialog(
      backgroundColor: d.ground,
      title: Text('Agent, model and effort', style: d.rowTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('AGENT', style: d.label.copyWith(color: d.ink3)),
              const SizedBox(height: 6),
              _pulldown<String>(
                d,
                key: const ValueKey('agent-choice'),
                value: _harness,
                loading: installed == null,
                items: [
                  for (final h in {
                    ?widget.agent,
                    ...?installed,
                  })
                    DropdownMenuItem<String?>(
                      value: h,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(children: [
                          AgentGlyph(agent: h, size: 16),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                                '${AgentGlyph.nameOf(h)}'
                                '${h == widget.agent ? '  ·  running' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: d.rowTitle.copyWith(fontSize: 15)),
                          ),
                        ]),
                      ),
                    ),
                ],
                onChanged: (h) => setState(() {
                  if (h == null || h == _harness) return;
                  _harness = h;
                  _model = null;
                  _effort = null;
                  _loadModels(h);
                }),
              ),
              if (_other)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      'Starts ${AgentGlyph.nameOf(_harness!)} here in place of '
                      '${AgentGlyph.nameOf(widget.agent!)}. The conversation '
                      'so far stays in its transcript; the new agent starts '
                      'without it.',
                      style: d.label.copyWith(color: d.ink3)),
                ),
              const SizedBox(height: 16),
              Text('MODEL', style: d.label.copyWith(color: d.ink3)),
              const SizedBox(height: 6),
              _pulldown<ModelOption>(
                d,
                key: const ValueKey('model-choice'),
                value: _model,
                loading: models == null,
                items: [
                  _item(
                      d,
                      null,
                      _other
                          ? 'Default'
                          : running.isEmpty
                              ? 'As it is'
                              : 'Keep $running',
                      _other ? 'Whatever ${AgentGlyph.nameOf(_harness!)} is set to use' : ''),
                  for (final m in models ?? const <ModelOption>[])
                    _item(d, m, m.label,
                        m.detail.isEmpty || m.detail == m.label ? m.id : m.detail),
                ],
                onChanged: (m) => setState(() {
                  _model = m;
                  if (_effort != null && !_efforts.contains(_effort)) {
                    _effort = null;
                  }
                }),
              ),
              const SizedBox(height: 16),
              Text('EFFORT', style: d.label.copyWith(color: d.ink3)),
              const SizedBox(height: 6),
              _pulldown<String>(
                d,
                key: const ValueKey('effort-choice'),
                value: _effort,
                loading: models == null && _model == null && efforts.isEmpty,
                hint: efforts.isEmpty ? 'This model has no effort setting' : null,
                items: [
                  _item(
                      d,
                      null,
                      _other
                          ? 'Default'
                          : effortNow == null
                              ? 'As it is'
                              : 'Keep $effortNow',
                      ''),
                  for (final e in efforts) _item(d, e, e, ''),
                ],
                onChanged: efforts.isEmpty
                    ? null
                    : (e) => setState(() => _effort = e),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        TextButton(
          key: const ValueKey('model-switch'),
          onPressed: !_other && _model == null && _effort == null
              ? null
              : () => Navigator.of(context).pop(ModelChoice(
                  harness: _other ? _harness : null,
                  model: _model,
                  effort: _effort)),
          child: const Text('SWITCH'),
        ),
      ],
    );
  }

  DropdownMenuItem<T?> _item<T>(D d, T? value, String title, String detail) =>
      DropdownMenuItem<T?>(
        value: value,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: d.rowTitle.copyWith(fontSize: 15)),
              if (detail.isNotEmpty)
                Text(detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: d.label.copyWith(color: d.ink3)),
            ],
          ),
        ),
      );

  /// A pull-down in the app's own square style; a spinner while its list
  /// is on its way.
  Widget _pulldown<T>(D d,
      {required Key key,
      required T? value,
      required List<DropdownMenuItem<T?>> items,
      required ValueChanged<T?>? onChanged,
      bool loading = false,
      String? hint}) {
    final enabled = onChanged != null && !loading;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(border: Border.all(color: d.ink, width: 2)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T?>(
          key: key,
          value: value,
          isExpanded: true,
          itemHeight: null,
          dropdownColor: d.ground,
          icon: loading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: d.ink3))
              : Icon(Icons.expand_more, color: enabled ? d.ink : d.ink3),
          disabledHint: hint == null
              ? null
              : Text(hint,
                  style: d.rowTitle.copyWith(fontSize: 15, color: d.ink3)),
          items: items,
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }
}
