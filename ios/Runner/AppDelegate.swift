import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var ecardDeepLinkChannel: FlutterMethodChannel?
  private var pendingEcardRoute: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard
      let registrar = self.registrar(
        forPlugin: "TechPieNativeGlassRegistry"
      )
    else {
      assertionFailure("Failed to create registrar for TechPieNativeGlassRegistry")
      return false
    }

    NativeGlassRegistry.registerAll(with: registrar)

    let deepLinkChannel = FlutterMethodChannel(
      name: "techpie/ecard_deep_link",
      binaryMessenger: registrar.messenger()
    )
    deepLinkChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "consumePendingRoute":
        result(self.pendingEcardRoute)
      case "acknowledgePendingRoute":
        self.pendingEcardRoute = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    ecardDeepLinkChannel = deepLinkChannel

    if let url = launchOptions?[.url] as? URL {
      _ = captureEcardPayURL(url, notifyFlutter: false)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if captureEcardPayURL(url, notifyFlutter: true) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  private func captureEcardPayURL(_ url: URL, notifyFlutter: Bool) -> Bool {
    guard
      url.scheme?.lowercased() == "techpie",
      url.host?.lowercased() == "ecard",
      url.path.lowercased() == "/pay"
    else {
      return false
    }
    pendingEcardRoute = "pay"
    if notifyFlutter {
      ecardDeepLinkChannel?.invokeMethod("openPayCode", arguments: nil)
    }
    return true
  }
}
