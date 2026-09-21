package club.geekpie.techpie.ecardbind

import java.net.Inet4Address

/**
 * The DNS wire format the bind tunnel speaks: echo the question, then either
 * append an A record pointing at the mirror or answer with no records at all so
 * the client falls back to IPv4.
 *
 * Deliberately free of Android types (only [Inet4Address]) and of the service,
 * so the encoding can be exercised on its own. The layout — 0x8180 in the
 * flags, a compressed name pointer 0xC00C for the answer — is the one the
 * desktop hijack script already serves the same records with.
 */
internal object EcardBindDns {
    const val TYPE_A = 1
    const val RCODE_SERVFAIL = 2

    private const val CLASS_IN = 1
    private const val TTL_SECONDS = 60
    private const val HEADER_SIZE = 12
    private const val QUESTION_TAIL = 4
    private const val ANSWER_SIZE = 16
    private const val COMPRESSION_MASK = 0xC0
    private const val RESPONSE_FLAGS = 0x80
    private const val RECURSION_DESIRED = 0x01
    private const val TRUNCATED = 0x02

    fun queryId(packet: ByteArray): Int =
        ((packet[0].toInt() and 0xFF) shl 8) or (packet[1].toInt() and 0xFF)

    /** The question of a DNS message, or null when it is not one we can read. */
    fun parseQuestion(packet: ByteArray, length: Int): Question? {
        val name = StringBuilder()
        var offset = HEADER_SIZE
        var terminated = false
        while (offset < length) {
            val labelLength = packet[offset].toInt() and 0xFF
            if (labelLength == 0) {
                offset += 1
                terminated = true
                break
            }
            // Compression pointers never appear in a question.
            if (labelLength and COMPRESSION_MASK != 0) return null
            if (offset + 1 + labelLength > length) return null
            if (name.isNotEmpty()) name.append('.')
            name.append(String(packet, offset + 1, labelLength, Charsets.US_ASCII))
            offset += 1 + labelLength
        }
        if (!terminated || offset + QUESTION_TAIL > length) return null
        val type =
            ((packet[offset].toInt() and 0xFF) shl 8) or (packet[offset + 1].toInt() and 0xFF)
        return Question(name.toString(), type, offset)
    }

    fun buildReply(
        id: Int,
        packet: ByteArray,
        question: Question,
        address: Inet4Address?,
        rcode: Int = 0,
        truncated: Boolean = false,
    ): ByteArray {
        val questionLength = question.typeOffset + QUESTION_TAIL - HEADER_SIZE
        val reply = ByteArray(
            HEADER_SIZE + questionLength + if (address == null) 0 else ANSWER_SIZE,
        )
        reply[0] = (id shr 8).toByte()
        reply[1] = id.toByte()
        // Response, recursion available, and the query's own RD bit echoed back:
        // a resolver that asked for recursion is entitled to see it mirrored.
        reply[2] = (
            RESPONSE_FLAGS or
                (packet[2].toInt() and RECURSION_DESIRED) or
                (if (truncated) TRUNCATED else 0)
            ).toByte()
        reply[3] = (RESPONSE_FLAGS or rcode).toByte()
        // One question, one answer at most, and no authority or additional records.
        reply[5] = 1
        if (address != null) reply[7] = 1
        System.arraycopy(packet, HEADER_SIZE, reply, HEADER_SIZE, questionLength)
        if (address == null) return reply

        var offset = HEADER_SIZE + questionLength
        reply[offset++] = 0xC0.toByte()
        reply[offset++] = 0x0C
        reply[offset++] = 0
        reply[offset++] = TYPE_A.toByte()
        reply[offset++] = 0
        reply[offset++] = CLASS_IN.toByte()
        reply[offset++] = 0
        reply[offset++] = 0
        reply[offset++] = 0
        reply[offset++] = TTL_SECONDS.toByte()
        reply[offset++] = 0
        reply[offset++] = 4
        System.arraycopy(address.address, 0, reply, offset, 4)
        return reply
    }

    class Question(val name: String, val type: Int, val typeOffset: Int)
}
