import 'package:flutter/painting.dart';

/// The single recognition region used by the scanner preview and guide.
Rect scannerWindowForSize(Size size) {
  if (size.isEmpty) return Rect.zero;
  final side = size.width.clamp(250.0, 310.0);
  return Rect.fromCenter(
    center: Offset(size.width / 2, size.height * 0.43),
    width: side,
    height: side,
  ).intersect(Offset.zero & size);
}
