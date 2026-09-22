import 'package:flutter/material.dart';

/// Minimal SVG path parser — enough for flat logo marks.
///
/// Supports M/m, L/l, H/h, V/v, C/c, Q/q and Z/z, which is what the agent
/// symbols use — Codex's outline is almost entirely quadratics. Anything
/// richer would be a reason to take on a real SVG dependency rather than
/// extend this.
Path parseSvgPath(String d) {
  final path = Path();
  final tokens = _tokenise(d);
  var i = 0;
  double cx = 0, cy = 0, startX = 0, startY = 0;
  String? command;

  double next() => tokens[i++] as double;
  bool moreNumbers() => i < tokens.length && tokens[i] is double;

  while (i < tokens.length) {
    if (tokens[i] is String) {
      command = tokens[i++] as String;
    } else if (command == null) {
      break; // Numbers before any command: malformed, stop.
    } else if (command == 'M') {
      command = 'L'; // Extra pairs after a moveto are linetos, per spec.
    } else if (command == 'm') {
      command = 'l';
    }

    switch (command) {
      case 'M':
        cx = next();
        cy = next();
        path.moveTo(cx, cy);
        startX = cx;
        startY = cy;
      case 'm':
        cx += next();
        cy += next();
        path.moveTo(cx, cy);
        startX = cx;
        startY = cy;
      case 'L':
        cx = next();
        cy = next();
        path.lineTo(cx, cy);
      case 'l':
        cx += next();
        cy += next();
        path.lineTo(cx, cy);
      case 'H':
        cx = next();
        path.lineTo(cx, cy);
      case 'h':
        cx += next();
        path.lineTo(cx, cy);
      case 'V':
        cy = next();
        path.lineTo(cx, cy);
      case 'v':
        cy += next();
        path.lineTo(cx, cy);
      case 'C':
        final x1 = next(), y1 = next(), x2 = next(), y2 = next();
        cx = next();
        cy = next();
        path.cubicTo(x1, y1, x2, y2, cx, cy);
      case 'c':
        final x1 = cx + next(), y1 = cy + next();
        final x2 = cx + next(), y2 = cy + next();
        final ex = cx + next(), ey = cy + next();
        path.cubicTo(x1, y1, x2, y2, ex, ey);
        cx = ex;
        cy = ey;
      case 'Q':
        final x1 = next(), y1 = next();
        cx = next();
        cy = next();
        path.quadraticBezierTo(x1, y1, cx, cy);
      case 'q':
        final x1 = cx + next(), y1 = cy + next();
        final ex = cx + next(), ey = cy + next();
        path.quadraticBezierTo(x1, y1, ex, ey);
        cx = ex;
        cy = ey;
      case 'Z':
      case 'z':
        path.close();
        cx = startX;
        cy = startY;
      default:
        return path; // Unsupported command: stop rather than draw nonsense.
    }
    if (command == 'Z' || command == 'z') continue;
    if (!moreNumbers()) continue;
  }
  return path;
}

List<Object> _tokenise(String d) {
  final out = <Object>[];
  final pattern = RegExp(r'([MmLlHhVvCcSsQqTtAaZz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)');
  for (final m in pattern.allMatches(d)) {
    if (m.group(1) != null) {
      out.add(m.group(1)!);
    } else {
      out.add(double.parse(m.group(2)!));
    }
  }
  return out;
}

/// Paints a parsed path scaled to fit, preserving aspect.
class SvgPathPainter extends CustomPainter {
  final Path path;
  final Color colour;
  final double viewBox;

