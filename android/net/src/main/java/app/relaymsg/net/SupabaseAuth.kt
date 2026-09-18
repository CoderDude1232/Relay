package app.relaymsg.net

import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

/** A Supabase auth failure, with the message Supabase itself gave. */
class SupabaseAuthException(val status: Int, val reason: String) :
    IOException(reason.ifEmpty { "Authentication failed (HTTP $status)" })

/** A signed-in Supabase session. The tokens are credentials — treat them as such. */
data class SupabaseSession(
    val accessToken: String,
    val refreshToken: String,
    val userId: String,
    val email: String,
)

/**
 * Relay's account layer (PROTOCOL.md §7.8).
 *
 * The relay does not hold passwords for humans: it verifies a **Supabase**
 * access token server-to-server and resolves the account from the Supabase user
 * id, falling back to the email. So signing up and signing in both mean getting
 * a Supabase session first, then presenting it to `POST /v1/accounts/oauth`.
 *
 * No SDK, same as iOS — it is three JSON posts. The `anonKey` is a public
 * client key (its JWT role is literally `anon`); it identifies the project and
 * grants nothing on its own.
 */
class SupabaseAuth(
    private val projectUrl: String = PROJECT_URL,
    private val anonKey: String = ANON_KEY,
    private val client: OkHttpClient = OkHttpClient(),
) {
    suspend fun signUp(email: String, password: String): SupabaseSession =
        post("/auth/v1/signup", JSONObject().put("email", email).put("password", password))

    suspend fun signIn(email: String, password: String): SupabaseSession =
        post(
            "/auth/v1/token?grant_type=password",
            JSONObject().put("email", email).put("password", password),
        )

    /** Exchanges a stored refresh token for a fresh pair. Call after a 401. */
    suspend fun refresh(refreshToken: String): SupabaseSession =
        post(
            "/auth/v1/token?grant_type=refresh_token",
            JSONObject().put("refresh_token", refreshToken),
        )

    private suspend fun post(path: String, body: JSONObject): SupabaseSession =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(projectUrl + path)
                .header("apikey", anonKey)
                .header("Authorization", "Bearer $anonKey")
                .post(body.toString().toRequestBody(JSON))
                .build()

            client.newCall(request).execute().use { response ->
                val text = response.body.string()
                if (!response.isSuccessful) throw SupabaseAuthException(response.code, reason(text))
                parse(text)
            }
        }

    /**
     * Supabase reports errors under several keys depending on the endpoint and
     * the version; showing the raw body would leak the token on some of them.
     */
    private fun reason(body: String): String = runCatching {
        val json = JSONObject(body)
        listOf("error_description", "msg", "message", "error")
            .firstNotNullOfOrNull { key -> json.optString(key).takeIf { it.isNotEmpty() } }
            .orEmpty()
    }.getOrDefault("")

    private fun parse(body: String): SupabaseSession {
        val json = JSONObject(body)
        val user = json.optJSONObject("user")
        // A confirmation-required sign-up returns a user with no session. Better
        // to say so than to hand back a blank token and fail later.
        val accessToken = json.optString("access_token")
        if (accessToken.isEmpty()) {
            throw SupabaseAuthException(
                200,
                "Check your email to confirm the account, then sign in.",
            )
        }
        return SupabaseSession(
            accessToken = accessToken,
            refreshToken = json.optString("refresh_token"),
            userId = user?.optString("id").orEmpty(),
            email = user?.optString("email").orEmpty(),
        )
    }

    companion object {
        /**
         * The same project the iOS client uses (`SupabaseConfig`). Both clients
         * must point at one project or an account created on one is invisible to
         * the other.
         */
        const val PROJECT_URL = "https://kmhxqtouqlfefzaedoqx.supabase.co"

        /** Public client key, role `anon`. Safe to ship; it authorises nothing. */
        const val ANON_KEY =
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImttaHhxdG91" +
                "cWxmZWZ6YWVkb3F4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY4MjI1NjEsImV4cCI6MjEwMjM5" +
                "ODU2MX0.9uwaGRkEGNa6G6ZvJYTQ5oAw04JXHf4rEiqlCfpCP3E"

        private val JSON = "application/json; charset=utf-8".toMediaType()
    }
}
