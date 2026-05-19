import Flutter
import UIKit

private final class NativeGlassActionButtonRootView: UIView {
  var onDidMoveToWindow: (() -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onDidMoveToWindow?()
  }
}

final class NativeGlassActionButtonFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NativeGlassActionButtonPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args,
      messenger: messenger
    )
  }
}

final class NativeGlassActionButtonPlatformView: NSObject, FlutterPlatformView {
  static let viewType = "techpie/native_glass_action_button"

  private let rootView: NativeGlassActionButtonRootView
  private let channel: FlutterMethodChannel
  private let backgroundView = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemChromeMaterial)
  )
  private let button = UIButton(type: .system)

  private var label: String?
  private var sfSymbol = "circle"
  private var destructive = false
  private var enabled = true
  private var animateOnAppear = false
  private var glassVariant = "automatic"
  private var hasAnimatedIn = false

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: Any?,
    messenger: FlutterBinaryMessenger
  ) {
    rootView = NativeGlassActionButtonRootView(frame: frame)
    channel = FlutterMethodChannel(
      name: "\(Self.viewType)/\(viewId)",
      binaryMessenger: messenger
    )

    super.init()

    rootView.onDidMoveToWindow = { [weak self] in
      self?.animateIntoPlaceIfNeeded()
    }

    parseArguments(args)
    buildViewHierarchy()
    applyButtonAppearance()
    button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    rootView
  }

  private func parseArguments(_ args: Any?) {
    guard let params = args as? [String: Any] else { return }

    label = params["label"] as? String
    if let rawSymbol = params["sfSymbol"] as? String, !rawSymbol.isEmpty {
      sfSymbol = rawSymbol
    }
    destructive = params["destructive"] as? Bool ?? false
    enabled = params["enabled"] as? Bool ?? true
    animateOnAppear = params["animateOnAppear"] as? Bool ?? animateOnAppear
    glassVariant = params["glassVariant"] as? String ?? glassVariant
  }

  private func handle(call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "updateConfiguration":
      parseArguments(call.arguments)
      animateConfigurationUpdate()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func buildViewHierarchy() {
    rootView.backgroundColor = .clear
    rootView.clipsToBounds = false

    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityTraits.insert(.button)
    button.clipsToBounds = false

    if #available(iOS 26.0, *) {
      rootView.addSubview(button)

      NSLayoutConstraint.activate([
        button.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
        button.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
        button.topAnchor.constraint(equalTo: rootView.topAnchor),
        button.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
      ])
      return
    }

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.clipsToBounds = true
    backgroundView.layer.cornerRadius = 18
    backgroundView.layer.borderWidth = 1
    backgroundView.layer.borderColor = NativeGlassColors.controlBorder.cgColor
    backgroundView.layer.shadowColor = UIColor.black.cgColor
    backgroundView.layer.shadowOpacity = 0.08
    backgroundView.layer.shadowRadius = 10
    backgroundView.layer.shadowOffset = CGSize(width: 0, height: 6)

    if #available(iOS 13.0, *) {
      backgroundView.layer.cornerCurve = .continuous
    }

    rootView.addSubview(backgroundView)
    backgroundView.contentView.addSubview(button)

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: rootView.topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      button.leadingAnchor.constraint(equalTo: backgroundView.contentView.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: backgroundView.contentView.trailingAnchor),
      button.topAnchor.constraint(equalTo: backgroundView.contentView.topAnchor),
      button.bottomAnchor.constraint(equalTo: backgroundView.contentView.bottomAnchor)
    ])
  }

  private func applyButtonAppearance() {
    if #available(iOS 26.0, *) {
      applyLiquidGlassAppearance()
      return
    }

    let foregroundColor = destructive
      ? NativeGlassColors.destructiveRed
      : NativeGlassColors.floatingButtonForeground
    let image = symbolImage(named: sfSymbol)
    rootView.alpha = enabled ? 1.0 : 0.45
    button.isEnabled = enabled

    if #available(iOS 15.0, *) {
      var configuration = UIButton.Configuration.plain()
      configuration.image = image
      configuration.title = label
      configuration.baseForegroundColor = foregroundColor
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 8,
        leading: 12,
        bottom: 8,
        trailing: 12
      )
      configuration.imagePadding = label == nil || label?.isEmpty == true ? 0 : 6
      configuration.cornerStyle = .capsule
      button.configuration = configuration
    } else {
      button.setImage(image, for: .normal)
      button.setTitle(label, for: .normal)
      button.tintColor = foregroundColor
      button.setTitleColor(foregroundColor, for: .normal)
      button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
      button.titleEdgeInsets = label == nil || label?.isEmpty == true
        ? .zero
        : UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
    }
  }

  @available(iOS 26.0, *)
  private func applyLiquidGlassAppearance() {
    let foregroundColor = destructive
      ? NativeGlassColors.destructiveRed
      : NativeGlassColors.floatingButtonForeground
    let image = symbolImage(named: sfSymbol)
    let disabledAlpha = enabled ? 1.0 : 0.45
    rootView.alpha = disabledAlpha
    button.isEnabled = enabled

    let useClearGlass: Bool
    switch glassVariant {
    case "glass":
      useClearGlass = false
    case "clearGlass":
      useClearGlass = true
    default:
      useClearGlass = label == nil || label?.isEmpty == true
    }

    var configuration: UIButton.Configuration =
      useClearGlass ? .clearGlass() : .glass()
    configuration.image = image
    configuration.title = label
    configuration.baseForegroundColor = foregroundColor
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8,
      leading: 12,
      bottom: 8,
      trailing: 12
    )
    configuration.imagePadding = image == nil || label == nil || label?.isEmpty == true
      ? 0
      : 6
    configuration.cornerStyle = .capsule

    button.configuration = configuration
    button.tintColor = foregroundColor
    button.backgroundColor = .clear
    button.layer.shadowOpacity = 0
    button.layer.borderWidth = 0
    button.setNeedsUpdateConfiguration()
  }

  private func animateConfigurationUpdate() {
    if #available(iOS 26.0, *) {
      UIView.transition(
        with: button,
        duration: 0.24,
        options: [.transitionCrossDissolve, .curveEaseInOut, .allowUserInteraction]
      ) {
        self.applyButtonAppearance()
      }
      return
    }

    UIView.animate(
      withDuration: 0.20,
      delay: 0,
      options: [.curveEaseInOut, .allowUserInteraction]
    ) {
      self.applyButtonAppearance()
      self.rootView.layoutIfNeeded()
    }
  }

  private func animateIntoPlaceIfNeeded() {
    guard animateOnAppear, !hasAnimatedIn, rootView.window != nil else {
      return
    }

    hasAnimatedIn = true
    rootView.alpha = 0
    rootView.transform = CGAffineTransform(
      translationX: 0,
      y: 10
    ).scaledBy(x: 0.96, y: 0.96)

    UIView.animate(
      withDuration: 0.34,
      delay: 0,
      usingSpringWithDamping: 0.86,
      initialSpringVelocity: 0.18,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.rootView.alpha = self.enabled ? 1.0 : 0.45
      self.rootView.transform = .identity
    }
  }

  private func symbolImage(named systemName: String) -> UIImage? {
    guard systemName != "none" else { return nil }

    let configuration = UIImage.SymbolConfiguration(
      pointSize: 14,
      weight: .semibold,
      scale: .medium
    )

    return UIImage(systemName: systemName, withConfiguration: configuration)?
      .withRenderingMode(.alwaysTemplate)
  }

  @objc
  private func handleTap() {
    guard enabled else { return }
    let feedback = UIImpactFeedbackGenerator(style: .light)
    feedback.impactOccurred(intensity: 0.55)
    channel.invokeMethod("onPressed", arguments: nil)
  }
}
