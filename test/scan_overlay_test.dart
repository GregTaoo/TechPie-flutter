import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/widgets/scanner/scan_overlay.dart';

void main() {
  // The numbers below are Telegram's, from `CameraScanActivity`: they are what
  // makes the opening animation read as "the edges retract into corner ticks"
  // rather than "a box fades in".
  group('the opening animation', () {
    test('the box grows from half size to full size', () {
      expect(ScanOverlayPainter.appearingScale(0), 0.5);
      expect(ScanOverlayPainter.appearingScale(1), 1);
    });

    test('the stroke is fully there almost immediately', () {
      expect(ScanOverlayPainter.bracketStroke(0), 0);
      // Telegram reaches 4dp within the first 5% of the spring (`v * 20`).
      expect(ScanOverlayPainter.bracketStroke(0.05), 4);
      expect(ScanOverlayPainter.bracketStroke(1), 4);
    });

    test('the arms start as whole edges and retract into 20dp ticks', () {
      const side = 300.0;
      expect(ScanOverlayPainter.bracketLength(side, 0), side);
      // `pow(v, 1.8)`: at half the spring the arm is already down to ~73% of
      // the edge, and it ends at a 20dp tick.
      expect(ScanOverlayPainter.bracketLength(side, 0.5), closeTo(219.6, 0.5));
      expect(ScanOverlayPainter.bracketLength(side, 1), 20);
    });

    test('the resting square is Telegram\'s centred min(w, h) / 1.5', () {
      final square = ScanOverlayPainter.restingSquare(const Size(400, 800));
      expect(square.width, closeTo(400 / 1.5, 0.01));
      expect(square.height, square.width);
      expect(square.center.dx, closeTo(200, 0.01));
      expect(square.center.dy, closeTo(400, 0.01));
    });
  });

  group('the found-code frame', () {
    test('the target is padded 25dp across and 15dp down', () {
      final target = ScanOverlayPainter.paddedTarget(
        const [Offset(0.4, 0.4), Offset(0.6, 0.6)],
        const Size(400, 800),
      );
      expect(target.left, closeTo(160 - 25, 0.01));
      expect(target.right, closeTo(240 + 25, 0.01));
      expect(target.top, closeTo(320 - 15, 0.01));
      expect(target.bottom, closeTo(480 + 15, 0.01));
    });

    test('the frame blends from the square onto the target', () {
      const rest = Rect.fromLTWH(100, 100, 200, 200);
      const found = Rect.fromLTWH(150, 150, 100, 100);
      expect(ScanOverlayPainter.blendFrame(rest, found, 0), rest);
      expect(ScanOverlayPainter.blendFrame(rest, found, 1), found);
      expect(
        ScanOverlayPainter.blendFrame(rest, found, 0.5),
        const Rect.fromLTWH(125, 125, 150, 150),
      );
      // Nothing found keeps the resting square, however far the spring has run.
      expect(ScanOverlayPainter.blendFrame(rest, null, 1), rest);
    });
  });
}