  SvgPathPainter({
    required this.path,
    required this.colour,
    required this.viewBox,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / viewBox;
    canvas.save();
    canvas.scale(scale, scale);
    canvas.drawPath(path, Paint()..color = colour..isAntiAlias = true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SvgPathPainter old) =>
      old.colour != colour || old.path != path;
}

/// Claude's symbol, from the published SVG (viewBox 0 0 100 100).
/// Trademark of Anthropic, used here to identify the agent.
const claudeSymbolPath =
    "m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z";

/// hsl(14.8, 63.1%, 59.6%) — the fill the symbol ships with.
const claudeOrange = Color(0xFFD97757);

/// Codex's symbol, from the published SVG (viewBox 0 0 250 250).
/// Trademark of OpenAI, used here to identify the agent.
const codexSymbolPath =
    "m84.3 5.1q3.7-1.5 7.7-2.6 3.9-1 7.9-1.6 4-0.5 8.1-0.6 4 0 8 0.5 "
    "20.7 2.4 37.1 17.7 0.1 0.1 0.4 0.3 0.1 0 0.2 0 0 0 0.2 0 0 0 0.1 "
    "0 0 0 0.1 0 5.2-1.4 10.7-1.9 5.4-0.4 10.7 0.1 5.5 0.4 10.7 1.9 "
    "5.2 1.3 10.1 3.6l0.6 0.4 1.6 0.8q5.2 2.5 9.7 6.1 4.7 3.4 8.6 7.7 "
    "3.8 4.3 6.9 9.2 3 4.8 5.2 10.2 4.3 10.5 4.3 22.1 0.2 2.1 0 "
    "4.2-0.1 2.2-0.2 4.3-0.3 2.1-0.7 4.3-0.4 2.1-0.9 4.1 0 0.2 0 0.4 "
    "0 0.2 0 0.5 0 0.1 0.1 0.4 0.1 0.1 0.3 0.3 12.3 12.6 16.3 30 6 "
    "29.7-12.2 53.5l-1.9 2.2q-3 3.5-6.5 6.4-3.4 3.1-7.3 5.5-3.8 "
    "2.4-8.1 4.2-4.1 1.9-8.5 3.2-0.3 0-0.4 0.2-0.3 0-0.4 0.1-0.1 "
    "0.1-0.3 0.4 0 0.1-0.1 0.3c-2.7 7.7-5.3 14.2-10.2 20.7-12.5 "
    "16.5-30.8 25.5-51.5 "
    "25.5q-24.6-0.1-43.6-18.1-0.2-0.1-0.4-0.2-0.2-0.1-0.4-0.1-0.2 "
    "0-0.3 0-0.3 0-0.4 0c-5.4 1.7-10.9 1.9-16.7 1.9q-3.5 "
    "0-7-0.5-3.4-0.4-6.9-1.2-3.3-0.8-6.6-2-3.3-1.2-6.4-2.8-3.3-1.6-6.4-3.6-3-2-5.8-4.3-3-2.3-5.5-5-2.5-2.6-4.6-5.6c-2.2-2.7-4.3-5.4-5.8-8.5q-0.8-1.6-1.6-3.2-0.6-1.7-1.3-3.3-0.7-1.7-1.2-3.4-0.5-1.6-1-3.4-1.1-4-1.6-7.9-0.6-4-0.6-8 "
    "0-4 0.6-8 0.4-4 1.4-8 0 0 0-0.1 0-0.1 0-0.1 0.2-0.2 0.2-0.3 "
    "0-0.1-0.2-0.1 0-0.2 0-0.3 0-0.1-0.1-0.1 0-0.2 "
    "0-0.2-0.1-0.1-0.1-0.1-2.4-2.5-4.6-5.2-2.1-2.7-4-5.4-1.7-3-3.2-6-1.5-3.1-2.6-6.3-0.8-2-1.3-4.1-0.7-2-1.1-4-0.4-2.1-0.7-4.2-0.2-2.2-0.4-4.3-0.2-2.8-0.1-5.6 "
    "0-2.8 0.3-5.4 0.1-2.8 0.6-5.6 0.4-2.8 1.1-5.5 7-23.1 26.9-36.3 "
    "4.3-2.9 8.2-4.5 4.5-1.9 9-3.2 0.2 0 0.3-0.1 0.1-0.2 0.3-0.3 0.1 "
    "0 0.1-0.3 0.1-0.1 0.1-0.2 1-3.1 2.2-6 1-2.9 2.5-5.7 1.5-3 "
    "3.2-5.6 1.7-2.7 3.7-5.1 2.5-3.2 5.3-5.9 3-2.8 6.1-5.4 3.2-2.4 "
    "6.8-4.4 3.5-2 7.2-3.5zm48.3 146.4c-2.3 0.1-4.4 1-6 2.8-1.5 "
    "1.6-2.4 3.7-2.4 5.9 0 2.3 0.9 4.4 2.4 6.2 1.6 1.6 3.7 2.5 6 "
    "2.6h50.4c2.4 0.1 4.8-0.6 6.5-2.4 1.7-1.6 2.8-4 2.8-6.4 "
    "0-2.4-1.1-4.7-2.8-6.3-1.7-1.8-4.1-2.6-6.5-2.4zm-56.7-64.9c-1.2-1.9-3-3.4-5.3-3.9-2.2-0.5-4.5-0.3-6.5 "
    "0.9-2 1.1-3.5 3-4.1 5.2-0.7 2.2-0.4 4.6 0.6 6.5l17.7 30.9-17.5 "
    "29.5c-1.2 2-1.6 4.5-1.1 6.8 0.7 2.3 2.1 4.1 4.1 5.3 2 1.2 4.4 "
    "1.6 6.7 0.9 2.2-0.5 4.2-1.9 5.4-3.9l20.1-34.1q0.7-0.9 0.9-2.1 "
    "0.3-1.1 0.3-2.3 0-1.2-0.3-2.2-0.2-1.2-0.8-2.2z";

/// The three stops of the gradient it ships with, top to bottom.
const codexViolet = Color(0xFFB1A7FF);
const codexBlue = Color(0xFF7A9DFF);
const codexIndigo = Color(0xFF3941FF);
