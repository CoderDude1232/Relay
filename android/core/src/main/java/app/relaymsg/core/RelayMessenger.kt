package app.relaymsg.core

import app.relaymsg.crypto.CryptoEngine
import app.relaymsg.crypto.MessageKind
import app.relaymsg.net.DeviceMessagePayload
import app.relaymsg.net.IncomingEnvelope
import app.relaymsg.net.PreKeyMaintainer
import app.relaymsg.net.RelayApiClient
import app.relaymsg.net.RelayApiException
import app.relaymsg.net.RelayCredentials
import app.relaymsg.net.RelayWebSocket
import app.relaymsg.net.SendOutcome
import app.relaymsg.storage.MessageStore
import app.relaymsg.storage.SecureStore
import java.util.UUID
import org.signal.libsignal.protocol.SignalProtocolAddress
import app.relaymsg.storage.QuotedMessage
import relay.content.ContentOuterClass.Content
import relay.content.content
import relay.content.deleteMessage
import relay.content.editMessage
import relay.content.quote
import relay.content.reactionMessage
import relay.content.textMessage

/** A peer device we can address: its id, opaque mailbox and registration id. */
data class PeerDevice(val id: Int, val mailboxId: String?, val registrationId: Int)

/** A decrypted incoming message, once the envelope pipeline is done with it. */
data class DecryptedEnvelope(
    val envelopeId: String,
    /** The E2E-attested sender, never the server-stamped field when both exist. */
    val senderAccount: String,
    /**
     * The sending device. Sender keys are keyed by (account, device), so a
     * distribution message from one device of a peer says nothing about another.
     */
    val senderDeviceId: Int,
    val content: Content,
)

/**
 * Orchestrates sending and receiving — the counterpart of iOS's
 * `MessagingService`, minus the UI concerns.
 *
 * The fan-out rules it implements are the subtle part; see PROTOCOL.md §4.
 */
