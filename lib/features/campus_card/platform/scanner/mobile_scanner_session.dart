import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/async_mutex.dart';
import '../../core/errors/app_failure.dart';
import '../../domain/ports/platform_ports.dart';

/// Shared scanner controller for every platform the pinned mobile_scanner fork
/// supports — Android, iOS and OHOS — through one code path.
/// Presentation uses [controller] only to attach the plugin-owned camera
/// preview; all scanning operations remain behind [ScannerPort].
final class MobileScannerSession implements ScannerPort {
  MobileScannerSession({
    MobileScannerController? controller,
    ImagePicker? imagePicker,
  })  : controller = controller ??
            MobileScannerController(
              autoStart: false,
              // Decode at most four times a second without throttling preview.
              // ScannerModal gates duplicate results before any submission.
              detectionSpeed: DetectionSpeed.normal,
              detectionTimeoutMs: 250,
              facing: CameraFacing.back,
              formats: const [BarcodeFormat.qrCode],
              returnImage: false,
            ),
        _imagePicker = imagePicker ?? ImagePicker() {
    _subscription = this.controller.barcodes.listen(
          _acceptCapture,
          onError: _codes.addError,
        );
  }

  final MobileScannerController controller;
  final ImagePicker _imagePicker;
  final StreamController<ScannerReading> _codes =
      StreamController<ScannerReading>.broadcast(
    sync: true,
  );
  late final StreamSubscription<BarcodeCapture> _subscription;
  final _transitions = AsyncMutex();
  bool _running = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  @override
  Stream<ScannerReading> get scannedCodes => _codes.stream;

  @override
  Future<void> start() => _transitions.protect(_start);

  Future<void> _start() async {
    _ensureActive();
    if (_running) return;
    try {
      await controller.start();
      // mobile_scanner records startup failures in its value without throwing.
      // Do not mark a failed camera as running or suppress the next retry.
      final error = controller.value.error;
      if (error != null) throw error;
      _running = true;
    } on MobileScannerException catch (error) {
      throw AppFailure(
        FailureKind.permissionDenied,
        '无法启动相机，请检查相机权限。',
        code: 'SCANNER_START_FAILED',
        cause: error,
      );
    }
  }

  @override
  Future<void> stop() => _transitions.protect(_stop);

  Future<void> _stop() async {
    if (_disposed || !_running) return;
    await controller.stop();
    _running = false;
  }

  @override
  Future<void> setTorch(bool enabled) async {
    _ensureActive();
    final current = controller.value.torchState;
    if (current == TorchState.unavailable) {
      throw const AppFailure(
        FailureKind.unavailable,
        '当前设备不支持手电筒。',
        code: 'SCANNER_TORCH_UNAVAILABLE',
      );
    }
    final isEnabled = current == TorchState.on;
    if (isEnabled != enabled) await controller.toggleTorch();
  }

  @override
  Future<String?> scanImage() async {
    _ensureActive();
    final path =
        (await _imagePicker.pickImage(source: ImageSource.gallery))?.path;
    if (path == null) return null;
    final capture = await controller.analyzeImage(path);
    return _firstValue(capture);
  }

  Future<void> dispose() => _disposeFuture ??= _transitions.protect(_dispose);

  Future<void> _dispose() async {
    if (_disposed) return;
    await _stop();
    _disposed = true;
    await _subscription.cancel();
    await _codes.close();
    await controller.dispose();
  }

  void _acceptCapture(BarcodeCapture capture) {
    if (_codes.isClosed) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _codes.add(
        ScannerReading(
          value,
          corners: _normalisedCorners(barcode, capture.size),
        ),
      );
      return;
    }
  }

  /// The decoded corners in 0..1 against the frame they were read from — the
  /// same space the viewfinder draws in, so the frame can land on the code.
  List<Offset>? _normalisedCorners(Barcode barcode, Size frame) {
    final corners = barcode.corners;
    if (corners.isEmpty) return null;
    if (frame.width <= 0 || frame.height <= 0) return null;
    return [
      for (final point in corners)
        Offset(point.dx / frame.width, point.dy / frame.height),
    ];
  }

  String? _firstValue(BarcodeCapture? capture) {
    if (capture == null) return null;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('MobileScannerSession is disposed');
  }
}
