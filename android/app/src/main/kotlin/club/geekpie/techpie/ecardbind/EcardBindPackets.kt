package club.geekpie.techpie.ecardbind

/**
 * The little bit of IPv4/UDP the tunnel needs: recognise a DNS query taken off
 * the interface queue, and build the reply packet to put back into it.
 *
 * A socket on port 53 is not an option — port 53 is privileged, so binding to
 * it fails with EACCES — while reading and writing the interface needs no
 * privilege at all.
 */
internal object EcardBindPackets {
    const val UDP_PROTOCOL = 17

    private const val IPV4_HEADER = 20
    private const val UDP_HEADER = 8
    private const val VERSION_IPV4 = 0x40
    private const val FRAGMENT_MASK = 0x3FFF
    private const val DEFAULT_TTL = 64
    private const val FLAG_DONT_FRAGMENT = 0x4000

    /** A whole IPv4/UDP datagram, with its payload located in the packet. */
    class Datagram(
        val sourceAddress: ByteArray,
        val destinationAddress: ByteArray,
        val sourcePort: Int,
        val destinationPort: Int,
        val identification: Int,
        val payloadOffset: Int,
        val payloadLength: Int,
    )

    /** The UDP datagram inside [packet], or null when it is not a whole IPv4 one. */
    fun parseUdp(packet: ByteArray, length: Int): Datagram? {
        if (length < IPV4_HEADER) return null
        if (packet[0].toInt() and 0xF0 != VERSION_IPV4) return null
        val headerLength = (packet[0].toInt() and 0x0F) * 4
        if (headerLength < IPV4_HEADER || headerLength + UDP_HEADER > length) return null
        if (packet[9].toInt() and 0xFF != UDP_PROTOCOL) return null
        // Anything but a whole datagram (fragment offset, more fragments) is not
        // a DNS query; the resolver does not fragment them.
        val offsetAndFlags =
            ((packet[6].toInt() and 0xFF) shl 8) or (packet[7].toInt() and 0xFF)
        if (offsetAndFlags and FRAGMENT_MASK != 0) return null
        val udpLength =
            ((packet[headerLength + 4].toInt() and 0xFF) shl 8) or
                (packet[headerLength + 5].toInt() and 0xFF)
        if (udpLength < UDP_HEADER || headerLength + udpLength > length) return null
        return Datagram(
            sourceAddress = packet.copyOfRange(12, 16),
            destinationAddress = packet.copyOfRange(16, 20),
            sourcePort = portAt(packet, headerLength),
            destinationPort = portAt(packet, headerLength + 2),
            identification = ((packet[4].toInt() and 0xFF) shl 8) or (packet[5].toInt() and 0xFF),
            payloadOffset = headerLength + UDP_HEADER,
            payloadLength = udpLength - UDP_HEADER,
        )
    }

    /** An IPv4/UDP packet carrying [payload], addressed back at [query]'s sender. */
    fun buildUdpReply(query: Datagram, payload: ByteArray): ByteArray {
        val totalLength = IPV4_HEADER + UDP_HEADER + payload.size
        val packet = ByteArray(totalLength)
        packet[0] = (VERSION_IPV4 or (IPV4_HEADER / 4)).toByte()
        packet[2] = (totalLength shr 8).toByte()
        packet[3] = totalLength.toByte()
        packet[4] = (query.identification shr 8).toByte()
        packet[5] = query.identification.toByte()
        packet[6] = (FLAG_DONT_FRAGMENT shr 8).toByte()
        packet[7] = FLAG_DONT_FRAGMENT.toByte()
        packet[8] = DEFAULT_TTL.toByte()
        packet[9] = UDP_PROTOCOL.toByte()
        // Bytes 10..11 stay zero until the header checksum is written.
        System.arraycopy(query.destinationAddress, 0, packet, 12, 4)
        System.arraycopy(query.sourceAddress, 0, packet, 16, 4)
        val headerChecksum = complement(sumWords(0, packet, 0, IPV4_HEADER))
        packet[10] = (headerChecksum shr 8).toByte()
        packet[11] = headerChecksum.toByte()

        val udpLength = UDP_HEADER + payload.size
        packet[IPV4_HEADER] = (query.destinationPort shr 8).toByte()
        packet[IPV4_HEADER + 1] = query.destinationPort.toByte()
        packet[IPV4_HEADER + 2] = (query.sourcePort shr 8).toByte()
        packet[IPV4_HEADER + 3] = query.sourcePort.toByte()
        packet[IPV4_HEADER + 4] = (udpLength shr 8).toByte()
        packet[IPV4_HEADER + 5] = udpLength.toByte()
        System.arraycopy(payload, 0, packet, IPV4_HEADER + UDP_HEADER, payload.size)

        // Pseudo header: both addresses, then the zero byte and protocol as the
        // word 0x0011, then the UDP length.
        var running = sumWords(0, packet, 12, 8)
        running += UDP_PROTOCOL + udpLength
        running += sumWords(0, packet, IPV4_HEADER, UDP_HEADER + payload.size)
        var udpChecksum = complement(running)
        // Zero means "not computed" for UDP, which some receivers reject.
        if (udpChecksum == 0) udpChecksum = 0xFFFF
        packet[IPV4_HEADER + 6] = (udpChecksum shr 8).toByte()
        packet[IPV4_HEADER + 7] = udpChecksum.toByte()
        return packet
    }

    private fun portAt(packet: ByteArray, offset: Int): Int =
        ((packet[offset].toInt() and 0xFF) shl 8) or (packet[offset + 1].toInt() and 0xFF)

    private fun sumWords(initial: Int, packet: ByteArray, from: Int, count: Int): Int {
        var total = initial
        val end = from + count
        var index = from
        while (index + 1 < end) {
            total += ((packet[index].toInt() and 0xFF) shl 8) or
                (packet[index + 1].toInt() and 0xFF)
            index += 2
        }
        if (index < end) total += (packet[index].toInt() and 0xFF) shl 8
        return total
    }

    private fun complement(sum: Int): Int {
        var folded = sum
        while (folded shr 16 != 0) folded = (folded and 0xFFFF) + (folded shr 16)
        return folded.inv() and 0xFFFF
    }
}
