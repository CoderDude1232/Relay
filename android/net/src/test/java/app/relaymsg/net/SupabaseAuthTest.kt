package app.relaymsg.net

import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The account layer's first hop (PROTOCOL.md §7.8).
 *
 * Worth pinning because the relay never sees the password — it only sees the
 * token this returns — so a malformed request here surfaces much later as a
 * relay rejection that looks like something else entirely.
 */
class SupabaseAuthTest {

    private lateinit var server: MockWebServer
    private lateinit var auth: SupabaseAuth

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        auth = SupabaseAuth(
            projectUrl = server.url("/").toString().trimEnd('/'),
            anonKey = "anon-key",
        )
    }

    @After
    fun tearDown() = server.close()

    private fun respond(code: Int, body: String) {
        server.enqueue(MockResponse.Builder().code(code).body(body).build())
    }

    private val session = """
        {"access_token":"at","refresh_token":"rt","user":{"id":"user-1","email":"a@b.co"}}
    """.trimIndent()

    @Test
    fun `sign up posts the project's anon key both ways`() = runTest {
        respond(200, session)
        auth.signUp("a@b.co", "hunter22")

        val request = server.takeRequest()
        assertEquals("/auth/v1/signup", request.url.encodedPath)
        // Supabase wants it as a header AND as a bearer token; one alone 401s.
        assertEquals("anon-key", request.headers["apikey"])
        assertEquals("Bearer anon-key", request.headers["Authorization"])
        assertTrue(request.body!!.utf8().contains("\"email\":\"a@b.co\""))
    }

    @Test
    fun `sign in uses the password grant`() = runTest {
        respond(200, session)
        val result = auth.signIn("a@b.co", "hunter22")

        val request = server.takeRequest()
        assertEquals("/auth/v1/token", request.url.encodedPath)
        assertEquals("password", request.url.queryParameter("grant_type"))
        assertEquals("at", result.accessToken)
        assertEquals("rt", result.refreshToken)
        assertEquals("user-1", result.userId)
        assertEquals("a@b.co", result.email)
    }

    @Test
    fun `refresh uses the refresh token grant`() = runTest {
        respond(200, session)
        auth.refresh("old-token")

        val request = server.takeRequest()
        assertEquals("refresh_token", request.url.queryParameter("grant_type"))
        assertTrue(request.body!!.utf8().contains("old-token"))
    }

    @Test
    fun `a sign-up needing email confirmation says so instead of returning a blank token`() =
        runTest {
            // Supabase returns 200 with a user and no session when confirmation
            // is on. Passing an empty token to the relay would fail there with
            // something far less useful.
            respond(200, """{"user":{"id":"user-1","email":"a@b.co"}}""")

            val error = assertThrows(SupabaseAuthException::class.java) {
                kotlinx.coroutines.runBlocking { auth.signUp("a@b.co", "hunter22") }
            }
            assertTrue(error.reason.contains("confirm"))
        }

    @Test
    fun `an error reports Supabase's own message`() = runTest {
        respond(400, """{"error_description":"Invalid login credentials"}""")

        val error = assertThrows(SupabaseAuthException::class.java) {
            kotlinx.coroutines.runBlocking { auth.signIn("a@b.co", "wrong") }
        }
        assertEquals(400, error.status)
        assertEquals("Invalid login credentials", error.reason)
    }

    @Test
    fun `an unparseable error does not leak the response body`() = runTest {
        // The body of a failed auth call can contain the token that was sent.
        respond(500, """<html>gateway error for token eyJhbGciOi...</html>""")

        val error = assertThrows(SupabaseAuthException::class.java) {
            kotlinx.coroutines.runBlocking { auth.signIn("a@b.co", "pw") }
        }
        assertEquals("", error.reason)
        assertTrue(error.message!!.contains("500"))
        assertTrue(!error.message!!.contains("eyJhbGciOi"))
    }
}
