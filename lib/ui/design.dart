import 'package:flutter/material.dart';

/// The design system.
///
/// Two rules carry most of the work:
///  - **One family, weight does the work.** Archivo for prose, Roboto Mono for
///    anything machine-generated (paths, hosts, code, counts, states). Prose is
///    never mono; machine output is never Archivo.
///  - **One hue, one meaning.** Accent means a human is needed, and marks the
///    primary action. Every other agent state is drawn in ink — filled,
///    outlined, dashed, dotted — so blocked stays unmissable in a list of ten.
class D {
  final Color ground;
  final Color fill;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color accentField;
  final Color accentText;
  final double dividerOpacity;

  const D({
    required this.ground,
    required this.fill,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accentField,
    required this.accentText,
    required this.dividerOpacity,
  });

  static const light = D(
    ground: Color(0xFFF3F2F2),
    fill: Color(0xFFEAE9E9),
    ink: Color(0xFF201E1D),
    ink2: Color(0xFF605D5D),
    ink3: Color(0xFF9B9797),
    accentField: Color(0xFFEC3013),
    accentText: Color(0xFFAE1800),
    dividerOpacity: 0.40,
  );

  static const dark = D(
    ground: Color(0xFF1A1918),
    fill: Color(0xFF262423),
    ink: Color(0xFFF3F2F2),
    ink2: Color(0xFFA8A4A3),
    ink3: Color(0xFF7D7979),
    accentField: Color(0xFFFF563C),
    accentText: Color(0xFFFF9783),
    dividerOpacity: 0.35,
  );

  static const sans = 'Archivo';
  static const mono = 'RobotoMono';

  /// Reserved for the status symbols. Nothing else in the app uses green —
  /// accent still means "a human is needed" and nothing else.
  static const idleGreen = Color(0xFF6EA05A);

  static D of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  Color get divider => ink.withValues(alpha: dividerOpacity);

  // ── Type scale ────────────────────────────────────────────────────────────
  // Sizes are literal from the design; only colour varies by theme.

  /// Agent prose. Paragraph spacing is 14 — see [proseParagraphGap].
  TextStyle get prose => TextStyle(
      fontFamily: sans, fontSize: 16, height: 25 / 16, color: ink);
  static const proseParagraphGap = 14.0;

  /// Heading inside a reply: uppercase, 22 above / 8 below.
  TextStyle get replyHeading => TextStyle(
        fontFamily: sans,
        fontSize: 13,
        height: 16 / 13,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.10 * 13,
        color: ink,
      );

  TextStyle get userMessage => TextStyle(
      fontFamily: sans, fontSize: 17, height: 24 / 17,
      fontWeight: FontWeight.w600, color: ink);

  /// The mono kicker above a user band, and above the live tail.
  TextStyle get kicker => TextStyle(
        fontFamily: mono,
        fontSize: 10,
        height: 1,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.14 * 10,
        color: ink3,
      );

  TextStyle get listItem => TextStyle(
      fontFamily: sans, fontSize: 16, height: 24 / 16, color: ink);

  TextStyle get inlineCode => TextStyle(
      fontFamily: mono, fontSize: 14.5, fontWeight: FontWeight.w500, color: ink);

  TextStyle get codeBlock => TextStyle(
      fontFamily: mono, fontSize: 13, height: 20 / 13, color: ink);

  /// Secondary / metadata. Uppercase, except paths which keep their case.
  TextStyle get meta => TextStyle(
        fontFamily: mono,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.12 * 12,
        color: ink2,
      );

  /// Group headers and other small mono labels.
  TextStyle get label => TextStyle(
        fontFamily: mono,
        fontSize: 11,
        height: 1,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.12 * 11,
        color: ink2,
      );

  /// Session title in a list row.
  TextStyle get rowTitle => TextStyle(
      fontFamily: sans, fontSize: 16, height: 21 / 16,
      fontWeight: FontWeight.w600, color: ink);

