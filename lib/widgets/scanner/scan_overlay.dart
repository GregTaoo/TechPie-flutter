import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// The scanner's viewfinder, reproduced from Telegram's `CameraScanActivity`.
///
/// Three animated scalars drive everything, exactly as they do there:
///
/// * [appearing] — a spring started when the preview is actually running. The
///   box grows from half size to full size while the four corner brackets
///   retract from full-length edges into short ticks. That retraction *is* the
///   opening animation; nothing slides in.
/// * [dismissed] — 0..1, fades the chrome (title, hint, torch) out and deepens
///   the scrim once a code has been found, over `300ms × distance`.
/// * [absorbed] — a spring that morphs the box from its resting square onto the
///   code's own corners, so the frame lands on the code instead of shrinking to
///   the centre.
///
/// The numbers are the ones in Telegram's source: `lineLength` eases with
/// `pow(v, 1.8)`, the stroke reaches 4dp within 5% of the appearing spring, the
/// resting square is `min(w, h) / 1.5`, and the found-code target is padded
/// 25dp horizontally and 15dp vertically.
final class ScanOverlay extends StatefulWidget {
  const ScanOverlay({
    super.key,
    required this.child,
    required this.appearing,
    required this.dismissed,
    required this.absorbed,
    this.target,
    this.windowFor,
    this.dimOpacity = 0.5,
    this.accent = Colors.white,
    this.painterKey,
  });

  /// The camera preview (or anything else) this overlay sits on top of.
  final Widget child;

  /// 0..1, the opening spring. See [ScanOverlayController].
  final Animation<double> appearing;

  /// 0..1, how far the found-code state has taken over the chrome.
  final Animation<double> dismissed;

  /// 0..1, how far the box has moved onto [target].
  final Animation<double> absorbed;

  /// The found code's corners, normalised to 0..1 in preview space. Null keeps
  /// the box on its resting square.
  final List<Offset>? target;

  /// Where the box rests, as a function of the size being painted. Pass the
  /// same function the camera plugin is told to read, so the frame never lies
  /// about where a scan happens. Defaults to Telegram's centred
  /// `min(w, h) / 1.5` square.
  final Rect Function(Size size)? windowFor;

  /// Scrim opacity at rest, before [dismissed] deepens it.
  final double dimOpacity;

  /// Bracket colour.
  final Color accent;

  /// Placed on the painting layer, so a caller (or a test) can address the mask
  /// itself rather than the widget that hosts it.
  final Key? painterKey;

  @override
  State<ScanOverlay> createState() => _ScanOverlayState();
}

