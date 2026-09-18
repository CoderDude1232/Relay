package app.relaymsg.net

import app.relaymsg.crypto.MessageKind
import app.relaymsg.crypto.PeerPreKeyBundle
import app.relaymsg.crypto.PreKeyPublication
import app.relaymsg.crypto.PublicPreKey
import app.relaymsg.crypto.SignedPublicPreKey
import java.io.IOException
import java.util.Base64
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject

/** An error returned by the relay. The body is always `{"error": "..."}`. */
class RelayApiException(val status: Int, val serverMessage: String) :
    IOException(if (serverMessage.isEmpty()) "server error (HTTP $status)" else serverMessage)

/** The relay sent something we could not parse. */
class MalformedResponseException(message: String = "malformed response") : IOException(message)

/** An account's live connection state. `lastSeen` is ms since epoch, 0 if never. */
data class Presence(val online: Boolean, val lastSeen: Long)

/**
 * Short-lived TURN credentials from `GET /v1/turn-credentials`.
 *
 * coturn REST HMAC-SHA1, so [username] already encodes the expiry and the pair
 * is only good for [ttl] seconds.
 */
data class TurnCredentials(
    val urls: List<String>,
    val username: String,
    val credential: String,
    val ttl: Long,
)

/** What `POST /v1/accounts/oauth` came back with. */
sealed interface OAuthAccountResult {
    data class SignedIn(
        val credentials: RelayCredentials,
        val username: String,
        /** True for a brand-new account, false when an existing one was recovered. */
        val created: Boolean,
    ) : OAuthAccountResult

    /** The token is valid but there is no account yet; ask for a username. */
    data object UsernameRequired : OAuthAccountResult
}

/** A linking rendezvous. `expiresAt` is ms since epoch; the relay allows 10 minutes. */
data class ProvisioningSession(val sessionId: String, val expiresAt: Long)

/** One resolved blinded-directory hit. */
data class DirectoryMatch(val token: ByteArray, val accountId: String, val username: String) {
    override fun equals(other: Any?): Boolean = this === other || (
        other is DirectoryMatch && token.contentEquals(other.token) &&
            accountId == other.accountId && username == other.username
        )

    override fun hashCode(): Int = 31 * token.contentHashCode() + accountId.hashCode()
}

/** A device of our own account, as `GET /v1/devices` reports it. */
data class LinkedDevice(val deviceId: Int, val mailboxId: String?)

/**
 * The relay's JSON REST control plane: accounts, devices, prekeys, discovery,
 * attachments and the sealed-sender delivery path.
 *
 * **Binary fields are standard padded base64** everywhere, matching the server's
 * `b64` type. Every authenticated call is signed with `Relay-Sig` unless it is
 * explicitly routed through Basic for the auth-key bootstrap.
 */