  /// A quiet row recedes so the live ones read as figure.
  TextStyle get rowTitleQuiet => TextStyle(
      fontFamily: sans, fontSize: 16, height: 21 / 16,
      fontWeight: FontWeight.w500, color: ink2);

  /// The live tail: the one place mono runs as body text.
  TextStyle get liveTail => TextStyle(
      fontFamily: mono, fontSize: 12.5, height: 19 / 12.5, color: ink2);

  /// The disclosure ledger.
  TextStyle get ledger => TextStyle(
      fontFamily: mono, fontSize: 13.5, height: 21 / 13.5, color: ink2);

  TextStyle get screenTitle => TextStyle(
      fontFamily: sans, fontSize: 19, height: 26 / 19,
      fontWeight: FontWeight.w700, color: ink);

  static ThemeData theme(Brightness brightness) {
    final d = brightness == Brightness.dark ? dark : light;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: d.ground,
      colorScheme: ColorScheme.fromSeed(
        seedColor: d.accentField,
        brightness: brightness,
        surface: d.ground,
      ),
      fontFamily: sans,
      splashFactory: InkRipple.splashFactory,
    );
  }
}

/// The five agent states, drawn rather than coloured.
///
/// Shape carries the meaning and the single hue carries the urgency, which is
/// what keeps a blocked agent unmissable — and is colour-blind safe as a
/// side effect.
enum AgentMark { blocked, working, done, idle, unknown }

AgentMark markFor(String? status) => switch (status) {
      'blocked' => AgentMark.blocked,
      'working' => AgentMark.working,
      'done' => AgentMark.done,
      'idle' => AgentMark.idle,
      _ => AgentMark.unknown,
    };

/// A 12px marker inside a 40dp touch column, so the state doubles as the hit
/// target for the row.
class StateMarker extends StatefulWidget {
  final AgentMark mark;

  const StateMarker({super.key, required this.mark});

  @override
  State<StateMarker> createState() => _StateMarkerState();
}

class _StateMarkerState extends State<StateMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(StateMarker old) {
    super.didUpdateWidget(old);
    if (old.mark != widget.mark) _syncPulse();
  }

  // Working is the only animated thing in the app.
  void _syncPulse() {
    if (widget.mark == AgentMark.working) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    return SizedBox(
      width: 40,
      height: 24,
      child: Align(
        alignment: Alignment.centerLeft,
        child: switch (widget.mark) {
          AgentMark.blocked => Container(
              width: 12, height: 12, color: d.accentField),
          AgentMark.working => AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => Container(
                width: 12,
                height: 12,
                color: d.ink.withValues(
                    alpha: 1.0 - (0.6 * Curves.easeInOut.transform(_pulse.value))),
              ),
            ),
          AgentMark.done => Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                  border: Border.all(color: d.ink, width: 2)),
            ),
          AgentMark.idle => Container(width: 12, height: 2, color: d.ink3),
          // A dashed border stands in for the dotted outline; the only variant
          // that would otherwise need CustomPaint.
          AgentMark.unknown => CustomPaint(
              size: const Size(12, 12),
              painter: _DottedSquare(color: d.ink3),
            ),
        },
      ),
    );
  }
}

class _DottedSquare extends CustomPainter {
  final Color color;

  _DottedSquare({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const dash = 2.5;
    for (double x = 0; x < size.width; x += dash * 2) {
      canvas.drawLine(Offset(x, 1), Offset((x + dash).clamp(0, size.width), 1), paint);
      canvas.drawLine(Offset(x, size.height - 1),
          Offset((x + dash).clamp(0, size.width), size.height - 1), paint);
    }
    for (double y = 0; y < size.height; y += dash * 2) {
      canvas.drawLine(Offset(1, y), Offset(1, (y + dash).clamp(0, size.height)), paint);
      canvas.drawLine(Offset(size.width - 1, y),
          Offset(size.width - 1, (y + dash).clamp(0, size.height)), paint);
    }
  }

  @override
  bool shouldRepaint(_DottedSquare old) => old.color != color;
}

/// A small running indicator. The pulsing state marker is deliberately quiet;
/// this is for places that need to say "work is happening" unmistakably.
class WorkingSpinner extends StatefulWidget {
  final Color color;
  final double size;

