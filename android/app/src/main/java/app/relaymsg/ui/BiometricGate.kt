package app.relaymsg.ui

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.fragment.app.FragmentActivity
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * The device's own unlock, used as the app's.
 *
 * Deliberately **not** a second secret: the database key is already wrapped by
 * a Keystore key, and inventing an app PIN would add a weaker credential
 * guarding the same data. This only decides whether to show the UI to whoever
 * is holding an already-unlocked phone.
 */
object BiometricGate {

    /** Biometric, or the device PIN/pattern when no biometric is enrolled. */
    private const val ALLOWED =
        BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL

    fun isAvailable(activity: FragmentActivity): Boolean =
        BiometricManager.from(activity).canAuthenticate(ALLOWED) ==
            BiometricManager.BIOMETRIC_SUCCESS

    /**
     * Prompts, and resolves to whether the user got through.
     *
     * A failure is not an error to report: the user cancelling is the common
     * case, and it means the same thing as failing — do not show the app.
     */
    suspend fun authenticate(activity: FragmentActivity, reason: String): Boolean =
        suspendCancellableCoroutine { continuation ->
            val prompt = BiometricPrompt(
                activity,
                androidx.core.content.ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (continuation.isActive) continuation.resume(true)
                    }

                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        if (continuation.isActive) continuation.resume(false)
                    }
                    // onAuthenticationFailed is a single bad read, not a
                    // decision; the prompt stays up and tries again.
                },
            )
            prompt.authenticate(
                BiometricPrompt.PromptInfo.Builder()
                    .setTitle("Unlock Relay")
                    .setSubtitle(reason)
                    .setAllowedAuthenticators(ALLOWED)
                    .build(),
            )
            continuation.invokeOnCancellation { prompt.cancelAuthentication() }
        }
}
