import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'context_pie.dart';
import 'design.dart';

/// What is left of each subscription, as the host reads it — through the
/// herdr-agent-usage plugin, CodexBar, or both: every limit of every plan,
/// how much of it is used, and when it resets.
class QuotasScreen extends StatefulWidget {
  final AppState state;

  const QuotasScreen({super.key, required this.state});

  @override
  State<QuotasScreen> createState() => _QuotasScreenState();
}

class _QuotasScreenState extends State<QuotasScreen> {
  late Future<List<PlanUsage>?> _plans;

  @override
  void initState() {
    super.initState();
    _plans = widget.state.plans();
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final pad = MediaQuery.of(context).size.width < 340 ? 12.0 : 16.0;
    return Scaffold(
      backgroundColor: d.ground,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
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
                      Text('BACK',
                          style: d.meta.copyWith(fontSize: 11, color: d.ink3)),
                    ]),
                    const SizedBox(height: 6),
                    Text('Subscriptions', style: d.screenTitle),
                  ],
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<PlanUsage>?>(
                future: _plans,
                initialData: widget.state.planList,
                builder: (context, snapshot) {
                  final found = snapshot.data;
                  final waiting =
                      snapshot.connectionState != ConnectionState.done;
                  if (found == null || found.isEmpty) {
                    return Padding(
                      padding: EdgeInsets.all(pad),
                      child: Text(
                          waiting
                              ? 'Asking the host…'
                              : found == null
                                  ? 'The host did not answer.'
                                  : 'Nothing on the host has read a '
                                      'subscription yet.',
                          style: d.prose.copyWith(color: d.ink3)),
                    );
                  }
                  return ListView(
                    padding: EdgeInsets.fromLTRB(pad, 16, pad, 16),
                    children: [for (final p in found) _plan(d, p)],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The open agent's subscription in two thin bars: the five-hour window
/// over the week, each with the hours until it resets.
class QuotaBars extends StatelessWidget {
  final PlanUsage plan;

  const QuotaBars({super.key, required this.plan});

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    PlanWindow? find(int minutes) {
      for (final w in plan.windows) {
        if (w.minutes == minutes) return w;
      }
      return null;
    }

    final shown = [?find(300), ?find(10080)];
    final windows = shown.isEmpty ? plan.windows.take(2).toList() : shown;
    final now = DateTime.now();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final w in windows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _bar(d, w, width: 44, height: 5),
              const SizedBox(width: 5),
              SizedBox(
                width: 30,
                child: Text(hoursLeft(w.resetsAt, now) ?? '',
                    style: d.meta.copyWith(fontSize: 10, color: d.ink3)),
              ),
            ]),
          ),
      ],
    );
  }
}

/// A limit as a bar, in the context pie's colours: the same ink, and the
/// same red from 80%.
Widget _bar(D d, PlanWindow w, {double? width, double height = 6}) {
  final colour =
      ContextPie.isHigh(w.usedPercent / 100) ? d.accentField : d.ink2;
  return Container(
    width: width,
    height: height,
    decoration: BoxDecoration(border: Border.all(color: colour, width: 1)),
    child: FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: (w.usedPercent / 100).clamp(0.0, 1.0),
      child: Container(color: colour),
    ),
  );
}

/// "2d", "20h", "40m": the time left before a window resets — days once
/// there is more than one, hours below that, minutes in the last hour.
String? hoursLeft(DateTime? at, DateTime now) {
  if (at == null) return null;
  final left = at.difference(now);
  if (left.isNegative) return '0m';
  if (left.inHours >= 24) return '${left.inDays}d';
  if (left.inHours >= 1) return '${left.inHours}h';
  return '${left.inMinutes}m';
}

Widget _plan(D d, PlanUsage p) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
              [providerName(p.provider), if (p.plan.isNotEmpty) p.plan]
                  .join(' · '),
              style: d.rowTitle.copyWith(fontSize: 15)),
          if (asOf(p.at, DateTime.now()) case final old?)
            Text(old, style: d.label.copyWith(color: d.ink3)),
          if (p.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(p.error!,
                  style: d.label.copyWith(color: d.ink3)),
            ),
          for (final w in p.windows) _window(d, w),
        ],
      ),
    );

Widget _window(D d, PlanWindow w) {
  final high = ContextPie.isHigh(w.usedPercent / 100);
  final span = windowSpan(w.minutes);
  final reset = resetsIn(w.resetsAt, DateTime.now());
  return Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: Text(
                [?w.label, ?span].join(' · '),
                style: d.label.copyWith(color: d.ink2)),
          ),
          Text('${w.usedPercent.round()}%',
              style: d.label.copyWith(color: high ? d.accentText : d.ink2)),
        ]),
        const SizedBox(height: 4),
        _bar(d, w),
        if (reset != null || w.pace != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                [
                  ?reset,
                  if (w.pace case final pace?) pace.replaceAll(' | ', ' · '),
                ].join(' · '),
                style: d.label.copyWith(color: d.ink3)),
          ),
      ],
    ),
  );
}

/// "as of 2h ago" for a reading old enough to matter; null for a fresh one.
String? asOf(DateTime? at, DateTime now) {
  if (at == null) return null;
  final age = now.difference(at);
  if (age < const Duration(minutes: 15)) return null;
  if (age.inHours < 1) return 'as of ${age.inMinutes}m ago';
  if (age.inDays < 1) return 'as of ${age.inHours}h ago';
  return 'as of ${age.inDays} days ago';
}

/// "Claude", "Codex": a provider as people name it.
String providerName(String id) => switch (id) {
      'codex' => 'Codex',
      'claude' => 'Claude',
      'openai' => 'OpenAI',
      'opencode' => 'OpenCode',
      'xai' => 'xAI',
      'grok' => 'Grok',
      'muse' => 'muse',
      'omp' => 'omp',
      _ => id.isEmpty ? id : id[0].toUpperCase() + id.substring(1),
    };

/// "5 hours", "week", "30 days": how long a limit's window runs.
String? windowSpan(int? minutes) {
  if (minutes == null || minutes <= 0) return null;
  if (minutes == 10080) return 'week';
  if (minutes % 1440 == 0) return '${minutes ~/ 1440} days';
  if (minutes % 60 == 0) return '${minutes ~/ 60} hours';
  return '$minutes minutes';
}

/// "resets in 1h 9m", "resets in 3 days".
String? resetsIn(DateTime? at, DateTime now) {
  if (at == null) return null;
  final left = at.difference(now);
  if (left.isNegative) return 'resetting';
  if (left.inHours >= 48) return 'resets in ${left.inDays} days';
  if (left.inHours >= 1) {
    return 'resets in ${left.inHours}h ${left.inMinutes % 60}m';
  }
  return 'resets in ${left.inMinutes}m';
}
