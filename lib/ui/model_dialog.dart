import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'design.dart';

/// What was chosen: a model, an effort, or both; null keeps that one.
class ModelChoice {
  final ModelOption? model;
  final String? effort;

  const ModelChoice({this.model, this.effort});
}

/// Pick another model for a running agent, another effort, or both.
///
/// Both pull-downs are there from the start and begin on what the agent runs
/// now; the models arrive when the agent has listed them. The efforts are
/// those of the model chosen, or of the one in use.
class ModelDialog extends StatefulWidget {
  final String? agent;
  final Future<List<ModelOption>> models;
  final String? currentModel;
  final String? currentEffort;

  const ModelDialog({
    super.key,
    required this.agent,
    required this.models,
    this.currentModel,
    this.currentEffort,
  });

  @override
  State<ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<ModelDialog> {
  List<ModelOption>? _models;
  ModelOption? _model;
  String? _effort;

  @override
  void initState() {
    super.initState();
    widget.models.then((found) {
      if (mounted) setState(() => _models = found);
    });
  }

  /// The listed model the agent runs now, when it can be told: the
  /// transcript names it in full, the list sometimes by alias.
  ModelOption? get _running {
    final now = widget.currentModel;
    if (now == null || now.isEmpty) return null;
    for (final m in _models ?? const <ModelOption>[]) {
      if (m.id == now || m.label == now || m.id.endsWith('/$now')) return m;
    }
    return null;
  }

  List<String> get _efforts {
    final chosen = _model;
    if (chosen != null) return chosen.efforts;
    return _running?.efforts ??
        AppState.effortsFor(widget.agent, _models ?? const []);
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final models = _models;
    final efforts = _efforts;
    final running = widget.currentModel ?? '';
    final effortNow = widget.currentEffort;
    return AlertDialog(
      backgroundColor: d.ground,
      title: Text('Model and effort', style: d.rowTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('MODEL', style: d.label.copyWith(color: d.ink3)),
            const SizedBox(height: 6),
            _pulldown<ModelOption>(
              d,
              key: const ValueKey('model-choice'),
              value: _model,
              loading: models == null,
              items: [
                _item(d, null,
                    running.isEmpty ? 'As it is' : 'Keep $running', ''),
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
                _item(d, null,
                    effortNow == null ? 'As it is' : 'Keep $effortNow', ''),
                for (final e in efforts) _item(d, e, e, ''),
              ],
              onChanged: efforts.isEmpty
                  ? null
                  : (e) => setState(() => _effort = e),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        TextButton(
          key: const ValueKey('model-switch'),
          onPressed: _model == null && _effort == null
              ? null
              : () => Navigator.of(context)
                  .pop(ModelChoice(model: _model, effort: _effort)),
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
