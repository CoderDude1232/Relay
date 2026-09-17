package app.relaymsg.net

import app.relaymsg.crypto.CryptoEngine

/**
 * Keeps the device's one-time prekey pool topped up.
 *
 * When the relay reports fewer than [threshold] remaining, a fresh batch of
 * [batchSize] is generated — along with a rotated signed prekey and Kyber prekey
 * — and uploaded. Thresholds match iOS so both clients behave alike.
 */
class PreKeyMaintainer(
    private val threshold: Int = 20,
    private val batchSize: Int = 100,
) {
    /** Hands out prekey ids that are never reused for the device's lifetime. */
    interface IdAllocator {
        fun allocate(count: Int): IntRange
    }

    /** The device's very first key publication. */
    suspend fun publishInitialKeys(
        api: RelayApiClient,
        engine: CryptoEngine,
        allocator: IdAllocator,
    ) = upload(api, engine, allocator, oneTimeCount = batchSize)

    /**
     * Re-publishes identity, signed prekey and Kyber prekey with **no** one-time
     * keys, replacing whatever the server holds.
     *
     * Run on launch. Without it, a reinstall leaves the relay serving a signed
     * prekey whose private half is gone, and every new inbound session fails
     * (PROTOCOL.md §1.3).
     */
    suspend fun republishSignedPreKeys(
        api: RelayApiClient,
        engine: CryptoEngine,
        allocator: IdAllocator,
    ) = upload(api, engine, allocator, oneTimeCount = 0)

    /** Tops the pool up if the relay says it is running low. Returns true if it uploaded. */
    suspend fun replenishIfNeeded(
        api: RelayApiClient,
        engine: CryptoEngine,
        allocator: IdAllocator,
    ): Boolean {
        if (api.oneTimePreKeyCount() >= threshold) return false
        upload(api, engine, allocator, oneTimeCount = batchSize)
        return true
    }

    private suspend fun upload(
        api: RelayApiClient,
        engine: CryptoEngine,
        allocator: IdAllocator,
        oneTimeCount: Int,
    ) {
        // Two ids for the signed and Kyber prekeys, then the one-time batch.
        val ids = allocator.allocate(2 + oneTimeCount)
        val signedPreKeyId = ids.first
        val kyberPreKeyId = ids.first + 1
        val oneTimeIds =
            if (oneTimeCount == 0) IntRange.EMPTY else (ids.first + 2)..ids.last

        api.uploadKeys(
            engine.generatePreKeyPublication(
                signedPreKeyId = signedPreKeyId,
                kyberPreKeyId = kyberPreKeyId,
                oneTimePreKeyIds = oneTimeIds,
            ),
        )
    }
}
