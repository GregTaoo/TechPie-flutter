# iOS camera capture adaptation

`mobile_scanner_capture.patch` adapts the pinned `mobile_scanner 7.0.0-beta.6`
Darwin implementation for TechPie's scanner. The package is BSD-3-Clause,
copyright Julian Steenbakker; its source and license remain in the original
Flutter dependency. This does not change package versions or download sources.

The upstream implementation uses a photo session preset, converts camera frames
to BGRA and then creates a CGImage for each Vision request. The adaptation:

- Chooses 1080p video, with 720p/VGA fallbacks when unavailable.
- Uses a supported NV12 format when possible. Flutter 3.27's FlutterTexture
  contract and Vision both accept 420f/420v pixel buffers; BGRA remains a fallback.
- Requests up to 60 fps within the selected device format's supported range,
  permitting exposure to fall back to 30 fps. Unsupported formats retain defaults.
- Sends the retained frame directly to Vision, creating a CGImage/JPEG only
  when image bytes were explicitly requested and a barcode was found.
- Locks preview-buffer exchange with Flutter's raster thread and ignores
  detection results or queued frames belonging to a stopped camera session.

The capture callback remains on the plugin's main queue. Recognition runs in
the background and eligibility/completion state is updated on the main queue.
The Dart adapter independently limits recognition attempts to every 250 ms;
that interval does not limit preview texture updates. The visible guide and
recognition region share the same geometry.

The Podfile's post-install hook verifies the upstream source checksum, applies
the patch to `ios/Pods/TechPiePatches/MobileScannerPlugin.swift`, and compiles that
generated copy. It never modifies the shared pub cache. Re-running `pod install`
recreates the copy from the same original source. A dependency update requires
reviewing this patch and checksum; mismatches fail the build rather than silently
using a different implementation.

To regenerate the local pod project:

```sh
pod install --project-directory=ios --no-repo-update
```

The generated Swift file must not be edited or committed. Patch files preserve
upstream whitespace, so whitespace checking is disabled only for `.patch` files
in this directory.

Validation must distinguish successful builds and synthetic QR decoding from
physical-camera frame-rate and low-light checks. The 60 fps setting is a request,
not a measured guarantee.

A physical iPhone 16 Pro Max comparison on 2026-09-07 measured 16.11 fps
before and 30.00 fps after, using roughly 12-second native capture samples
following a two-second warmup. Low Power Mode was off and thermal state was
nominal in both runs. Frame intervals over 50 ms fell from 186 to zero; the
longest interval fell from 66.67 to 33.33 ms. The selected optimized camera
format supported 30 fps in this run, so 60 fps was not verified.

Vision request count (including warmup) fell from 229 to 53, with cumulative
request wall time falling from 7.00 to 1.01 seconds. These are native capture
and recognition measurements, not Flutter raster FPS or battery measurements.
Temporary counters recorded metadata only and are absent from the final app.
