import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../utils/haptics.dart';
import '../adaptive_page_navigation.dart';
import 'scan_overlay.dart';

/// Opens the shared scanner and resolves with the raw decoded string, or null
/// when the user backs out.
///
/// One scanner for the whole app: a campus-card payment code, a student-activity
/// check-in, whatever comes next. Callers get the code verbatim and own what it
/// means; the screen owns the camera, the viewfinder and its animations.
Future<String?> showTechPieScanner(
  BuildContext context, {
  String title = '扫描二维码',
  String hint = '将二维码放入框内，即可自动扫描',
  bool torch = true,
  MobileScannerController? controller,
  Widget Function(BuildContext context)? previewBuilder,
  Duration settleBeforePop = const Duration(milliseconds: 220),
}) {
  return pushAdaptivePage<String>(
    context,
    builder: (_) => TechPieScanPage(
      title: title,
      hint: hint,
      torch: torch,
      controller: controller,
      previewBuilder: previewBuilder,
      settleBeforePop: settleBeforePop,
    ),
  );
}

/// The scanner screen itself, for callers that want to place it themselves.
///
/// The viewfinder is [ScanOverlay]: Telegram's spring-opened box, the brackets
/// that retract into ticks, and the frame that springs onto the found code
/// before the result is handed back.
final class TechPieScanPage extends StatefulWidget {
  const TechPieScanPage({
    super.key,
    this.title = '扫描二维码',
    this.hint = '将二维码放入框内，即可自动扫描',
    this.torch = true,
    this.controller,
    this.previewBuilder,
    this.settleBeforePop = const Duration(milliseconds: 220),
  });

  final String title;
  final String hint;
  final bool torch;

  /// Injected in tests; owned by the page otherwise.
  final MobileScannerController? controller;

  /// Replaces the camera preview, so the overlay can be driven without a camera.
  final Widget Function(BuildContext context)? previewBuilder;

  /// How long the found animation is left on screen before the result is
  /// returned — the whole point of the animation is that the payer sees it.
  final Duration settleBeforePop;

  @override
  State<TechPieScanPage> createState() => _TechPieScanPageState();
}

final class _TechPieScanPageState extends State<TechPieScanPage>
    with TickerProviderStateMixin {
  late final MobileScannerController _controller =
      widget.controller ?? MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  late final ScanOverlayController _overlay =
      ScanOverlayController(vsync: this);
  bool _ownsController = false;
  bool _handled = false;
  List<Offset>? _target;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    unawaited(_startPreview());
  }

  Future<void> _startPreview() async {
    try {
      await _controller.start();
    } catch (_) {
      // A device without a usable camera keeps the fallback preview.
    }
    if (!mounted) return;
    // Telegram starts its opening spring when the camera session is ready, not
    // when the view is created.
    _overlay.startAppearing();
  }

  @override
  void dispose() {
    _overlay.dispose();
    if (_ownsController) unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _handled = true;
      // The frame springs onto the code's own corners (`Barcode.corners`),
      // padded the way Telegram pads them, while the chrome fades out.
      setState(() => _target = barcode.corners);
      _overlay.setFound(true);
      unawaited(AppHaptics.play(AppHaptics.mediumImpact));
      unawaited(_finish(value));
      return;
    }
  }

  Future<void> _finish(String value) async {
    await Future<void>.delayed(widget.settleBeforePop);
    if (!mounted) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(widget.title),
      ),
      body: ScanOverlay(
        appearing: _overlay.appearing,
        dismissed: _overlay.dismissed,
        absorbed: _overlay.absorbed,
        target: _target,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.previewBuilder?.call(context) ?? _preview(),
            if (widget.torch) _torchButton(),
            _hint(),
          ],
        ),
      ),
    );
  }

  Widget _preview() {
    return MobileScanner(
      controller: _controller,
      onDetect: _onDetect,
      errorBuilder: (context, error, _) => const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 42),
            child: Text(
              '当前设备没有可用相机，请从相册选择二维码图片。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
            ),
          ),
        ),
      ),
    );
  }

  Widget _torchButton() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 96),
        child: _TorchButton(controller: _controller),
      ),
    );
  }

  /// Telegram's hint under the box: it fades out with the same scalar as the
  /// title once a code is found.
  Widget _hint() {
    return Align(
      alignment: const Alignment(0, 0.62),
      child: AnimatedBuilder(
        animation: _overlay.dismissed,
        builder: (context, child) => Opacity(
          opacity: (1 - _overlay.dismissed.value).clamp(0.0, 1.0),
          child: child,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Text(
            widget.hint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ),
    );
  }
}

final class _TorchButton extends StatefulWidget {
  const _TorchButton({required this.controller});

  final MobileScannerController controller;

  @override
  State<_TorchButton> createState() => _TorchButtonState();
}

final class _TorchButtonState extends State<_TorchButton> {
  bool _on = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: _on ? 0.32 : 0.18),
      shape: const CircleBorder(),
      child: IconButton(
        onPressed: () async {
          try {
            await widget.controller.toggleTorch();
          } catch (_) {
            return;
          }
          if (!mounted) return;
          setState(() => _on = !_on);
        },
        icon: Icon(_on ? Icons.flash_on : Icons.flash_off, color: Colors.white),
        tooltip: _on ? '关闭手电筒' : '打开手电筒',
      ),
    );
  }
}