class RelayApiClient(
    baseUrl: String,
    private val auth: RelayAuthenticator?,
    private val client: OkHttpClient = defaultClient(),
) {
    companion object {
        private val JSON = "application/json".toMediaType()
        private val OCTET_STREAM = "application/octet-stream".toMediaType()

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    private val base: HttpUrl = baseUrl.trimEnd('/').toHttpUrl()

    // ---------------------------------------------------------------- accounts

    /**
     * Creates an account and its primary device. Unauthenticated.
     *
     * Supplying [email] enables contact discovery and recovery; the relay stores
     * it only as an OPRF-keyed token, never in the clear.
     */
    suspend fun register(
        username: String,
        password: String,
        email: String? = null,
        accountPassword: String? = null,
    ): Triple<RelayCredentials, String, String> {
        val body = JSONObject()
            .put("username", username)
            .put("password", password)
            .apply {
                if (!email.isNullOrEmpty()) put("email", email)
                if (!accountPassword.isNullOrEmpty()) put("accountPassword", accountPassword)
            }
        val json = postJson("v1/accounts", body, authenticated = false)
        val credentials = RelayCredentials(
            accountId = json.getString("accountId"),
            deviceId = json.getInt("deviceId"),
            password = password,
        )
        return Triple(credentials, json.optString("mailboxId"), username)
    }

    suspend fun lookupAccountId(username: String): String =
        get("v1/accounts/by-username/$username", authenticated = false).getString("accountId")

    suspend fun lookupUsername(accountId: String): String =
        get("v1/accounts/$accountId").getString("username")

    suspend fun presence(accountId: String): Presence =
        get("v1/presence/$accountId").let {
            Presence(it.getBoolean("online"), it.optLong("lastSeen"))
        }

    /** Uploads this account's 32-byte sealed-sender access key. */
    suspend fun setAccessKey(key: ByteArray) {
        require(key.size == 32) { "access key must be 32 bytes" }
        putNoContent("v1/accounts/me/access-key", JSONObject().put("accessKey", key.b64()))
    }

    // ----------------------------------------------------------------- devices

    /**
     * Uploads the device's P-256 auth public key, **over HTTP Basic**.
     *
     * This is the one call that cannot be signed: `Relay-Sig` verifies against
     * this very key, which the server does not have yet (PROTOCOL.md §2.3).
     */
    suspend fun uploadDeviceAuthKeyWithBasicAuth(publicKey: ByteArray) {
        require(publicKey.size == 65 && publicKey[0] == 0x04.toByte()) {
            "auth key must be an uncompressed P-256 point (0x04 || X || Y)"
        }
        val auth = requireNotNull(auth) { "credentials required" }
        execute(
            requestBuilder("v1/devices/auth-key")
                .put(JSONObject().put("publicKey", publicKey.b64()).toString().toRequestBody(JSON))
                .apply { auth.basicHeaders().forEach { (k, v) -> header(k, v) } }
                .build(),
        ).close()
    }

    /**
     * Registers an additional device on this account.
     *
     * Device-list changes are signed with the device auth key, not merely
     * authenticated: [signature] covers the canonical
     * `relay-device-list-v1` payload including [expectedVersion], so a stale
     * view of the device list is rejected with 409 rather than racing. That
     * matters because a silently-added device would receive every future
     * message.
     */
    suspend fun addDevice(
        password: String,
        expectedVersion: Long,
        signerDeviceId: Int,
        signature: ByteArray,
    ): Triple<Int, String?, Long> {
        val body = JSONObject()
            .put("password", password)
            .put(
                "auth",
                JSONObject()
                    .put("expectedVersion", expectedVersion)
                    .put("signerDeviceId", signerDeviceId)
                    .put("signature", signature.b64()),
            )
        val json = postJson("v1/devices", body)
        return Triple(
            json.getInt("deviceId"),
            json.optString("mailboxId").ifEmpty { null },
            json.optLong("deviceListVersion"),
        )
    }

    suspend fun listDevices(): Pair<List<LinkedDevice>, Long> {
        val json = get("v1/devices")
        val devices = json.getJSONArray("devices").map { obj ->
            LinkedDevice(obj.getInt("deviceId"), obj.optString("mailboxId").ifEmpty { null })
        }
        return devices to json.optLong("deviceListVersion")
    }

    /** Assigns this device a fresh opaque mailbox id. Clients rotate daily. */
    suspend fun rotateMailbox(): String =
        postJson("v1/devices/me/mailbox/rotate", null).getString("mailboxId")

    /** Registers this device's FCM token so the relay can wake it. */
    suspend fun setFcmToken(token: String) =
        putNoContent("v1/devices/fcm", JSONObject().put("token", token))

    /**
     * Whether the relay may embed the encrypted envelope in the push payload.
     * `false` (the default) is a content-free wake; the client then fetches the
     * queue itself.
     */
    suspend fun setPushIncludeContent(include: Boolean) =
        putNoContent("v1/devices/me/push-content", JSONObject().put("includeContent", include))

    // -------------------------------------------------------------------- keys

    suspend fun uploadKeys(publication: PreKeyPublication) {
        val body = JSONObject()
            .put("registrationId", publication.registrationId)
            .put("identityKey", publication.identityKey.b64())
            .put("signedPreKey", publication.signedPreKey.toJson())
            .put("kyberPreKey", publication.kyberPreKey.toJson())
            .put(
                "oneTimePreKeys",
                JSONArray().apply {
                    publication.oneTimePreKeys.forEach {
                        put(JSONObject().put("keyId", it.id).put("publicKey", it.publicKey.b64()))
                    }
                },
            )
        putNoContent("v1/keys", body)
    }

    suspend fun oneTimePreKeyCount(): Int = get("v1/keys/count").getInt("count")

    /**
     * Fetches prekey bundles for every device of [accountId], consuming one
     * one-time prekey per device, plus the account's sealed-sender access key
     * when it has published one.
     *
     * `oneTimePreKey` is null once a peer's pool is exhausted — the session then
     * establishes from the signed prekey alone, which is degraded but valid, so
     * both shapes must be handled.
     */
    suspend fun fetchPreKeyBundles(accountId: String): Pair<List<PeerPreKeyBundle>, ByteArray?> {
        val json = get("v1/keys/$accountId")
        val bundles = json.getJSONArray("devices").map { device ->
            PeerPreKeyBundle(
                deviceId = device.getInt("deviceId"),
                mailboxId = device.optString("mailboxId").ifEmpty { null },
                registrationId = device.getInt("registrationId"),
                identityKey = device.getString("identityKey").unb64(),
                signedPreKey = device.getJSONObject("signedPreKey").toSignedPreKey(),
                kyberPreKey = device.getJSONObject("kyberPreKey").toSignedPreKey(),
                oneTimePreKey = device.optJSONObject("oneTimePreKey")?.let {
                    PublicPreKey(it.getInt("keyId"), it.getString("publicKey").unb64())
                },
            )
        }
        val accessKey = json.optString("accessKey").takeIf { it.isNotEmpty() }?.unb64()
        return bundles to accessKey
    }

    // --------------------------------------------------------------- discovery

    /** Blinded discovery step 1: the relay evaluates `k·B` without learning `B`'s preimage. */
    suspend fun directoryEvaluate(blinded: List<ByteArray>): List<ByteArray> {
        require(blinded.size in 1..1024) { "blinded must contain 1..1024 elements" }
        val body = JSONObject().put("blinded", JSONArray(blinded.map { it.b64() }))
        return postJson("v1/directory/oprf", body).getJSONArray("evaluated").mapStrings { it.unb64() }
    }

    /** Blinded discovery step 2. Unmatched tokens are simply absent — non-users stay private. */
    suspend fun directoryResolve(tokens: List<ByteArray>): List<DirectoryMatch> {
        require(tokens.size in 1..1024) { "tokens must contain 1..1024 elements" }
        val body = JSONObject().put("tokens", JSONArray(tokens.map { it.b64() }))
        return postJson("v1/directory/resolve", body).getJSONArray("results").map {
            DirectoryMatch(
                token = it.getString("token").unb64(),
                accountId = it.getString("accountId"),
                username = it.getString("username"),
            )
        }
    }

    // ---------------------------------------------------------------- messages

    /** Mints this device's sealed-sender certificate (7-day expiry). */
    suspend fun deliveryCertificate(): Pair<ByteArray, Long> =
        get("v1/certificate/delivery").let {
            it.getString("certificate").unb64() to it.getLong("expiresAt")
        }

    /**
     * Sealed-sender delivery over the **unauthenticated** endpoint, so the relay
     * never learns who sent the message. Authorisation is the recipient's access
     * key instead.
     *
     * Any failure is a flat `403` — an unknown mailbox and a wrong access key are
     * deliberately indistinguishable, so callers must not infer existence from it.
     */
    suspend fun sendSealed(
        mailboxId: String,
        type: MessageKind,
        content: ByteArray,
        accessKey: ByteArray,
        ephemeral: Boolean,
        clientTimestamp: Long,
    ): Long {
        val body = JSONObject()
            .put("mailboxId", mailboxId)
            .put("type", type.toWire().number)
            .put("content", content.b64())
            .put("accessKey", accessKey.b64())
            .put("ephemeral", ephemeral)
            .put("clientTimestamp", clientTimestamp)
        return postJson("v1/messages/sealed", body, authenticated = false).getLong("serverTimestamp")
    }

    /**
     * This device's queued envelopes. Does **not** dequeue — each must be acked.
     * Used as the fallback for receiving when the WebSocket cannot connect.
     */
    suspend fun fetchQueue(): List<IncomingEnvelope> =
        get("v1/queue").getJSONArray("envelopes")
            .mapStrings { it.unb64() }
            .mapNotNull(IncomingEnvelope::parse)

    /** Removes a delivered envelope from this device's queue. */
    suspend fun ackMessage(envelopeId: String) =
        postNoContent("v1/messages/ack", JSONObject().put("envelopeId", envelopeId))

    // ------------------------------------------------------------- attachments

    /** Allocates a blob id and uploads the encrypted bytes to it. */
    suspend fun uploadAttachment(ciphertext: ByteArray): String {
        val id = postJson("v1/attachments", null).getString("id")
        execute(
            requestBuilder("v1/attachments/$id", method = "PUT")
                .put(ciphertext.toRequestBody(OCTET_STREAM))
                .signed("PUT", "/v1/attachments/$id")
                .build(),
        ).close()
        return id
    }

    suspend fun downloadAttachment(id: String): ByteArray = withContext(Dispatchers.IO) {
        execute(
            requestBuilder("v1/attachments/$id", method = "GET")
                .get()
                .signed("GET", "/v1/attachments/$id")
                .build(),
        ).use { it.body.bytes() }
    }

    // ---------------------------------------------------------------- calls

    /**
     * Fetches TURN credentials, or null when the relay has no TURN configured.
     *
     * A `404` is documented as "no TURN", not a failure — the call still connects
     * over host/STUN candidates, it just cannot use Private Call Mode. Anything
     * else is a real error and propagates.
     */
    suspend fun turnCredentials(): TurnCredentials? {
        val json = try {
            get("v1/turn-credentials")
        } catch (e: RelayApiException) {
            if (e.status == 404) return null else throw e
        }
        return TurnCredentials(
            urls = json.optJSONArray("urls")?.mapStrings { it } ?: emptyList(),
            username = json.optString("username"),
            credential = json.optString("credential"),
            ttl = json.optLong("ttl"),
        )
    }

    // ---------------------------------------------------------- oauth accounts

    /**
     * Registers or recovers an account from a verified Supabase token.
     *
     * The relay checks the token server-to-server and resolves the account by
     * Supabase user id, then by email. That is what lets a returning user sign in
     * on a brand-new device with no local credentials at all — and why
     * [username] is only needed the first time.
     *
     * A `404` is not an error: it means the token is good but no account exists
     * yet, so the caller should prompt for a username and retry.
     */
    suspend fun registerWithOAuth(
        accessToken: String,
        devicePassword: String,
        username: String? = null,
        accountPassword: String? = null,
    ): OAuthAccountResult {
        val body = JSONObject()
            .put("accessToken", accessToken)
            .put("password", devicePassword)
        username?.takeIf { it.isNotBlank() }?.let { body.put("username", it) }
        accountPassword?.takeIf { it.isNotEmpty() }?.let { body.put("accountPassword", it) }

        val json = try {
            postJson("v1/accounts/oauth", body, authenticated = false)
        } catch (e: RelayApiException) {
            if (e.status == 404) return OAuthAccountResult.UsernameRequired else throw e
        }
        return OAuthAccountResult.SignedIn(
            credentials = RelayCredentials(
                accountId = json.getString("accountId"),
                deviceId = json.getInt("deviceId"),
                password = devicePassword,
            ),
            username = json.optString("username"),
            created = json.optBoolean("created"),
        )
    }

    /** Creates a device on this account for a scanned QR. Primary side of linking. */
    suspend fun linkDevice(
        password: String,
        expectedVersion: Long,
        signerDeviceId: Int,
        signature: ByteArray,
    ): Int = postJson(
        "v1/devices/link",
        JSONObject()
            .put("password", password)
            .put(
                "auth",
                JSONObject()
                    .put("expectedVersion", expectedVersion)
                    .put("signerDeviceId", signerDeviceId)
                    .put("signature", signature.b64()),
            ),
    ).getInt("deviceId")

    // -------------------------------------------------------- device linking

    /**
     * Mints a rendezvous session for linking this device to an existing account.
     *
     * Unauthenticated by necessity: the device calling this has no credentials
     * yet — acquiring them is the point. The session id alone is not enough to
     * take over an account, because the payload deposited against it is sealed
     * to an ephemeral key that only ever appears in the QR.
     */
    suspend fun createProvisioningSession(): ProvisioningSession =
        postJson("v1/provisioning-sessions", null, authenticated = false).let {
            ProvisioningSession(it.getString("sessionId"), it.getLong("expiresAt"))
        }

    /**
     * Polls for the sealed provisioning payload.
     *
     * Null means the primary has not deposited it yet (`204`). The session is
     * single-use and deleted on the first successful fetch, so a caller gets
     * exactly one chance to keep the result.
     */
    suspend fun fetchProvisioningBlob(sessionId: String): ByteArray? {
        val response = execute(
            requestBuilder("v1/provisioning-sessions/$sessionId").get().build(),
        )
        return response.use {
            if (it.code == 204) return null
            JSONObject(it.body.string()).getString("blob").unb64()
        }
    }

    /**
     * Deposits the sealed payload for a device being linked. Primary side.
     *
     * The relay stores an opaque blob; it cannot read the identity key inside.
     */
    suspend fun storeProvisioningBlob(sessionId: String, blob: ByteArray) {
        execute(
            requestBuilder("v1/provisioning-sessions/$sessionId", "PUT")
                .put(JSONObject().put("blob", blob.b64()).toString().toRequestBody(JSON))
                .signed("PUT", "/v1/provisioning-sessions/$sessionId")
                .build(),
        ).close()
    }

    // ------------------------------------------------------------- invites

    suspend fun createContactInvite(): Pair<String, Long> =
        postJson("v1/contact-invites", null).let {
            it.getString("token") to it.getLong("expiresAt")
        }

    suspend fun claimContactInvite(token: String): Pair<String, String> =
        postJson("v1/contact-invites/claim", JSONObject().put("token", token)).let {
            it.getString("accountId") to it.getString("username")
        }

    suspend fun createGroupInvite(blob: ByteArray): Pair<String, Long> =
        postJson("v1/group-invites", JSONObject().put("blob", blob.b64())).let {
            it.getString("token") to it.getLong("expiresAt")
        }

    suspend fun claimGroupInvite(token: String): ByteArray =
        postJson("v1/group-invites/claim", JSONObject().put("token", token))
            .getString("blob").unb64()

    // ----------------------------------------------------------------- plumbing

    private fun requestBuilder(path: String, method: String = "GET"): Request.Builder =
        Request.Builder().url(base.newBuilder().addPathSegments(path).build())

    /** Attaches `Relay-Sig` headers. [signedPath] must exclude the query string. */
    private fun Request.Builder.signed(method: String, signedPath: String): Request.Builder = apply {
        auth?.headers(method, signedPath)?.forEach { (k, v) -> header(k, v) }
    }

    private suspend fun execute(request: Request): Response = withContext(Dispatchers.IO) {
        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            val message = runCatching {
                JSONObject(response.body.string()).optString("error")
            }.getOrDefault("")
            response.close()
            throw RelayApiException(response.code, message)
        }
        response
    }

    private suspend fun get(path: String, authenticated: Boolean = true): JSONObject {
        val builder = requestBuilder(path).get()
        if (authenticated) builder.signed("GET", "/$path")
        return execute(builder.build()).use { it.json() }
    }

    private suspend fun postJson(
        path: String,
        body: JSONObject?,
        authenticated: Boolean = true,
    ): JSONObject {
        val builder = requestBuilder(path, "POST").post(body.orEmptyBody())
        if (authenticated) builder.signed("POST", "/$path")
        return execute(builder.build()).use { it.json() }
    }

    private suspend fun postNoContent(path: String, body: JSONObject) {
        execute(
            requestBuilder(path, "POST").post(body.toString().toRequestBody(JSON))
                .signed("POST", "/$path").build(),
        ).close()
    }

    private suspend fun putNoContent(path: String, body: JSONObject) {
        execute(
            requestBuilder(path, "PUT").put(body.toString().toRequestBody(JSON))
                .signed("PUT", "/$path").build(),
        ).close()
    }

    private fun JSONObject?.orEmptyBody(): RequestBody =
        (this?.toString() ?: "{}").toRequestBody(JSON)

    private fun Response.json(): JSONObject =
        runCatching { JSONObject(body.string()) }.getOrElse { throw MalformedResponseException() }
}

// ------------------------------------------------------------------ helpers

private fun ByteArray.b64(): String = Base64.getEncoder().encodeToString(this)
private fun String.unb64(): ByteArray = Base64.getDecoder().decode(this)

private fun SignedPublicPreKey.toJson(): JSONObject = JSONObject()
    .put("keyId", id)
    .put("publicKey", Base64.getEncoder().encodeToString(publicKey))
    .put("signature", Base64.getEncoder().encodeToString(signature))

private fun JSONObject.toSignedPreKey(): SignedPublicPreKey = SignedPublicPreKey(
    id = getInt("keyId"),
    publicKey = Base64.getDecoder().decode(getString("publicKey")),
    signature = Base64.getDecoder().decode(getString("signature")),
)

private fun <T> JSONArray.map(transform: (JSONObject) -> T): List<T> =
    (0 until length()).map { transform(getJSONObject(it)) }

private fun <T> JSONArray.mapStrings(transform: (String) -> T): List<T> =
    (0 until length()).map { transform(getString(it)) }
