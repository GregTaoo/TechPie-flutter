package club.geekpie.techpie.ecardbind

import android.content.Intent
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Log
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * DNS-only tunnel for the eCard bind-code flow.
 *
 * The interface carries a /32 route for its own address and another for the
 * resolver address it hands out, and the service reads the resulting queries off
 * the interface queue and answers them there. Only name resolution changes for
 * every app: their TCP keeps leaving through the underlying network, because the
 * only routes are the two /32s above. Nothing is filtered by package name on
 * purpose — the hijack has to cover whichever app makes the lookup, including
 * this one, whose own exchange request resolves the eCard host. The upstream
 * resolver socket is protected so those lookups do not loop back into the
 * tunnel.
 *
 * It is deliberately not a foreground service: the flow lasts a minute, and the
 * tunnel lives as long as the user stays on the eCard page or in the mini
 * program.
 */
class EcardBindVpnService : VpnService() {
    private var responder: DnsResponder? = null
    private var tunnel: ParcelFileDescriptor? = null
    private var hijackedHost: String? = null
    private var hijackedAnswer: String? = null
    private val dnsAddress: ByteArray = InetAddress.getByName(DNS_ADDRESS).address

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val host = intent?.getStringExtra(REQUEST_HOST_ARG)?.trim()?.lowercase().orEmpty()
        val answer = intent?.getStringExtra(REQUEST_IP_ARG)?.trim().orEmpty()
        Log.i(TAG, "start host=$host answer=$answer extras=${intent?.extras}")
        if (intent == null || host.isEmpty() || answer.isEmpty()) {
            Log.w(TAG, "start ignored: incomplete parameters")
            return failStart()
        }
        // A second start for the same parameters is a no-op; different ones
        // (only the Dart constants decide, but a retry may race a stop) rebuild
        // the interface from scratch.
        if (responder != null && host == hijackedHost && answer == hijackedAnswer) {
            return START_STICKY
        }
        stopServing()

        val answerAddress = try {
            InetAddress.getByName(answer) as? Inet4Address
        } catch (_: UnknownHostException) {
            null
        }
        if (answerAddress == null) {
            return failStart()
        }
        // Read the upstream resolver before establishing: afterwards this app's
        // own active network is the tunnel, whose only resolver would be us.
        val upstream = upstreamDnsServer()
        Log.i(TAG, "upstream=$upstream underlying=${underlyingSummary()}")

        val builder = Builder()
            .setSession(SESSION_NAME)
            .addAddress(TUN_ADDRESS, 32)
            // The resolver address is *not* assigned to the interface: an
            // address owned by the interface would be delivered locally (to port
            // 53, which an app may not bind — EACCES) and would never reach this
            // service. Routed instead, the query lands in the interface queue,
            // where it can be read and answered.
            .addDnsServer(DNS_ADDRESS)
            .addRoute(DNS_ADDRESS, 32)
            .setBlocking(false)
            // Only IPv4 is hijacked. Without this the tunnel would also capture,
            // and then black-hole, IPv6 for every app; letting the family through
            // keeps their IPv6 on the underlying network.
            .allowFamily(OsConstants.AF_INET6)
        // No addAllowedApplication: a VPN with no allow list applies to every
        // app, which is what this needs — the lookup that matters can come from
        // any of them, and a list would silently stop covering the ones it does
        // not name.

        val descriptor = try {
            builder.establish()
        } catch (error: Exception) {
            // No consent, or the platform refused the interface.
            Log.e(TAG, "establish failed", error)
            null
        }
        if (descriptor == null) {
            Log.e(TAG, "no tunnel: establish returned null")
            return failStart()
        }
        Log.i(TAG, "established tun fd=${descriptor.fd}")

