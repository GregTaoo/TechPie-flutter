import Foundation

/// Answers only the eCard hostname while the temporary bind tunnel is running.
/// The system resolver sends this match domain into the tunnel. The extension
/// adds no default IP route.
enum EcardDnsPacket {
  static let resolverAddress: [UInt8] = [198, 18, 0, 1]

  /// Parses a dotted-quad IPv4 literal into its four octets. The mirror address
  /// arrives from Dart as a string; the tunnel hands back the octets verbatim.
  static func parseIpv4(_ address: String) -> [UInt8]? {
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets: [UInt8] = []
    octets.reserveCapacity(4)
    for part in parts {
      guard let value = UInt8(part) else { return nil }
      octets.append(value)
    }
    return octets
  }

  static func reply(to packet: Data, host: String, mirrorAddress: [UInt8]) -> Data? {
    let input = [UInt8](packet)
    guard input.count >= 28, input[0] >> 4 == 4 else { return nil }
    let ipHeaderLength = Int(input[0] & 0x0f) * 4
    guard ipHeaderLength >= 20, input.count >= ipHeaderLength + 8,
      input[9] == 17,
      Array(input[16..<20]) == resolverAddress,
      input[6] & 0x20 == 0,
      (UInt16(input[6] & 0x1f) << 8 | UInt16(input[7])) == 0
    else { return nil }

    let ipLength = Int(input[2]) << 8 | Int(input[3])
    let udp = ipHeaderLength
    let udpLength = Int(input[udp + 4]) << 8 | Int(input[udp + 5])
    guard ipLength <= input.count, ipLength >= udp + 8,
      udpLength >= 8, udp + udpLength <= ipLength,
      input[udp + 2] == 0, input[udp + 3] == 53
    else { return nil }

    guard let answer = dnsReply(
      Array(input[(udp + 8)..<(udp + udpLength)]),
      host: host,
      mirrorAddress: mirrorAddress
    ) else {
      return nil
    }
    let length = 28 + answer.count
    guard length <= 65_535 else { return nil }
    var output = [UInt8](repeating: 0, count: length)
    output[0] = 0x45
    output[2] = UInt8(length >> 8)
    output[3] = UInt8(length & 0xff)
    output[4] = input[4]
    output[5] = input[5]
    output[8] = 64
    output[9] = 17
    output.replaceSubrange(12..<16, with: resolverAddress)
    output.replaceSubrange(16..<20, with: input[12..<16])
    let ipChecksum = checksum(output[0..<20])
    output[10] = UInt8(ipChecksum >> 8)
    output[11] = UInt8(ipChecksum & 0xff)

    output[20] = 0
    output[21] = 53
    output[22] = input[udp]
    output[23] = input[udp + 1]
    let responseUdpLength = 8 + answer.count
    output[24] = UInt8(responseUdpLength >> 8)
    output[25] = UInt8(responseUdpLength & 0xff)
    // Zero is a valid UDP checksum for IPv4. The IP header itself is checked.
    output.replaceSubrange(28..<length, with: answer)
    return Data(output)
  }

  private static func dnsReply(
    _ query: [UInt8], host: String, mirrorAddress: [UInt8]
  ) -> [UInt8]? {
    guard query.count >= 17, query.count <= 4_096,
      query[2] & 0x80 == 0, query[2] & 0x78 == 0,
      query[4] == 0, query[5] == 1
    else { return nil }

    var labels: [String] = []
    var cursor = 12
    while cursor < query.count {
      let size = Int(query[cursor])
      cursor += 1
      if size == 0 { break }
      guard size <= 63, cursor + size <= query.count,
        let label = String(bytes: query[cursor..<(cursor + size)], encoding: .ascii)
      else { return nil }
      labels.append(label.lowercased())
      cursor += size
    }
    guard labels.joined(separator: ".") == host, cursor + 4 <= query.count,
      query[cursor + 2] == 0, query[cursor + 3] == 1
    else { return nil }

    let type = UInt16(query[cursor]) << 8 | UInt16(query[cursor + 1])
    let hasAddress = type == 1
    var response: [UInt8] = [
      query[0], query[1],
      UInt8(0x84 | (query[2] & 0x01)), 0x00, // answer, authoritative, original RD
      0, 1, 0, hasAddress ? 1 : 0,
      0, 0, 0, 0,
    ]
    response += query[12..<(cursor + 4)]
    if hasAddress {
      response += [
        0xc0, 0x0c, // pointer to the question's name
        0, 1, 0, 1, // A, IN
        0, 0, 0, 0, // do not cache the temporary binding address after disconnect
        0, 4,
      ]
      response += mirrorAddress
    }
    return response
  }

  private static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
    var sum: UInt32 = 0
    var index = bytes.startIndex
    while index < bytes.endIndex {
      let high = UInt32(bytes[index]) << 8
      index += 1
      let low = index < bytes.endIndex ? UInt32(bytes[index]) : 0
      index += 1
      sum += high | low
    }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
  }
}
