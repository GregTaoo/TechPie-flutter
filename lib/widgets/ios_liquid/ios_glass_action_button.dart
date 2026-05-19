import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum IosGlassActionButtonVariant { automatic, glass, clearGlass }

class IosGlassActionButton extends StatefulWidget {
  const IosGlassActionButton({
    super.key,
    required this.onPressed,
    this.label,
    this.icon,
    required this.sfSymbol,
    this.destructive = false,
    this.enabled = true,
    this.width,
    this.height = 36,
    this.animateOnAppear = false,
    this.variant = IosGlassActionButtonVariant.automatic,
  });

  final VoidCallback onPressed;
  final String? label;
  final IconData? icon;
  final String sfSymbol;
  final bool destructive;
  final bool enabled;
  final double? width;
  final double height;
  final bool animateOnAppear;
  final IosGlassActionButtonVariant variant;

  @override
  State<IosGlassActionButton> createState() => _IosGlassActionButtonState();
}

class _IosGlassActionButtonState extends State<IosGlassActionButton> {
  MethodChannel? _channel;

  bool get _usesNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_usesNative) {
      if (widget.label == null || widget.label!.isEmpty) {
        return IconButton(
          onPressed: widget.enabled ? widget.onPressed : null,
          icon: Icon(widget.icon ?? Icons.circle, size: 18),
        );
      }

      if (widget.icon == null) {
        return TextButton(
          onPressed: widget.enabled ? widget.onPressed : null,
          child: Text(widget.label!),
        );
      }

      return TextButton.icon(
        onPressed: widget.enabled ? widget.onPressed : null,
        icon: Icon(widget.icon, size: 18),
        label: Text(widget.label!),
      );
    }

    final width =
        widget.width ??
        ((widget.label == null || widget.label!.isEmpty) ? 36.0 : 92.0);

    return SizedBox(
      width: width,
      height: widget.height,
      child: UiKitView(
        viewType: _viewType,
        layoutDirection: Directionality.of(context),
        creationParams: <String, Object?>{
          'label': widget.label,
          'sfSymbol': widget.sfSymbol,
          'destructive': widget.destructive,
          'enabled': widget.enabled,
          'animateOnAppear': widget.animateOnAppear,
          'glassVariant': widget.variant.name,
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant IosGlassActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!_usesNative) return;
    final channel = _channel;
    if (channel == null) return;

    final changed =
        oldWidget.label != widget.label ||
        oldWidget.sfSymbol != widget.sfSymbol ||
        oldWidget.destructive != widget.destructive ||
        oldWidget.enabled != widget.enabled ||
        oldWidget.variant != widget.variant;

    if (!changed) return;

    unawaited(_sendConfigurationUpdate(channel));
  }

  Future<void> _sendConfigurationUpdate(MethodChannel channel) async {
    try {
      await channel.invokeMethod<void>('updateConfiguration', <String, Object?>{
        'label': widget.label,
        'sfSymbol': widget.sfSymbol,
        'destructive': widget.destructive,
        'enabled': widget.enabled,
        'glassVariant': widget.variant.name,
      });
    } on PlatformException {
      // Platform view may be tearing down.
    } on MissingPluginException {
      // Platform view may not be wired yet.
    }
  }

  void _onPlatformViewCreated(int viewId) {
    final channel = MethodChannel('$_channelPrefix/$viewId');
    _channel?.setMethodCallHandler(null);
    _channel = channel;

    channel.setMethodCallHandler((call) async {
      if (call.method != 'onPressed') return null;
      widget.onPressed();
      return null;
    });
  }
}

const _viewType = 'techpie/native_glass_action_button';
const _channelPrefix = 'techpie/native_glass_action_button';
