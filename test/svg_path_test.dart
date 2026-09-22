import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/ui/svg_path.dart';

void main() {
  test('parses lines, relative moves and closes', () {
    final p = parseSvgPath('M10 10 H90 V90 H10 Z');
    final b = p.getBounds();
    expect(b.left, 10);
    expect(b.top, 10);
    expect(b.right, 90);
    expect(b.bottom, 90);
  });

  test('handles implicit repeats and sign-separated numbers', () {
    final p = parseSvgPath('m0 0l10 0 0 10-10 0z');
    expect(p.getBounds().width, 10);
    expect(p.getBounds().height, 10);
  });

  test('handles relative cubics', () {
    final p = parseSvgPath('M0 0 c10 0 20 10 20 20');
    expect(p.getBounds().right, closeTo(20, 0.001));
  });

  test('the Claude symbol fills its viewBox', () {
    // A parser slip shows up as a collapsed bounding box.
    final p = parseSvgPath(claudeSymbolPath);
    final b = p.getBounds();
    expect(b.width, greaterThan(90));
    expect(b.height, greaterThan(90));
    expect(b.left, lessThan(5));
    expect(b.top, lessThan(5));
  });
}