final class _ScanOverlayState extends State<ScanOverlay> {
  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          child: AnimatedBuilder(
            animation: Listenable.merge([
              widget.appearing,
              widget.dismissed,
              widget.absorbed,
            ]),
            builder: (context, _) => CustomPaint(
              key: widget.painterKey,
              painter: ScanOverlayPainter(
                appearing: widget.appearing.value.clamp(0.0, 1.4),
                dismissed: widget.dismissed.value.clamp(0.0, 1.0),
                absorbed: widget.absorbed.value.clamp(0.0, 1.0),
                target: widget.target,
                windowFor: widget.windowFor,
                dimOpacity: widget.dimOpacity,
                accent: widget.accent,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Drives the three scalars for a scanner screen and disposes them together.
///
/// Kept separate from [ScanOverlay] so a page can start `appearing` when its
/// preview reports its first frame, and `absorbed`/`dismissed` when a code is
/// decoded — the same triggers Telegram uses.
final class ScanOverlayController {
  /// [vsync] must be a [TickerProviderStateMixin] (or another provider that
  /// allows more than one ticker): this drives three controllers.
  ScanOverlayController({required TickerProvider vsync, this.restingWindowBuilder})
      : appearing = AnimationController.unbounded(vsync: vsync, value: 0),
        dismissed = AnimationController.unbounded(vsync: vsync, value: 0),
        absorbed = AnimationController.unbounded(vsync: vsync, value: 0);

  /// 0..1, spring: Telegram's `SpringForce(500)`, damping ratio 0.8, stiffness
  /// 250 — converted to Flutter's (mass, stiffness, damping) form.
  final AnimationController appearing;

  /// 0..1, 300ms × distance with `cubic-bezier(0.25, 0.1, 0.25, 1)`.
  final AnimationController dismissed;

  /// 0..1, spring: damping ratio 1.0, stiffness 500.
  final AnimationController absorbed;

  final Rect Function(Size size)? restingWindowBuilder;

  static final SpringDescription _appearingSpring = SpringDescription(
    mass: 1,
    stiffness: 250,
    damping: 2 * math.sqrt(250) * 0.8,
  );
  static final SpringDescription _absorbedSpring = SpringDescription(
    mass: 1,
    stiffness: 500,
    damping: 2 * math.sqrt(500),
  );

  /// Telegram's curve for the found-code fade.
  static const Curve foundCurve = Cubic(0.25, 0.1, 0.25, 1);

  void startAppearing() {
    appearing.value = 0;
    appearing.animateWith(
      SpringSimulation(_appearingSpring, 0, 1, 0),
    );
  }

  /// How far the box is from the found state, for the bounce back when a code
  /// stops being read.
  void setFound(bool found) {
    final from = found ? absorbed.value : 1 - absorbed.value;
    absorbed.animateWith(SpringSimulation(_absorbedSpring, from, found ? 1 : 0, 0));
    dismissed.animateTo(
      found ? 1 : 0,
      duration: Duration(milliseconds: (300 * (found ? 1 - dismissed.value : dismissed.value)).round().clamp(1, 300)),
      curve: foundCurve,
    );
  }

  void dispose() {
    appearing.dispose();
    dismissed.dispose();
    absorbed.dispose();
  }
}

/// Paints the scrim, the box and the four corner brackets.
///
/// God object by design: this is one pass of a canvas, and splitting it would
/// only spread the same maths over three files.
final class ScanOverlayPainter extends CustomPainter {
  ScanOverlayPainter({
    required this.appearing,
    required this.dismissed,
    required this.absorbed,
    required this.target,
    required this.windowFor,
    required this.dimOpacity,
    required this.accent,
  });

  final double appearing;
  final double dismissed;
  final double absorbed;
  final List<Offset>? target;
  final Rect Function(Size size)? windowFor;
  final double dimOpacity;
  final Color accent;

  /// Telegram's resting square: `min(w, h) / 1.5`, centred, in logical pixels.
  static Rect restingSquare(Size size) {
    final side = math.min(size.width, size.height) / 1.5;
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side,
      height: side,
    );
  }

  /// The box while it appears: half size at 0, full size at 1.
  static double appearingScale(double appearing) =>
      0.5 + appearing.clamp(0.0, 1.0) * 0.5;

  /// The bracket stroke in logical pixels: Telegram reaches the full 4dp within
  /// the first 5% of the spring (`min(1, v * 20)`), so the ticks look like they
  /// are already there as the box grows.
  static double bracketStroke(double appearing) =>
      ui.lerpDouble(0, 4, math.min(1, appearing * 20))!;

  /// The bracket arm length: a whole box edge at rest, retracting to 20dp with
  /// Telegram's `pow(v, 1.8)`. This retraction *is* the opening animation.
  static double bracketLength(double side, double appearing) => ui.lerpDouble(
        side,
        20,
        math.min(1.2, math.pow(appearing.clamp(0.0, 1.2), 1.8).toDouble()),
      )!;

  /// The found code's bounds, padded the way Telegram pads them: 25dp across,
  /// 15dp down, in logical pixels.
  static Rect paddedTarget(
    List<Offset> corners,
    Size size, {
    double padX = 25,
    double padY = 15,
  }) {
    var left = corners.first.dx, right = corners.first.dx;
    var top = corners.first.dy, bottom = corners.first.dy;
    for (final point in corners) {
      left = math.min(left, point.dx);
      right = math.max(right, point.dx);
      top = math.min(top, point.dy);
      bottom = math.max(bottom, point.dy);
    }
    return Rect.fromLTRB(
      left * size.width - padX,
      top * size.height - padY,
      right * size.width + padX,
      bottom * size.height + padY,
    ).intersect(Offset.zero & size);
  }

  /// Blends the resting square onto the found target.
  static Rect blendFrame(Rect rest, Rect? found, double absorbed) =>
      found == null || absorbed <= 0
          ? rest
          : Rect.lerp(rest, found, absorbed.clamp(0.0, 1.0))!;

  /// The frame to draw: the resting square while nothing is found, the code's
  /// own bounds once something is, blended by [absorbed].
  Rect _frame(Size size) {
    final rest = (windowFor ?? restingSquare)(size);
    final corners = target;
    return blendFrame(
      rest,
      corners == null || corners.isEmpty
          ? null
          : paddedTarget(corners, size),
      absorbed,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // The box grows from half size while it appears.
    final frame = _frame(size);
    final scale = appearingScale(appearing);
    final box = Rect.fromCenter(
      center: frame.center,
      width: frame.width * scale,
      height: frame.height * scale,
    );

    // Scrim: four rectangles around the box, then the box interior, which the
    // appearing spring fades out and a found code keeps dark.
    final dim = dimOpacity + dismissed * 0.25;
    final scrim = Paint()
      ..color = Colors.black.withValues(alpha: dim.clamp(0.0, 1.0));
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, box.top), scrim);
    canvas.drawRect(
      Rect.fromLTRB(0, box.bottom, size.width, size.height),
      scrim,
    );
    canvas.drawRect(Rect.fromLTRB(0, box.top, box.left, box.bottom), scrim);
    canvas.drawRect(
      Rect.fromLTRB(box.right, box.top, size.width, box.bottom),
      scrim,
    );
    final inner = Paint()
      ..color = Colors.black.withValues(
        alpha: (dim * (1 - appearing.clamp(0.0, 1.0))).clamp(0.0, 1.0),
      );
    canvas.drawRect(box, inner);

    // Corner brackets: full-length edges that retract into ticks. `pow(1.8)`
    // and the `* 20` on the stroke are Telegram's.
    final progress = appearing.clamp(0.0, 1.2);
    final stroke = bracketStroke(progress);
    final length = bracketLength(math.min(box.width, box.height), progress);
    final bracket = Paint()
      ..color = accent.withValues(alpha: math.min(1, progress))
      ..style = PaintingStyle.fill;

    _bracket(canvas, bracket, box.topLeft, 1, 1, stroke, length);
    _bracket(canvas, bracket, box.topRight, -1, 1, stroke, length);
    _bracket(canvas, bracket, box.bottomLeft, 1, -1, stroke, length);
    _bracket(canvas, bracket, box.bottomRight, -1, -1, stroke, length);
  }

  /// One corner, drawn the way Telegram draws it: three arcs of radius
  /// `stroke / 2` (the arm ends), and the outer corner as an arc of radius
  /// `stroke` centred at `(1.5 × stroke, 1.5 × stroke)` inside the corner, so
  /// the tick looks extruded rather than mitred.
  void _bracket(
    Canvas canvas,
    Paint paint,
    Offset corner,
    int dx,
    int dy,
    double stroke,
    double length,
  ) {
    final half = stroke / 2;
    Offset at(double x, double y) =>
        Offset(corner.dx + dx * x, corner.dy + dy * y);
    final path = Path()
      // The two arm ends are rounded.
      ..moveTo(at(0, length).dx, at(0, length).dy)
      ..arcToPoint(at(0, length).translate(dx * half, 0), radius: Radius.circular(half))
      ..lineTo(at(half, length).dx, at(half, length).dy)
      // The inner elbow.
      ..lineTo(at(half, half).dx, at(half, half).dy)
      ..lineTo(at(length, half).dx, at(length, half).dy)
      // The arm end on the other side.
      ..arcToPoint(at(length, 0), radius: Radius.circular(half))
      // The outer corner: the arc Telegram centres at 1.5 × stroke.
      ..arcToPoint(
        at(0, half),
        radius: Radius.circular(stroke),
        largeArc: false,
      )
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(ScanOverlayPainter oldDelegate) =>
      oldDelegate.appearing != appearing ||
      oldDelegate.dismissed != dismissed ||
      oldDelegate.absorbed != absorbed ||
      oldDelegate.target != target ||
      oldDelegate.windowFor != windowFor ||
      oldDelegate.dimOpacity != dimOpacity ||
      oldDelegate.accent != accent;
}
