import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private var running = false
  // Fallbacks match Dart's EcardBindHijackService; the host and mirror address
  // normally arrive in the provider configuration on every start.
  private var matchHost = "ecard.shanghaitech.edu.cn"
  private var mirrorAddress: [UInt8] = [119, 78, 254, 196]

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    if let providerConfiguration =
      (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
    {
      if let host = providerConfiguration["host"] as? String, !host.isEmpty {
        matchHost = host
      }
      if let ip = providerConfiguration["ip"] as? String,
        let address = EcardDnsPacket.parseIpv4(ip)
      {
        mirrorAddress = address
      }
    }

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
    let ipv4 = NEIPv4Settings(
      addresses: ["198.18.0.2"],
      subnetMasks: ["255.255.255.252"]
    )
    ipv4.includedRoutes = [
      NEIPv4Route(destinationAddress: "198.18.0.1", subnetMask: "255.255.255.255")
    ]
    settings.ipv4Settings = ipv4
    let dns = NEDNSSettings(servers: ["198.18.0.1"])
    dns.matchDomains = [matchHost]
    dns.matchDomainsNoSearch = true
    settings.dnsSettings = dns

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else {
        completionHandler(error)
        return
      }
      if error == nil {
        self.running = true
        self.readPackets()
      }
      completionHandler(error)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    running = false
    completionHandler()
  }

  private func readPackets() {
    packetFlow.readPackets { [weak self] packets, _ in
      guard let self, self.running else { return }
      let replies = packets.compactMap {
        EcardDnsPacket.reply(to: $0, host: self.matchHost, mirrorAddress: self.mirrorAddress)
      }
      if !replies.isEmpty {
        _ = self.packetFlow.writePackets(
          replies,
          withProtocols: Array(repeating: NSNumber(value: AF_INET), count: replies.count)
        )
      }
      self.readPackets()
    }
  }
}
