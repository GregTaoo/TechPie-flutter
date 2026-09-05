import Flutter
import UIKit

enum NativeGlassRegistry {
  static func registerAll(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let platformChannel = FlutterMethodChannel(
      name: "techpie/platform",
      binaryMessenger: messenger
    )

    platformChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "iosMajorVersion":
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        result(major)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let paymentSuccessImpact = UIImpactFeedbackGenerator(style: .heavy)
    let paymentSuccessNotification = UINotificationFeedbackGenerator()
    let paymentHapticsChannel = FlutterMethodChannel(
      name: "club.geekpie.pay/haptics",
      binaryMessenger: messenger
    )
    paymentHapticsChannel.setMethodCallHandler { call, result in
      guard call.method == "paymentSuccess" else {
        result(FlutterMethodNotImplemented)
        return
      }
      paymentSuccessImpact.prepare()
      paymentSuccessNotification.prepare()
      paymentSuccessImpact.impactOccurred(intensity: 1.0)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.085) {
        paymentSuccessNotification.notificationOccurred(.success)
      }
      result(nil)
    }

    registrar.register(
      NativeGlassTabBarFactory(messenger: messenger),
      withId: NativeGlassTabBarPlatformView.viewType
    )
    registrar.register(
      NativeNavigationBarFactory(messenger: messenger),
      withId: NativeNavigationBarPlatformView.viewType
    )

    NativeGlassPresenterPlugin.register(with: registrar)
    IcsFilePresenterPlugin.register(with: registrar)
  }
}
