import Flutter
import NetworkExtension

/// Starts the short-lived, single-domain resolver used to read a bind code in
/// the WeChat mini program. The packet tunnel has no default IP route.
final class EcardBindTunnelPlugin {
  private let channel: FlutterMethodChannel
  private let providerBundleIdentifier: String
  private var manager: NETunnelProviderManager?

  init(messenger: FlutterBinaryMessenger) {
    providerBundleIdentifier = "\(Bundle.main.bundleIdentifier ?? "com.example.techpie").EcardBindTunnel"
    channel = FlutterMethodChannel(name: "techpie/ecard_bind", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result("inactive")
        return
      }
      switch call.method {
      case "start": self.start(result)
      case "stop": self.stop(result)
      case "status": self.status(result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func load(_ completion: @escaping (NETunnelProviderManager?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      guard let self else {
        completion(nil)
        return
      }
      if error != nil {
        completion(self.manager)
        return
      }
      let selected = managers?.first {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
          == self.providerBundleIdentifier
      }
      self.manager = selected
      completion(selected)
    }
  }

  private func status(_ result: @escaping FlutterResult) {
    load { manager in
      result(manager?.connection.status == .connected ? "active" : "inactive")
    }
  }

  private func start(_ result: @escaping FlutterResult) {
    load { [weak self] existing in
      guard let self else {
        result("inactive")
        return
      }
      let manager = existing ?? NETunnelProviderManager()
      if manager.connection.status == .connected {
        result("active")
        return
      }
      let configuration = NETunnelProviderProtocol()
      configuration.providerBundleIdentifier = self.providerBundleIdentifier
      configuration.serverAddress = "TechPie eCard DNS"
      manager.protocolConfiguration = configuration
      manager.localizedDescription = "TechPie eCard 自动获取"
      manager.isEnabled = true
      manager.isOnDemandEnabled = false
      manager.saveToPreferences { error in
        guard error == nil else {
          result("inactive")
          return
        }
        manager.loadFromPreferences { error in
          guard error == nil else {
            result("inactive")
            return
          }
          self.manager = manager
          do {
            try manager.connection.startVPNTunnel()
            self.waitForConnection(manager, result: result, remaining: 20)
          } catch {
            result("inactive")
          }
        }
      }
    }
  }

  private func waitForConnection(
    _ manager: NETunnelProviderManager,
    result: @escaping FlutterResult,
    remaining: Int
  ) {
    if manager.connection.status == .connected {
      result("active")
    } else if remaining == 0 {
      manager.connection.stopVPNTunnel()
      result("inactive")
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let self else {
          result("inactive")
          return
        }
        self.waitForConnection(manager, result: result, remaining: remaining - 1)
      }
    }
  }

  private func stop(_ result: @escaping FlutterResult) {
    load { [weak self] manager in
      guard let self, let manager else {
        result(nil)
        return
      }
      manager.connection.stopVPNTunnel()
      self.waitForDisconnection(manager, result: result, remaining: 10)
    }
  }

  private func waitForDisconnection(
    _ manager: NETunnelProviderManager,
    result: @escaping FlutterResult,
    remaining: Int
  ) {
    let status = manager.connection.status
    if status == .disconnected || status == .invalid {
      result(nil)
    } else if remaining == 0 {
      result(FlutterError(code: "ECARD_TUNNEL_STILL_ACTIVE", message: "eCard DNS 仍在断开中", details: nil))
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let self else {
          result(nil)
          return
        }
        self.waitForDisconnection(manager, result: result, remaining: remaining - 1)
      }
    }
  }
}