class RelayMessenger(
    private val api: RelayApiClient,
    private val engine: CryptoEngine,
    private val store: SecureStore,
    private val credentials: RelayCredentials,
    private val sealedSenderTrustRoot: ByteArray? = null,
) {
    private val peerAccessKeys = mutableMapOf<String, ByteArray>()
    private var senderCertificate: Pair<ByteArray, Long>? = null

    /** Prekey ids come from a monotonic counter in the encrypted kv table. */
    private val allocator = object : PreKeyMaintainer.IdAllocator {
        override fun allocate(count: Int): IntRange {
            val key = "next-prekey-id"
            val current = store.messages.kvGet(key)?.toString(Charsets.UTF_8)?.toIntOrNull() ?: 1
            val next = current + count
            store.messages.kvPut(key, next.toString().toByteArray())
            return current until next
        }
    }

    // ------------------------------------------------------------- bootstrap

    /**
     * Brings a brand-new device fully online.
     *
     * Order matters: the auth key must be uploaded over Basic before anything can
     * be signed, and keys must be published before peers can start a session.
     */
    suspend fun bootstrap(authPublicKey: ByteArray, accessKey: ByteArray) {
        api.uploadDeviceAuthKeyWithBasicAuth(authPublicKey)
        PreKeyMaintainer().publishInitialKeys(api, engine, allocator)
        api.setAccessKey(accessKey)
    }

    /**
     * Brings a **linked** device online.
     *
     * Same as [bootstrap] minus the access key, and that omission is the point:
     * the account already has one, and rotating it would revoke every sender who
     * currently holds it — so linking a second phone would silently break sealed
     * sending from everyone who has ever messaged you.
     */
    suspend fun bootstrapLinkedDevice(authPublicKey: ByteArray) {
        api.uploadDeviceAuthKeyWithBasicAuth(authPublicKey)
        PreKeyMaintainer().publishInitialKeys(api, engine, allocator)
    }

    /** Re-publishes signed and Kyber prekeys, and tops up the one-time pool. */
    suspend fun refreshKeys() {
        val maintainer = PreKeyMaintainer()
        maintainer.republishSignedPreKeys(api, engine, allocator)
        maintainer.replenishIfNeeded(api, engine, allocator)
    }

    // -------------------------------------------------------------- sessions

    /**
     * Fetches fresh bundles for every device of [account] and establishes
     * sessions, recording the device list and the peer's access key.
     *
     * Our own device is skipped: libsignal refuses a session to self, and when
     * refreshing our own account for multi-device sync the relay returns this
     * device's bundle too — without the skip that aborts the whole refresh.
     */
    suspend fun refreshSessions(
        account: String,
        useOneTimePreKeys: Boolean = true,
    ): List<PeerDevice> {
        val (bundles, accessKey) = api.fetchPreKeyBundles(account)
        accessKey?.let { peerAccessKeys[account] = it }

        val devices = bundles.mapNotNull { rawBundle ->
            // Dropping the one-time prekey yields the same degraded-but-valid
            // session the relay forces when a peer's pool is exhausted. Useful as
            // a diagnostic: if a peer can decrypt without a one-time prekey but
            // not with one, their published pool is out of sync with their store.
            val bundle = if (useOneTimePreKeys) rawBundle else rawBundle.copy(oneTimePreKey = null)
            if (account == credentials.accountId && bundle.deviceId == credentials.deviceId) {
                return@mapNotNull null
            }
            engine.processPeerBundle(bundle, SignalProtocolAddress(account, bundle.deviceId))
            PeerDevice(bundle.deviceId, bundle.mailboxId, bundle.registrationId)
        }
        storeKnownDevices(account, devices)
        return devices
    }

    private fun storeKnownDevices(account: String, devices: List<PeerDevice>) {
        val encoded = devices.joinToString(";") { "${it.id},${it.mailboxId ?: ""},${it.registrationId}" }
        store.messages.kvPut("peer-devices:$account", encoded.toByteArray())
    }

    private fun knownDevices(account: String): List<PeerDevice> =
        store.messages.kvGet("peer-devices:$account")
            ?.toString(Charsets.UTF_8)
            ?.split(";")
            ?.filter { it.isNotBlank() }
            ?.mapNotNull { row ->
                val parts = row.split(",")
                if (parts.size != 3) return@mapNotNull null
                PeerDevice(
                    id = parts[0].toIntOrNull() ?: return@mapNotNull null,
                    mailboxId = parts[1].ifEmpty { null },
                    registrationId = parts[2].toIntOrNull() ?: 0,
                )
            }
            .orEmpty()

    /** Known devices, refreshing when absent or missing a mailbox id. */
    private suspend fun addressableDevices(account: String): List<PeerDevice> {
        val known = knownDevices(account)
        if (known.isNotEmpty() && known.none { it.mailboxId.isNullOrEmpty() }) return known
        return refreshSessions(account)
    }

    // ---------------------------------------------------------------- sending

    /**
     * Our profile, for one peer.
     *
     * Sent pairwise and end-to-end encrypted like anything else — the relay
     * never holds a display name or an avatar, so there is no directory to
     * scrape. [revision] is a millisecond clock and newest wins, which is what
     * lets two of our own devices disagree briefly without either losing.
     */
    fun buildProfile(
        displayName: String,
        avatar: relay.content.ContentOuterClass.AttachmentPointer?,
        revision: Long,
        status: String = "",
        bio: String = "",
    ): Content = content {
        profile = relay.content.profileUpdate {
            this.displayName = displayName
            timestamp = revision
            avatar?.let { this.avatar = it }
            // Always set, even when empty: the whole profile travels together,
            // and an empty string is how the sender clears one of these.
            this.status = status
            this.bio = bio
        }
        senderAccountId = credentials.accountId
        senderDeviceId = credentials.deviceId
    }

    /**
     * A reaction. Non-ephemeral, so it survives the recipient being offline.
     *
     * `target_author` is who *wrote* the message being reacted to, not who is
     * reacting — in a group it is the only way to identify the target, since
     * timestamps are only unique per author.
     */
    fun buildReaction(
        targetAuthor: String,
        targetTimestamp: Long,
        emoji: String,
        remove: Boolean,
        timestamp: Long,
        groupId: String? = null,
    ): Content = content {
        reaction = reactionMessage {
            this.emoji = emoji
            this.targetAuthor = targetAuthor
            this.targetTimestamp = targetTimestamp
            this.remove = remove
            this.timestamp = timestamp
        }
        senderAccountId = credentials.accountId
        senderDeviceId = credentials.deviceId
        groupId?.let { this.groupId = it }
    }

    /** An edit. Attachments are not editable, so only the body travels. */
    fun buildEdit(
        targetTimestamp: Long,
        newBody: String,
        groupId: String? = null,
    ): Content = content {
        edit = editMessage {
            this.targetTimestamp = targetTimestamp
            this.newBody = newBody
        }
        senderAccountId = credentials.accountId
        senderDeviceId = credentials.deviceId
        groupId?.let { this.groupId = it }
    }

    /**
     * An unsend. Leaves a tombstone rather than erasing the row, so the gap in
     * the conversation is visible instead of silently closing up.
     */
    fun buildDelete(
        targetTimestamp: Long,
        groupId: String? = null,
    ): Content = content {
        delete = deleteMessage {
            this.targetTimestamp = targetTimestamp
            // Only the author may delete, so the target author is always us.
            targetAuthor = credentials.accountId
        }
        senderAccountId = credentials.accountId
        senderDeviceId = credentials.deviceId
        groupId?.let { this.groupId = it }
    }

    /**
     * A change to the conversation's disappearing timer.
     *
     * Rides on an empty text message, because `expires_after_ms` is a field on
     * Content rather than a body of its own — the receiver applies the timer
     * before storing whatever arrived with it.
     */
    fun buildDisappearing(
        seconds: Long,
        timestamp: Long,
        groupId: String? = null,
    ): Content = content {
        text = textMessage {
            body = ""
            this.timestamp = timestamp
        }
        expiresAfterMs = seconds * 1000
        senderAccountId = credentials.accountId
        senderDeviceId = credentials.deviceId
        groupId?.let { this.groupId = it }
    }

    fun buildPoll(
        question: String,
        options: List<String>,
        multiSelect: Boolean,
        timestamp: Long,
        groupId: String? = null,
    ): Content = content {
        poll = relay.content.pollMessage {
            this.question = question
            this.options.addAll(options)
            this.multiSelect = multiSelect
            // Doubles as the poll's id: votes reference (author, timestamp).
            this.timestamp = timestamp
        }
        senderAccountId = credentials.accountId
        senderDeviceId = credentials.deviceId
        groupId?.let { this.groupId = it }
    }

    /** A vote. A later vote from the same account replaces the earlier one. */
    fun buildPollVote(
        pollAuthor: String,
        pollTimestamp: Long,
        selected: List<Int>,
        timestamp: Long,
        groupId: String? = null,
    ): Content = content {
        pollVote = relay.content.pollVote {
            this.pollAuthor = pollAuthor
            this.pollTimestamp = pollTimestamp
            selectedOptions.addAll(selected)
            this.timestamp = timestamp
        }
        senderAccountId = credentials.accountId
        senderDeviceId = credentials.deviceId
        groupId?.let { this.groupId = it }
    }

    /** Builds a `Content` carrying a text message, stamped as this device. */
    fun buildTextContent(
        body: String,
        timestamp: Long,
        groupId: String? = null,
        quote: QuotedMessage? = null,
    ): Content =
        content {
            text = textMessage {
                this.body = body
                this.timestamp = timestamp
                quote?.let {
                    this.quote = quote {
                        targetTimestamp = it.targetTimestamp
                        author = it.author
                        // Truncated by the sender: the recipient already has the
                        // original if they can see it, and a long quote would
                        // double the size of a one-word reply.
                        text = it.text.take(120)
                    }
                }
            }
            // Recipients prefer these over the envelope's server-stamped sender,
            // and for sealed messages they are the only self-declared identity —
            // checked against the certificate to catch spoofing.
            senderAccountId = credentials.accountId
            senderDeviceId = credentials.deviceId
            groupId?.let { this.groupId = it }
        }

    /**
     * Sends [plaintext] to every device of [account] over the authenticated
     * WebSocket, one frame per mailbox, applying the mismatch-retry rule.
     *
     * The rule matters: on a cross-account send the relay reports **every other
     * device** of the destination as missing, including ones an earlier frame in
     * this same send already reached. Retrying all of them duplicates messages,
     * so only genuinely unaddressed devices plus stale ones are retried, once.
     */
    suspend fun sendOverWebSocket(
        socket: RelayWebSocket,
        account: String,
        plaintext: ByteArray,
        clientTimestamp: Long,
        ephemeral: Boolean = false,
    ): SendOutcome {
        val payload = if (ephemeral) plaintext else ContentPadding.pad(plaintext)
        var devices = addressableDevices(account)
        val firstRound = devices.map { it.id }.toSet()

        var outcome = deliver(socket, account, devices, payload, clientTimestamp, ephemeral)
        if (outcome !is SendOutcome.MismatchedDevices) return outcome

        refreshSessions(account)
        devices = addressableDevices(account)
        val retryIds = (outcome.missing.toSet() - firstRound) + outcome.stale.toSet()
        if (retryIds.isEmpty()) {
            // Everything the relay called "missing" was already delivered to.
            return SendOutcome.Ok(0)
        }

        outcome = deliver(
            socket, account, devices.filter { it.id in retryIds }, payload, clientTimestamp, ephemeral,
        )
        if (outcome is SendOutcome.MismatchedDevices && outcome.extra.isEmpty()) {
            val addressed = firstRound + retryIds
            if ((outcome.missing + outcome.stale).all { it in addressed }) {
                return SendOutcome.Ok(0)
            }
        }
        return outcome
    }

    /** One frame per mailbox, accumulating mismatch info rather than stopping early. */
    private suspend fun deliver(
        socket: RelayWebSocket,
        account: String,
        devices: List<PeerDevice>,
        payload: ByteArray,
        clientTimestamp: Long,
        ephemeral: Boolean,
    ): SendOutcome {
        val missing = mutableListOf<Int>()
        val extra = mutableListOf<Int>()
        val stale = mutableListOf<Int>()

        for (device in devices) {
            val mailboxId = device.mailboxId
            if (mailboxId.isNullOrEmpty()) continue
            val address = SignalProtocolAddress(account, device.id)
            val encrypted = engine.encrypt(payload, address)
            val outcome = socket.send(
                mailboxId = mailboxId,
                payload = DeviceMessagePayload(device.id, device.registrationId, encrypted),
                clientTimestamp = clientTimestamp,
                ephemeral = ephemeral,
            )
            when (outcome) {
                is SendOutcome.Ok -> Unit
                is SendOutcome.MismatchedDevices -> {
                    // Keep going: devices after a stale one still need addressing.
                    missing += outcome.missing
                    extra += outcome.extra
                    stale += outcome.stale
                }
                else -> return outcome
            }
        }
        return if (missing.isEmpty() && extra.isEmpty() && stale.isEmpty()) {
            SendOutcome.Ok(0)
        } else {
            SendOutcome.MismatchedDevices(missing, extra, stale)
        }
    }

    /**
     * Sends sealed, over the unauthenticated delivery endpoint, so the relay
     * never learns the sender. Requires the peer to have published an access key.
     *
     * A `403` means a stale mailbox or rotated access key, so the failed devices
     * are refreshed and retried once — retrying all of them would duplicate the
     * copies that already landed.
     */
    suspend fun sendSealed(
        account: String,
        plaintext: ByteArray,
        clientTimestamp: Long,
        ephemeral: Boolean = false,
    ) {
        val payload = if (ephemeral) plaintext else ContentPadding.pad(plaintext)
        val certificate = senderCertificate()
        if (peerAccessKeys[account] == null) refreshSessions(account)
        val accessKey = peerAccessKeys[account]
            ?: throw IllegalStateException("recipient has not published a sealed-sender access key")

        val failed = sealedPass(account, addressableDevices(account), payload, certificate, accessKey, clientTimestamp, ephemeral)
        if (failed.isEmpty()) return

        refreshSessions(account)
        val refreshedKey = peerAccessKeys[account] ?: accessKey
        val retry = addressableDevices(account).filter { device -> failed.any { it.id == device.id } }
        val stillFailed = sealedPass(account, retry, payload, certificate, refreshedKey, clientTimestamp, ephemeral)
        if (stillFailed.isNotEmpty()) throw IllegalStateException("sealed delivery rejected")
    }

    private suspend fun sealedPass(
        account: String,
        devices: List<PeerDevice>,
        payload: ByteArray,
        certificate: ByteArray,
        accessKey: ByteArray,
        clientTimestamp: Long,
        ephemeral: Boolean,
    ): List<PeerDevice> {
        val failed = mutableListOf<PeerDevice>()
        for (device in devices) {
            val mailboxId = device.mailboxId
            if (mailboxId.isNullOrEmpty()) continue
            val address = SignalProtocolAddress(account, device.id)
            if (!engine.hasSession(address)) refreshSessions(account)
            val sealed = engine.sealedEncrypt(payload, address, certificate)
            try {
                api.sendSealed(
                    mailboxId = mailboxId,
                    type = MessageKind.MESSAGE,
                    content = sealed,
                    accessKey = accessKey,
                    ephemeral = ephemeral,
                    clientTimestamp = clientTimestamp,
                )
            } catch (e: RelayApiException) {
                if (e.status == 403) failed += device else throw e
            }
        }
        return failed
    }

    /** The cached delivery certificate, refreshed within a day of expiry. */
    private suspend fun senderCertificate(): ByteArray {
        val cached = senderCertificate
        val now = System.currentTimeMillis()
        if (cached != null && cached.second - now > 24 * 3600_000L) return cached.first
        val fetched = api.deliveryCertificate()
        senderCertificate = fetched
        return fetched.first
    }

    /**
     * Mirrors an outgoing message to this account's **other** devices.
     *
     * `sync_recipient` carries the peer the message was actually for, so a linked
     * device files it in the right conversation and stores it as outgoing rather
     * than as a message from ourselves (PROTOCOL.md §6.1, field 16).
     *
     * Deliberately bypasses [sendOverWebSocket]: our own devices are implicitly
     * trusted, so the identity-acknowledgement check that guards sends to a peer
     * does not apply, and the relay reports no missing devices for a self-send.
     *
     * Best-effort — a linked device that cannot be reached must not fail the
     * send that already succeeded to the real recipient.
     */
    suspend fun sendSyncToOwnDevices(
        socket: RelayWebSocket,
        content: Content,
        peer: String,
        clientTimestamp: Long,
    ) {
        val sync = content.toBuilder().setSyncRecipient(peer).build()
        val payload = ContentPadding.pad(sync.toByteArray())

        val devices = try {
            // Always refresh: a device linked since the last send would otherwise
            // never receive anything, and there is no notification for that.
            refreshSessions(credentials.accountId)
                .filter { it.id != credentials.deviceId }
        } catch (_: Throwable) {
            return
        }
        if (devices.isEmpty()) return

        for (device in devices) {
            val mailboxId = device.mailboxId
            if (mailboxId.isNullOrEmpty()) continue
            runCatching {
                val address = SignalProtocolAddress(credentials.accountId, device.id)
                socket.send(
                    mailboxId = mailboxId,
                    payload = DeviceMessagePayload(
                        device.id, device.registrationId, engine.encrypt(payload, address),
                    ),
                    clientTimestamp = clientTimestamp,
                )
            }
        }
    }

    // ----------------------------------------------------------------- groups

    /**
     * Builds a `GroupUpdate` content for [group], stamped as this device.
     *
     * Every field the recipients need travels here — the relay stores no group
     * state at all, so an update that omits the roster leaves recipients with a
     * stale one.
     */
    fun buildGroupUpdate(
        groupId: String,
        action: relay.content.ContentOuterClass.GroupUpdate.Action,
        revision: Long,
        name: String = "",
        members: List<String> = emptyList(),
        admins: List<String> = emptyList(),
        target: String = "",
        distributionId: String = "",
        announceOnly: Boolean = false,
    ): Content = content {
        groupUpdate = relay.content.groupUpdate {
            this.action = action
            this.revision = revision
            this.actor = credentials.accountId
            this.announceOnly = announceOnly
            if (name.isNotEmpty()) this.name = name
            if (target.isNotEmpty()) this.target = target
            if (distributionId.isNotEmpty()) this.distributionId = distributionId
            if (members.isNotEmpty()) this.members.addAll(members)
            if (admins.isNotEmpty()) this.admins.addAll(admins)
        }
        this.groupId = groupId
        senderAccountId = credentials.accountId
        senderDeviceId = credentials.deviceId
    }

    /** A group message, encrypted once under our sender key for this epoch. */
    fun buildGroupTextContent(groupId: String, body: String, timestamp: Long): Content =
        buildTextContent(body, timestamp, groupId)

    /**
     * Hands our sender key to any member who does not yet have it for this
     * epoch, over their **pairwise** session.
     *
     * Tracked per (group, epoch, member) so each member is served once —
     * redistributing on every send would be wasteful and, worse, would reset
     * their ratchet state for the epoch.
     */
    suspend fun distributeSenderKeyIfNeeded(
        socket: RelayWebSocket,
        groupId: String,
        distributionId: String,
        members: List<String>,
    ) {
        val epochKey = "skdm:$groupId:$distributionId"
        val alreadySent = store.messages.kvGet(epochKey)
            ?.decodeToString()?.split(",")?.filter { it.isNotBlank() }?.toMutableSet()
            ?: mutableSetOf()
        val targets = members.filter { it != credentials.accountId && it !in alreadySent }
        if (targets.isEmpty()) return

        val skdm = engine.senderKeyDistributionMessage(UUID.fromString(distributionId))
        val payload = content {
            senderKeyDistribution = relay.content.senderKeyDistribution {
                data = com.google.protobuf.ByteString.copyFrom(skdm)
                this.distributionId = distributionId
            }
            this.groupId = groupId
            senderAccountId = credentials.accountId
            senderDeviceId = credentials.deviceId
        }.toByteArray()

        for (member in targets) {
            val delivered = runCatching {
                sendOverWebSocket(socket, member, payload, System.currentTimeMillis())
            }.getOrNull()
            if (delivered is SendOutcome.Ok) alreadySent += member
        }
        store.messages.kvPut(epochKey, alreadySent.joinToString(",").toByteArray())
    }

    /**
     * Sends a group message by encrypting **once** with our sender key and
     * fanning the identical ciphertext out to every member's devices.
     *
     * Note iOS does NOT use this path while sealed sender is on — it sends
     * individual pairwise sealed copies instead, since a sealed message cannot
     * be a broadcast without multi-recipient sealing. Both must be handled on
     * receive; this is the sender-key half (PROTOCOL.md §1.4).
     */
    suspend fun sendGroupMessage(
        socket: RelayWebSocket,
        groupId: String,
        distributionId: String,
        members: List<String>,
        plaintext: ByteArray,
        clientTimestamp: Long,
    ): SendOutcome {
        distributeSenderKeyIfNeeded(socket, groupId, distributionId, members)

        val padded = ContentPadding.pad(plaintext)
        val ciphertext = engine.groupEncrypt(padded, UUID.fromString(distributionId))

        var worst: SendOutcome = SendOutcome.Ok(0)
        for (member in members.filter { it != credentials.accountId }) {
            val devices = addressableDevices(member)
            for (device in devices) {
                val mailboxId = device.mailboxId
                if (mailboxId.isNullOrEmpty()) continue
                val outcome = socket.send(
                    mailboxId = mailboxId,
                    payload = DeviceMessagePayload(device.id, device.registrationId, ciphertext),
                    clientTimestamp = clientTimestamp,
                )
                if (outcome !is SendOutcome.Ok && worst is SendOutcome.Ok) worst = outcome
            }
        }
        return worst
    }

    /** Sends a pairwise (non-sender-key) payload to each member. Used for updates. */
    suspend fun sendToGroupMembers(
        socket: RelayWebSocket,
        members: List<String>,
        plaintext: ByteArray,
        clientTimestamp: Long,
    ) {
        for (member in members.filter { it != credentials.accountId }) {
            runCatching { sendOverWebSocket(socket, member, plaintext, clientTimestamp) }
        }
    }

    // -------------------------------------------------------------- receiving

    /**
     * Decrypts one envelope and returns its content, or null when it is a
     * duplicate.
     *
     * Order is deliberate: claim the id first (Double Ratchet decryption is
     * destructive, so exactly one claimant may proceed), then recover the sender
     * — cryptographically for sealed envelopes — then reject a plaintext that
     * names a different sender than the certificate does.
     */
    fun processEnvelope(envelope: IncomingEnvelope): DecryptedEnvelope? {
        if (!store.messages.claimEnvelope(envelope.id)) return null

        val senderAddress: SignalProtocolAddress
        val plaintext: ByteArray
        if (envelope.senderAccount.isEmpty()) {
            val trustRoot = requireNotNull(sealedSenderTrustRoot) {
                "a sealed envelope arrived but no trust root is configured"
            }
            // Validate at the time the relay accepted the message: a certificate
            // that was valid then must still open after a delayed delivery.
            val validationTime =
                if (envelope.serverTimestamp > 0) envelope.serverTimestamp else System.currentTimeMillis()
            val result = engine.sealedDecrypt(envelope.message.data, trustRoot, validationTime)
            senderAddress = SignalProtocolAddress(result.senderAccountId, result.senderDeviceId)
            plaintext = result.plaintext
        } else {
            senderAddress = SignalProtocolAddress(envelope.senderAccount, envelope.senderDevice)
            plaintext = engine.decrypt(envelope.message, senderAddress)
        }

        val content = Content.parseFrom(plaintext)
        if (envelope.senderAccount.isEmpty() &&
            content.senderAccountId.isNotEmpty() &&
            content.senderAccountId != senderAddress.name
        ) {
            throw IllegalStateException("sealed sender spoofed: plaintext claims a different account")
        }
        val attested =
            if (content.senderAccountId.isNotEmpty()) content.senderAccountId else senderAddress.name

        return DecryptedEnvelope(envelope.id, attested, senderAddress.deviceId, content)
    }

    /** Records a peer device's sender key so their group messages can be decrypted. */
    fun processSenderKeyDistribution(data: ByteArray, account: String, deviceId: Int) {
        engine.processSenderKeyDistribution(data, SignalProtocolAddress(account, deviceId))
    }

    /** Convenience for callers that only need the store. */
    val messages: MessageStore get() = store.messages
}
