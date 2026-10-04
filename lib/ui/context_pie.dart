import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design.dart';

/// How full the agent's context is, as a small pie: the filled share is the
/// share in use. It turns to the accent at 80%, where agents start to
/// compact on their own and a conversation is worth tidying.
class ContextPie extends StatelessWidget {
  final double fraction;
  final double size;

  const ContextPie({super.key, required this.fraction, this.size = 18});

  static bool isHigh(double fraction) => fraction >= 0.8;

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final colour = isHigh(fraction) ? d.accentField : d.ink2;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _PiePainter(fraction, colour)),
    );
  }
}

class _PiePainter extends CustomPainter {
  final double fraction;
  final Color colour;

  _PiePainter(this.fraction, this.colour);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ring = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(rect.center, size.width / 2 - 0.75, ring);
    if (fraction <= 0) return;
    canvas.drawArc(
      rect.deflate(3),
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0.0, 1.0),
      true,
      Paint()..color = colour,
    );
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.fraction != fraction || old.colour != colour;
}

/// "108K" — tokens as a reader counts them.
String tokenCount(int n) => n >= 1000000
    ? '${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M'
    : n >= 1000
        ? '${(n / 1000).round()}K'
        : '$n';
