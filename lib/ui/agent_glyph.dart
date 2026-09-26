import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design.dart';
import 'svg_path.dart';

/// The agent's own mark, in place of spelling its name out.
///
/// Each is drawn from the agent's own published SVG, traced into a path and
/// painted at whatever size the row needs. They are trademarks of their
/// owners, used here to say which agent a row belongs to and nothing else.
class AgentGlyph extends StatelessWidget {
  final String? agent;
  final double size;

  const AgentGlyph({super.key, required this.agent, this.size = 14});

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final painter = switch (agent) {
      'pi' => _PiGlyph(),
      'claude' => _ClaudeGlyph(),
      'codex' => _CodexGlyph(),
      'opencode' => _OpencodeGlyph(d.ink),
      'omp' => _OmpGlyph(),
      _ => null,
    };
    if (painter == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            (agent?.isNotEmpty ?? false) ? agent![0].toUpperCase() : '·',
            style: TextStyle(
              fontFamily: D.mono,
              fontSize: size * 0.7,
              fontWeight: FontWeight.w700,
              color: d.ink3,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: painter),
    );
  }
}

/// Three interlocking blocks, transcribed from Pi's SVG on an 800 grid.
class _PiGlyph extends CustomPainter {
  static const _blocks = <(Color, List<Offset>)>[
    (
      Color(0xFFF09082),
      [
        Offset(165.29, 165.29),
        Offset(517.36, 165.29),
        Offset(517.36, 400),
        Offset(400, 400),
        Offset(400, 282.65),
        Offset(165.29, 282.65),
      ]
    ),
    (
      Color(0xFF4D9ABF),
      [
        Offset(165.29, 282.65),
        Offset(282.65, 282.65),
        Offset(282.65, 400),
        Offset(400, 400),
        Offset(400, 517.36),
        Offset(282.65, 517.36),
        Offset(282.65, 634.72),
        Offset(165.29, 634.72),
      ]
    ),
    (
      Color(0xFFF1BE58),
      [
        Offset(517.36, 400),
        Offset(634.72, 400),
        Offset(634.72, 634.72),
        Offset(517.36, 634.72),
      ]
    ),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 800;
    for (final (colour, points) in _blocks) {
      final path = Path()..moveTo(points.first.dx * scale, points.first.dy * scale);
      for (final p in points.skip(1)) {
        path.lineTo(p.dx * scale, p.dy * scale);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = colour);
    }
  }

  @override
  bool shouldRepaint(_PiGlyph old) => false;
}

/// Claude's published symbol.
class _ClaudeGlyph extends CustomPainter {
  static final _painter = SvgPathPainter(
    path: parseSvgPath(claudeSymbolPath),
    colour: claudeOrange,
    viewBox: 100,
  );

  @override
  void paint(Canvas canvas, Size size) => _painter.paint(canvas, size);

  @override
  bool shouldRepaint(_ClaudeGlyph old) => false;
}

/// Codex's own mark, traced from its SVG on a 250 grid.
///
/// It ships with a vertical gradient — violet at the top through blue to
/// indigo — which is most of what makes it recognisable at this size, so the
/// shader is part of the glyph rather than a flat fill.
class _CodexGlyph extends CustomPainter {
  _CodexGlyph();

  static final _path = parseSvgPath(codexSymbolPath);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 250;
    canvas.save();
    canvas.scale(scale);
    canvas.drawPath(
      _path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [codexViolet, codexBlue, codexIndigo],
          stops: [0, 0.5, 1],
        ).createShader(const Rect.fromLTWH(0, 0, 250, 250)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CodexGlyph old) => false;
}

/// OpenCode's mark, from its favicon on a 512 grid: a frame around a grey
/// square. The frame is white on OpenCode's own dark tile, so here it takes
/// the text colour to read on either theme.
class _OpencodeGlyph extends CustomPainter {
  final Color frame;
  _OpencodeGlyph(this.frame);

  @override
  void paint(Canvas canvas, Size size) {
    // The mark spans x 128–384 and y 96–416; fit that, not the whole tile.
    final scale = size.height / 320;
    canvas.save();
    canvas.translate((size.width - 256 * scale) / 2, 0);
    canvas.scale(scale);
    canvas.translate(-128, -96);
    canvas.drawRect(const Rect.fromLTRB(192, 224, 320, 352),
        Paint()..color = const Color(0xFF5A5858));
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(const Rect.fromLTRB(128, 96, 384, 416))
        ..addRect(const Rect.fromLTRB(192, 160, 320, 352)),
      Paint()..color = frame,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OpencodeGlyph old) => old.frame != frame;
}

/// oh-my-pi's π mark, from its SVG on a 64 grid, with its diagonal gradient
/// from magenta through violet to cyan (converted from the SVG's oklch).
class _OmpGlyph extends CustomPainter {
  _OmpGlyph();

  static final _path = parseSvgPath('M10 14h44v9H43v33h-9V23h-9v22h-9V23H10z');

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 64);
    canvas.drawPath(
      _path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF84FCC), Color(0xFF9362F4), Color(0xFF00DBE4)],
          stops: [0, 0.5, 1],
        ).createShader(const Rect.fromLTRB(10, 14, 54, 56)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OmpGlyph old) => false;
}
