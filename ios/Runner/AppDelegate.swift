import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var ecardDeepLinkChannel: FlutterMethodChannel?
  private var pendingEcardRoute: String?
  private var ecardFeedback: EcardFeedback?

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
    ecardFeedback = EcardFeedback(registrar: registrar)

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
      case "widgetAvailability":
        if #available(iOS 14.0, *) {
          WidgetCenter.shared.reloadTimelines(ofKind: "EcardPayWidget")
          result("manual")
        } else {
          result("unsupported")
        }
      case "requestPinWidget":
        result(false)
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
