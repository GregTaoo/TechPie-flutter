import 'dart:convert';

import 'package:image_picker/image_picker.dart';

typedef BhMobileSdkJavaScriptRunner = Future<void> Function(String script);

Future<void> handleBhMobileSdkMessage(
  String message,
  BhMobileSdkJavaScriptRunner runJavaScript,
) async {
  Map<String, dynamic>? request;
  try {
    final decoded = jsonDecode(message);
    if (decoded is Map<String, dynamic>) request = decoded;
  } catch (_) {
    return;
  }

  if (request?['type'] != 'bh_mobile_sdk' ||
      request?['action'] != 'takePhoto') {
    return;
  }

  final requestId = request?['requestId'];
  if (requestId is! String || requestId.isEmpty) return;

  List<Map<String, String>> result = <Map<String, String>>[];
  try {
    final requestedLimit = request?['limit'];
    var limit = 1;
    if (requestedLimit is num) {
      limit = requestedLimit.toInt().clamp(1, 9);
    }
    final images = await ImagePicker().pickMultiImage();
    final selectedImages = images.take(limit);
    result = <Map<String, String>>[
      for (final image in selectedImages)
        <String, String>{
          'url': image.path,
          'base64': base64Encode(await image.readAsBytes()),
        },
    ];
  } catch (_) {
    // An empty result represents cancellation or an unavailable picker.
  }

  final response = jsonEncode(<String, dynamic>{
    'requestId': requestId,
    'result': result,
  });
  await runJavaScript(
    'window.__techPieHandleBhMobileSdkResponse(${jsonEncode(response)});',
  );
}

const String techPieDocumentStartScript = r'''
(() => {
  window.__techPieBridgeReady = true;
  window.__techPieResolve = window.__techPieResolve || ((value) => value);
  const callbacks = window.__bhMobileSdkCallbacks =
      window.__bhMobileSdkCallbacks || {};
  let requestSequence = 0;
  const nativeTechPieBridge = window.TechPieBridge &&
      typeof window.TechPieBridge.postMessage === 'function'
    ? window.TechPieBridge
    : null;

  window.TechPieBridge = window.TechPieBridge || {
    postMessage(message) {
      let messageText;
      try {
        messageText = typeof message === 'string' ? message : JSON.stringify(message);
        if (typeof messageText !== 'string') messageText = String(message);
      } catch (_) {
        messageText = String(message);
      }

      if (nativeTechPieBridge) return nativeTechPieBridge.postMessage(messageText);
      if (window.chrome && window.chrome.webview &&
          typeof window.chrome.webview.postMessage === 'function') {
        return window.chrome.webview.postMessage(messageText);
      }
      if (window.webkit && window.webkit.messageHandlers &&
          window.webkit.messageHandlers.TechPieBridge &&
          typeof window.webkit.messageHandlers.TechPieBridge.postMessage === 'function') {
        return window.webkit.messageHandlers.TechPieBridge.postMessage(messageText);
      }
      throw new Error('TechPieBridge native transport unavailable');
    },
  };

  window.__techPieHandleBhMobileSdkResponse = (message) => {
    let response;
    try {
      response = typeof message === 'string' ? JSON.parse(message) : message;
    } catch (_) {
      return;
    }
    const callback = callbacks[response && response.requestId];
    if (!callback) return;
    delete callbacks[response.requestId];
    callback(response.result || []);
  };

  const takePhoto = (callback, limit) => {
    const requestId = 'bh-photo-' + (++requestSequence);
    callbacks[requestId] = typeof callback === 'function' ? callback : () => {};
    window.TechPieBridge.postMessage(JSON.stringify({
      type: 'bh_mobile_sdk',
      action: 'takePhoto',
      requestId,
      limit: typeof limit === 'number' ? limit : 1,
    }));
  };

  const mamp = window.mamp || {};
  const systemAbility = mamp.systemAbility || {};
  systemAbility.takePhoto = takePhoto;
  mamp.systemAbility = systemAbility;
  try {
    Object.defineProperty(window, 'mamp', {
      configurable: true,
      get: () => mamp,
      set: (value) => Object.assign(mamp, value || {}),
    });
  } catch (_) {
    window.mamp = mamp;
  }
  window.BH_MOBILE_SDK = window.BH_MOBILE_SDK || {};
  window.BH_MOBILE_SDK.systemAbility =
      window.BH_MOBILE_SDK.systemAbility || {};
  window.BH_MOBILE_SDK.systemAbility.takePhoto = takePhoto;
  window.BH_MOBILE_SDK.bridge = window.TechPieBridge;
})();
''';