  const WorkingSpinner({super.key, required this.color, this.size = 12});

  @override
  State<WorkingSpinner> createState() => _WorkingSpinnerState();
}

class _WorkingSpinnerState extends State<WorkingSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _SpinnerPainter(
                color: widget.color, progress: _c.value),
          ),
        ),
      );
}

class _SpinnerPainter extends CustomPainter {
  final Color color;
  final double progress;

  _SpinnerPainter({required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    // A square sweep rather than a circle — the app draws in squares.
    final rect = Offset.zero & size;
    const total = 4.0;
    final start = progress * 2 * 3.14159265;
    canvas.drawArc(rect.deflate(1), start, 2 * 3.14159265 / total, false, paint);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) =>
      old.progress != progress || old.color != color;
}

/// Clamped overscroll — the stretch drags long transcripts out of shape.
class NoStretchScrollBehavior extends MaterialScrollBehavior {
  const NoStretchScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();
}

/// Agent state as a glanceable symbol, the way Herdr's own status indicators
/// read: a filled dot for ready, a tick for finished, the spinner for work in
/// progress, accent for the one that needs a human.
///
/// This spends colour that the rest of the app deliberately withholds, which
/// is the trade for being readable without reading.
class StatusIcon extends StatelessWidget {
  final String? status;
  final double size;

  const StatusIcon({super.key, required this.status, this.size = 13});

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    if (status == 'working') {
      return WorkingSpinner(color: d.ink2, size: size);
    }
    final (glyph, colour) = switch (status) {
      'blocked' => ('!', d.accentField),
      'done' => ('✓', D.idleGreen),
      'idle' => ('●', D.idleGreen),
      _ => ('○', d.ink3),
    };
    return SizedBox(
      width: size + 4,
      height: size + 4,
      child: Center(
        child: Text(
          glyph,
          style: TextStyle(
            fontFamily: D.mono,
            fontSize: status == 'idle' ? size * 0.8 : size,
            height: 1,
            fontWeight: FontWeight.w700,
            color: colour,
          ),
        ),
      ),
    );
  }
}

/// Stop, with the fact that something is running drawn around it.
///
/// One control instead of two signals: the ring says work is happening, the
/// square says what tapping will do.
class StopControl extends StatefulWidget {
  final VoidCallback onTap;
  final double size;

  const StopControl({super.key, required this.onTap, this.size = 44});

  @override
  State<StopControl> createState() => _StopControlState();
}

class _StopControlState extends State<StopControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Center(
          child: SizedBox(
            width: widget.size - 8,
            height: widget.size - 8,
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, child) => CustomPaint(
                painter: _StopRingPainter(
                  colour: d.accentField,
                  progress: _c.value,
                ),
                child: child,
              ),
              child: Center(
                child: Container(
                  width: widget.size * 0.3,
                  height: widget.size * 0.3,
                  color: d.accentField,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StopRingPainter extends CustomPainter {
  final Color colour;
  final double progress;

  _StopRingPainter({required this.colour, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    canvas.drawArc(
      rect,
      progress * 2 * 3.141592653589793,
      1.7,
      false,
      Paint()
        ..color = colour
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawArc(
      rect,
      0,
      2 * 3.141592653589793,
      false,
      Paint()
        ..color = colour.withValues(alpha: 0.2)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_StopRingPainter old) =>
      old.progress != progress || old.colour != colour;
}

/// The app's switch: square, ink, no Material pill.
///
/// Defined once so a toggle in a menu and a toggle in settings are the same
/// object rather than two things that merely do the same job.
class SquareToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const SquareToggle({super.key, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 40,
        height: 22,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: value ? d.ink : d.divider),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 140),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(width: 16, height: 16, color: d.ground),
        ),
      ),
    );
  }
}
