import 'package:flutter/material.dart';

import '../transcript/turn.dart';
import 'design.dart';

/// Everything one turn did, in the order it did it.
///
/// The ledger line in the thread is a summary and stays one; auditing what an
/// agent actually did needs the whole run at full length, which is a screen's
/// worth of reading, not an inline disclosure inside the conversation.
class TurnDetailScreen extends StatelessWidget {
  final Turn turn;
  final bool showThinking;
  final bool showTools;

  const TurnDetailScreen({
    super.key,
    required this.turn,
    required this.showThinking,
    required this.showTools,
  });

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final pad = MediaQuery.of(context).size.width < 340 ? 12.0 : 16.0;
    // Reasoning and calls interleave, and the order is the argument: this
    // thought, therefore this call, therefore this next thought.
    final steps = [
      for (final step in turn.steps)
        if (step is ToolCall ? showTools : (step is Reasoning && showThinking))

          step
    ];

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
                      Text(_countLine(), style: d.label.copyWith(color: d.ink3)),
                    ]),
                    const SizedBox(height: 6),
                    Text('Turn detail', style: d.screenTitle),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.fromLTRB(pad, 14, pad, 28),
                itemCount: steps.length,
                itemBuilder: (context, i) {
                  final step = steps[i];
                  return step is ToolCall
                      ? _toolRow(context, d, step)
                      : _thinkingRow(d, (step as Reasoning).text);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _countLine() {
    final steps = showThinking ? turn.thinkingCount : 0;
    final tools = showTools ? turn.toolCount : 0;
    return [
      if (steps > 0) '$steps STEP${steps == 1 ? '' : 'S'}',
      if (tools > 0) '$tools TOOL${tools == 1 ? '' : 'S'}',
    ].join(' · ');
  }

  /// Reasoning is set a size down and a tone back: set like the reply it
  /// would read as more reply, which is exactly what it is not.
  Widget _thinkingRow(D d, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(text,
            style: d.ledger
                .copyWith(fontSize: 12.5, height: 18 / 12.5, color: d.ink3)),
      );

  Widget _toolRow(BuildContext context, D d, ToolCall call) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => showToolDetail(context, call),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(call.name,
                            style: d.ledger.copyWith(
                                fontSize: 13,
                                color: call.isError ? d.accentText : d.ink)),
                        if (call.detail.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(call.detail,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: d.ledger
                                  .copyWith(fontSize: 12.5, color: d.ink3)),
                        ],
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: d.ink3),
                ],
              ),
            ),
          ),
          Container(height: 2, color: d.divider),
        ],
      );
}

/// One call, over the list rather than in place.
///
/// A sheet, not a route: an argument blob and its output are a glance at one
/// row, and coming back to the same scroll position matters more than having
/// somewhere new to be.
Future<void> showToolDetail(BuildContext context, ToolCall call) {
  final d = D.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: d.ground,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.88,
    ),
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(call.name,
                style: d.screenTitle
                    .copyWith(color: call.isError ? d.accentText : d.ink)),
            if (call.detail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(call.detail,
                  style: d.ledger.copyWith(fontSize: 12.5, color: d.ink3)),
            ],
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (call.input.isNotEmpty)
                      _detailBlock(d, 'INPUT', call.input, false),
                    if (call.result.isNotEmpty)
                      _detailBlock(d, call.isError ? 'ERROR' : 'RESULT',
                          call.result, call.isError)
                    else
                      Text('No result recorded.',
                          style: d.prose.copyWith(fontSize: 13, color: d.ink3)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Inputs and results are program text, so they are set as program text and
/// scroll sideways rather than wrapping a command into nonsense.
Widget _detailBlock(D d, String label, String text, bool error) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: d.label
                  .copyWith(fontSize: 10, color: error ? d.accentText : d.ink3)),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            color: d.fill,
            padding: const EdgeInsets.all(10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(text,
                  style: d.ledger.copyWith(fontSize: 12, color: d.ink2)),
            ),
          ),
        ],
      ),
    );