        tunnel = descriptor
        hijackedHost = host
        hijackedAnswer = answer
        val dns = DnsResponder(descriptor, host, answerAddress, upstream)
        responder = dns
        active = true
        dns.start()
        return START_STICKY
    }

    override fun onRevoke() {
        stopServing()
        super.onRevoke()
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        stopServing()
        instance = null
        super.onDestroy()
    }

    /** The resolver of the network underneath, or a public one if unreadable. */
    private fun upstreamDnsServer(): InetAddress {
        val fallback = InetAddress.getByName(FALLBACK_UPSTREAM)
        try {
            val manager = getSystemService(ConnectivityManager::class.java) ?: return fallback
            val network = manager.activeNetwork ?: return fallback
            val servers = manager.getLinkProperties(network)?.dnsServers ?: return fallback
            return servers.firstOrNull {
                it is Inet4Address && !it.isLoopbackAddress && it.hostAddress != TUN_ADDRESS
            } ?: fallback
        } catch (_: Exception) {
            // No active network, or ACCESS_NETWORK_STATE refused: use the fallback.
            return fallback
        }
    }

    /** What the tunnel sits on top of, for the log. */
    private fun underlyingSummary(): String {
        return try {
            val manager = getSystemService(ConnectivityManager::class.java) ?: return "none"
            val network = manager.activeNetwork ?: return "none"
            val properties = manager.getLinkProperties(network)
            "if=${properties?.interfaceName} privateDns=${properties?.privateDnsServerName}"
        } catch (_: Exception) {
            "unreadable"
        }
    }

    /** Nothing is left running; the caller must return START_NOT_STICKY. */
    private fun failStart(): Int {
        stopServing()
        stopSelf()
        return START_NOT_STICKY
    }

    private fun stopServing() {
        Log.i(TAG, "stopping the tunnel")
        responder?.shutdown()
        responder = null
        try {
            tunnel?.close()
        } catch (_: IOException) {
            // Already gone; nothing left to release.
        }
        tunnel = null
        hijackedHost = null
        hijackedAnswer = null
        active = false
    }

    /**
     * The resolver of the tunnel: everything addressed to [DNS_ADDRESS] on port
     * 53 arrives on the interface queue, and the reply has to go back the same
     * way.
     *
     * A socket on port 53 would be simpler but is not available: 53 is
     * privileged, and binding to it fails with EACCES. One thread, one query at
     * a time — the apps ask a handful of names while the code is being read, and
     * a serialized relay cannot mix up answers.
     */
    private inner class DnsResponder(
        private val descriptor: ParcelFileDescriptor,
        private val host: String,
        private val answer: Inet4Address,
        private val upstream: InetAddress,
    ) : Thread("ecard-bind-dns") {
        @Volatile private var running = true
        private var relaySocket: DatagramSocket? = null
        private val forwardBuffer = ByteArray(MAX_PACKET)
        private var received = 0
        private var forwarded = 0

        override fun run() {
            val fd = descriptor.fileDescriptor
            val relay = DatagramSocket().apply { soTimeout = UPSTREAM_TIMEOUT_MS }
            // Without this the forwarded query would be routed back into this
            // interface and never reach a real resolver.
            val relayProtected = protect(relay)
            relaySocket = relay
            if (!relayProtected) Log.w(TAG, "relay socket could not be protected")
            Log.i(TAG, "answering DNS on $DNS_ADDRESS from the interface queue")

            val poll = arrayOf(
                StructPollfd().apply {
                    this.fd = fd
                    events = OsConstants.POLLIN.toShort()
                },
            )
            val packet = ByteArray(MAX_PACKET)
            while (running) {
                val ready = try {
                    Os.poll(poll, POLL_TIMEOUT_MS)
                } catch (error: Exception) {
                    failFatal("cannot poll the interface: $error")
                    return
                }
                // A poll timeout is how the loop says it is still alive.
                if (ready <= 0) {
                    Log.d(TAG, "alive received=$received forwarded=$forwarded")
                    continue
                }
                val length = try {
                    Os.read(fd, packet, 0, packet.size)
                } catch (error: ErrnoException) {
                    if (error.errno == OsConstants.EAGAIN ||
                        error.errno == OsConstants.EINTR
                    ) {
                        continue
                    }
                    failFatal("cannot read the interface: $error")
                    return
                } catch (error: Exception) {
                    failFatal("cannot read the interface: $error")
                    return
                }
                if (length <= 0) continue
                val reply = replyTo(packet, length) ?: continue
                try {
                    Os.write(fd, reply, 0, reply.size)
                } catch (error: Exception) {
                    Log.w(TAG, "cannot inject the reply: $error")
                }
            }
        }

        fun shutdown() {
            Log.i(TAG, "shutting the responder down (received=$received forwarded=$forwarded)")
            running = false
            relaySocket?.close()
            relaySocket = null
        }

        /** The whole IPv4/UDP packet to inject, or null when nothing is owed. */
        private fun replyTo(buffer: ByteArray, length: Int): ByteArray? {
            val datagram = EcardBindPackets.parseUdp(buffer, length) ?: return null
            if (datagram.destinationPort != DNS_PORT) return null
            if (!datagram.destinationAddress.contentEquals(dnsAddress)) return null

            val payload = buffer.copyOfRange(
                datagram.payloadOffset,
                datagram.payloadOffset + datagram.payloadLength,
            )
            val question = EcardBindDns.parseQuestion(payload, payload.size)
            if (question == null) {
                Log.w(TAG, "unreadable query from ${describe(datagram)}")
                return null
            }
            received += 1
            val id = EcardBindDns.queryId(payload)

            val dnsReply: ByteArray
            if (question.name.equals(host, ignoreCase = true)) {
                // The A record points at the mirror; every other type for this
                // host answers empty, so clients fall back to that A record.
                val address = if (question.type == EcardBindDns.TYPE_A) answer else null
                Log.i(
                    TAG,
                    "hijack ${question.name}/${question.type} from ${describe(datagram)}" +
                        " -> ${address ?: "empty"}",
                )
                dnsReply = EcardBindDns.buildReply(id, payload, question, address)
            } else {
                if (received <= LOG_FIRST_QUERIES || received % LOG_EVERY_QUERY == 0) {
                    Log.d(TAG, "forward ${question.name}/${question.type} ${describe(datagram)}")
                }
                dnsReply = forward(id, payload, question)
            }

            val replyPacket = EcardBindPackets.buildUdpReply(datagram, dnsReply)
            if (replyPacket.size <= MAX_REPLY_PACKET) return replyPacket

            // Bigger than one interface write: hand back an empty truncated
            // answer so the resolver retries this over TCP, which leaves through
            // the underlying network instead of this tunnel.
            Log.w(TAG, "reply for ${question.name} is ${replyPacket.size}B; asking for TCP")
            return EcardBindPackets.buildUdpReply(
                datagram,
                EcardBindDns.buildReply(id, payload, question, null, truncated = true),
            )
        }

        private fun forward(
            id: Int,
            payload: ByteArray,
            question: EcardBindDns.Question,
        ): ByteArray {
            forwarded += 1
            val relay = relaySocket
                ?: return EcardBindDns.buildReply(
                    id,
                    payload,
                    question,
                    null,
                    EcardBindDns.RCODE_SERVFAIL,
                )
            val deadline = System.currentTimeMillis() + UPSTREAM_TIMEOUT_MS
            try {
                relay.send(DatagramPacket(payload, payload.size, upstream, DNS_PORT))
                while (running) {
                    val remaining = deadline - System.currentTimeMillis()
                    if (remaining <= 0) break
                    relay.soTimeout = remaining.toInt()
                    val inbound = DatagramPacket(forwardBuffer, forwardBuffer.size)
                    relay.receive(inbound)
                    // A late answer to an earlier, timed-out query is not this
                    // query's answer.
                    if (inbound.length >= 2 && EcardBindDns.queryId(forwardBuffer) == id) {
                        return forwardBuffer.copyOf(inbound.length)
                    }
                }
            } catch (_: SocketTimeoutException) {
                // No answer in time: report SERVFAIL below.
                Log.w(TAG, "upstream $upstream timed out for ${question.name}")
            } catch (error: IOException) {
                // Same: the client is better off retrying than waiting.
                Log.w(TAG, "upstream $upstream failed for ${question.name}: $error")
            }
            return EcardBindDns.buildReply(
                id,
                payload,
                question,
                null,
                EcardBindDns.RCODE_SERVFAIL,
            )
        }
    }

    /**
     * A tunnel that cannot answer is worse than no tunnel: every app's DNS
     * would time out and then resolve through nobody. Take the interface down
     * with it — `stopSelf()` alone is not enough, because the system holds a
     * binding on a `VpnService`.
     */
    private fun failFatal(reason: String) {
        Log.e(TAG, reason)
        stopServing()
        stopSelf()
    }

    private fun describe(datagram: EcardBindPackets.Datagram): String {
        val source = InetAddress.getByAddress(datagram.sourceAddress).hostAddress
        val destination = InetAddress.getByAddress(datagram.destinationAddress).hostAddress
        return "$source:${datagram.sourcePort} -> $destination:${datagram.destinationPort}"
    }

    companion object {
        private const val TAG = "EcardBind"

        @Volatile var active = false
            private set

        /** The live service, so a stop can reach it without waiting for the system. */
        @Volatile private var instance: EcardBindVpnService? = null

        /**
         * Takes the tunnel down now.
         *
         * `stopSelf()`/`stopService()` are not enough on their own: the VPN
         * framework keeps this service bound for as long as the interface
         * exists, so the system never destroys it and `onDestroy` — where the
         * teardown otherwise lives — would never run. Closing the descriptor is
         * what actually removes the interface.
         */
        fun stopTunnel() {
            instance?.stopServing()
        }

        /** The interface's own address. */
        const val TUN_ADDRESS = "10.111.222.1"

        /**
         * The address the tunnel answers DNS for. It sits next to [TUN_ADDRESS]
         * but is deliberately never assigned to the interface: see the builder
         * in [onStartCommand].
         */
        const val DNS_ADDRESS = "10.111.222.2"
        const val REQUEST_HOST_ARG = "host"
        const val REQUEST_IP_ARG = "ip"

        private const val SESSION_NAME = "TechPie eCard 绑定"
        private const val FALLBACK_UPSTREAM = "223.5.5.5"
        private const val DNS_PORT = 53
        private const val MAX_PACKET = 4096
        private const val LOG_FIRST_QUERIES = 30
        private const val LOG_EVERY_QUERY = 50
        private const val UPSTREAM_TIMEOUT_MS = 4000
        private const val POLL_TIMEOUT_MS = 1000
        /** One IP packet has to fit the interface MTU, headers included. */
        private const val MAX_REPLY_PACKET = 1500
    }
}
