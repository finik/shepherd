import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'design.dart';

/// The question an agent is waiting on, and the answers it will take.
///
/// One answer at a time, in full, with arrows to flip between them and one
/// button to send the one you are looking at.
///
/// Agents write options as sentences — "Yes, and switch to accept edits
/// (auto-approve file edits and common file commands) for this session" — and
/// several side by side on a phone would each be cropped. A cropped consent
/// button can read as a different answer than the one it sends: "No, and tell
/// Claude what to do differently" is not "No".
class BlockedPrompt extends StatefulWidget {
  final ({String question, List<Choice> choices}) asked;

  /// Called with the option's number, which is the key the menu is waiting for.
  final void Function(int choice) onAnswer;

  /// For a question that takes several answers: called with the numbers of
  /// every option to leave ticked.
  final void Function(Set<int> ticked)? onChecks;

  const BlockedPrompt(
      {super.key, required this.asked, required this.onAnswer, this.onChecks});

  @override
  State<BlockedPrompt> createState() => _BlockedPromptState();
}

class _BlockedPromptState extends State<BlockedPrompt> {
  int _at = 0;

  /// The boxes ticked on the phone, by option number; starts as the screen
  /// has them.
  Set<int> _ticked = {};

  bool get _boxes =>
      widget.onChecks != null &&
      widget.asked.choices.any((c) => c.checked != null);

  Set<int> get _tickedOnScreen => {
        for (var i = 0; i < widget.asked.choices.length; i++)
          if (widget.asked.choices[i].checked == true) i + 1
      };

  /// Open on the option the agent's cursor is on, which is what Enter at the
  /// desktop would have picked.
  int get _start {
    final at = widget.asked.choices.indexWhere((c) => c.selected);
    return at < 0 ? 0 : at;
  }

  @override
  void initState() {
    super.initState();
    _at = _start;
    _ticked = _tickedOnScreen;
  }

  @override
  void didUpdateWidget(BlockedPrompt old) {
    super.didUpdateWidget(old);
    // A new question is a new set of answers; staying on option three of the
    // last one is how you agree to something you never read.
    if (old.asked.question != widget.asked.question) {
      _at = _start;
      _ticked = _tickedOnScreen;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final choices = widget.asked.choices;
    if (choices.isEmpty) return _panel(d, const []);
    if (_boxes) return _checklist(d, choices);
    final at = _at.clamp(0, choices.length - 1);
    return _panel(d, [
      const SizedBox(height: 12),
      Row(
        children: [
          _arrow(d, Icons.chevron_left, choices.length,
              () => setState(() => _at = (at - 1) % choices.length)),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    choices[at].label,
                    style: d.label.copyWith(fontSize: 13, color: d.ground),
                  ),
                  // What the agent said about this option. One at a time
                  // leaves room for it, which is the reason for one at a time.
                  if (choices[at].detail.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      choices[at].detail,
                      style: d.prose.copyWith(
                        fontSize: 13,
                        height: 1.35,
                        color: d.ground.withValues(alpha: 0.88),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          _arrow(d, Icons.chevron_right, choices.length,
              () => setState(() => _at = (at + 1) % choices.length)),
        ],
      ),
      if (choices.length > 1) ...[
        const SizedBox(height: 4),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < choices.length; i++) ...[
                if (i > 0) const SizedBox(width: 7),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        i == at ? d.ground : d.ground.withValues(alpha: 0.35),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
      const SizedBox(height: 12),
      InkWell(
        onTap: () => widget.onAnswer(at + 1),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          color: d.ground,
          alignment: Alignment.center,
          child: Text('OK',
              style: d.label.copyWith(fontSize: 15, color: d.accentField)),
        ),
      ),
    ]);
  }

  /// Several answers at once: every box on screen, ticked on the phone, and
  /// one button that ticks them in the agent and moves on to what it asks
  /// next.
  Widget _checklist(D d, List<Choice> choices) {
    return _panel(d, [
      const SizedBox(height: 8),
      for (var i = 0; i < choices.length; i++)
        if (choices[i].checked != null && !choices[i].typed)
          InkWell(
            key: ValueKey('check-${i + 1}'),
            onTap: () => setState(() => _ticked.contains(i + 1)
                ? _ticked.remove(i + 1)
                : _ticked.add(i + 1)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    margin: const EdgeInsets.only(top: 1, right: 12),
                    decoration: BoxDecoration(
                      color: _ticked.contains(i + 1) ? d.ground : null,
                      border: Border.all(color: d.ground, width: 2),
                    ),
                    child: _ticked.contains(i + 1)
                        ? Icon(Icons.check, size: 14, color: d.accentField)
                        : null,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(choices[i].label,
                            style: d.label
                                .copyWith(fontSize: 13, color: d.ground)),
                        if (choices[i].detail.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            choices[i].detail,
                            style: d.prose.copyWith(
                              fontSize: 13,
                              height: 1.35,
                              color: d.ground.withValues(alpha: 0.88),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      const SizedBox(height: 12),
      InkWell(
        key: const ValueKey('checks-next'),
        onTap: () => widget.onChecks!(Set.of(_ticked)),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          color: d.ground,
          alignment: Alignment.center,
          child: Text('NEXT',
              style: d.label.copyWith(fontSize: 15, color: d.accentField)),
        ),
      ),
    ]);
  }

  Widget _panel(D d, List<Widget> answers) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        color: d.accentField,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WAITING ON YOU', style: d.label.copyWith(color: d.ground)),
            const SizedBox(height: 8),
            if (widget.asked.question.isNotEmpty)
              Text(widget.asked.question,
                  style: d.liveTail.copyWith(color: d.ground)),
            ...answers,
          ],
        ),
      );

  Widget _arrow(D d, IconData icon, int count, VoidCallback onTap) =>
      GestureDetector(
        onTap: count > 1 ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Icon(icon,
              size: 26,
              color: count > 1 ? d.ground : d.ground.withValues(alpha: 0.3)),
        ),
      );
}
