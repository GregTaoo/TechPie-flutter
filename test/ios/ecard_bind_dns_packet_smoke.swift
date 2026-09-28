import Foundation

@main
enum EcardBindDnsPacketSmoke {
  static func main() {
    let host = "ecard.shanghaitech.edu.cn"
    let mirror: [UInt8] = [119, 78, 254, 196]
    let a = makePacket(host: host, type: 1)
    guard let answer = EcardDnsPacket.reply(to: Data(a), host: host, mirrorAddress: mirror) else {
      fatalError("A query did not receive a reply")
    }
    let bytes = [UInt8](answer)
    precondition(Array(bytes[12..<16]) == EcardDnsPacket.resolverAddress)
    precondition(Array(bytes[16..<20]) == [10, 0, 0, 2])
    precondition(bytes[20] == 0 && bytes[21] == 53)
    precondition(bytes[22] == 0xbe && bytes[23] == 0xef)
    precondition(bytes[34] == 0 && bytes[35] == 1, "A answer count")
    precondition(Array(bytes.suffix(4)) == mirror)
    precondition(
      Array(bytes[(bytes.count - 10)..<(bytes.count - 6)]) == [0, 0, 0, 0],
      "The temporary binding address must have a zero TTL"
    )
    precondition(validChecksum(bytes[0..<20]))

    let aaaa = makePacket(host: "ecard.shanghaitech.edu.cn", type: 28)
    guard let empty = EcardDnsPacket.reply(to: Data(aaaa), host: host, mirrorAddress: mirror) else {
      fatalError("AAAA query did not receive a negative reply")
    }
    let emptyBytes = [UInt8](empty)
    precondition(emptyBytes[34] == 0 && emptyBytes[35] == 0, "AAAA must not hijack IPv6")
    precondition(
      EcardDnsPacket.reply(
        to: Data(makePacket(host: "example.org", type: 1)),
        host: host,
        mirrorAddress: mirror
      ) == nil
    )

    var fragment = a
    fragment[6] = 0x20
    precondition(
      EcardDnsPacket.reply(to: Data(fragment), host: host, mirrorAddress: mirror) == nil
    )
    print("EcardBindDnsPacketSmoke passed")
  }

  private static func makePacket(host: String, type: UInt16) -> [UInt8] {
    var query: [UInt8] = [
      0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
    ]
    for label in host.split(separator: ".") {
      query.append(UInt8(label.utf8.count))
      query += label.utf8
    }
    query += [0, UInt8(type >> 8), UInt8(type & 0xff), 0, 1]
    let udpLength = 8 + query.count
    let ipLength = 20 + udpLength
    var packet: [UInt8] = [
      0x45, 0, UInt8(ipLength >> 8), UInt8(ipLength & 0xff),
      0x12, 0x34, 0, 0, 64, 17, 0, 0,
      10, 0, 0, 2, 198, 18, 0, 1,
      0xbe, 0xef, 0, 53,
      UInt8(udpLength >> 8), UInt8(udpLength & 0xff), 0, 0,
    ]
    packet += query
    return packet
  }

  private static func validChecksum(_ bytes: ArraySlice<UInt8>) -> Bool {
    var sum = 0
    var index = bytes.startIndex
    while index < bytes.endIndex {
      sum += Int(bytes[index]) << 8 | Int(bytes[index + 1])
      index += 2
    }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return sum == 0xffff
  }
}
