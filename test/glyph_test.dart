import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/ui/svg_path.dart';

/// The marks are path data pasted into Dart. A lost space turns "5.2 1.3"
/// into "5.21.3", which parses silently as two different numbers and leaves
/// the parser halfway through a curve.
void main() {
  test('every symbol fills its own viewBox', () {
    final claude = parseSvgPath(claudeSymbolPath).getBounds();
    expect(claude.width, closeTo(100, 4));
    expect(claude.height, closeTo(100, 4));

    final codex = parseSvgPath(codexSymbolPath).getBounds();
    expect(codex.width, closeTo(250, 6));
    expect(codex.height, closeTo(250, 6));
  });

  test('the parser handles the curves these paths are made of', () {
    // Codex's outline is almost entirely quadratics.
    final quadratic = parseSvgPath('M0 0 q10 0 10 10 q0 10 -10 10 z');
    expect(quadratic.getBounds().width, closeTo(10, 0.5));
    expect(quadratic.getBounds().height, closeTo(20, 0.5));
  });
}
