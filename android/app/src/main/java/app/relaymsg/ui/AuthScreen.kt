package app.relaymsg.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/** Which part of onboarding is on screen. */
enum class AuthStep { WELCOME, SIGN_UP, SIGN_IN, USERNAME }

/** The relay's own username rule; checked here to save a round-trip. */
private val USERNAME = Regex("^[a-zA-Z0-9._\\-]{1,64}$")

/**
 * Sign-up, sign-in, and the username prompt.
 *
 * Accounts are held by Supabase and verified by the relay server-to-server
 * (PROTOCOL.md §7.8), so an email and password get a session there first and the
 * relay mints or recovers the account from it. The username is only asked for
 * when the relay says it has no account for this user yet.
 */
@Composable
fun AuthScreen(
    step: AuthStep,
    busy: Boolean,
    error: String?,
    onSignUp: (email: String, password: String) -> Unit,
    onSignIn: (email: String, password: String) -> Unit,
    onSubmitUsername: (String) -> Unit,
    onShowSignUp: () -> Unit,
    onShowSignIn: () -> Unit,
    onLinkDevice: () -> Unit,
    onBack: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp)
            .imePadding(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Relay", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
        Text(
            "Private messaging, end-to-end encrypted.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp, bottom = 32.dp),
        )

        when (step) {
            AuthStep.WELCOME -> Welcome(busy, onShowSignUp, onShowSignIn, onLinkDevice)
            AuthStep.SIGN_UP -> EmailForm(
                submitLabel = "Create account",
                confirmPassword = true,
                busy = busy,
                onSubmit = onSignUp,
            )
            AuthStep.SIGN_IN -> EmailForm(
                submitLabel = "Sign in",
                confirmPassword = false,
                busy = busy,
                onSubmit = onSignIn,
                footnote = "Signing in on a new device gives it a new safety number. " +
                    "To keep your existing one, link from your other device instead.",
            )
            AuthStep.USERNAME -> UsernameForm(busy, onSubmitUsername)
        }

        error?.let {
            Text(
                it,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 16.dp),
            )
        }

        if (step != AuthStep.WELCOME) {
            TextButton(onClick = onBack, enabled = !busy, modifier = Modifier.padding(top = 8.dp)) {
                Text("Back")
            }
        }
    }
}

@Composable
private fun Welcome(
    busy: Boolean,
    onShowSignUp: () -> Unit,
    onShowSignIn: () -> Unit,
    onLinkDevice: () -> Unit,
) {
    Button(onClick = onShowSignUp, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
        Text("Create account with email")
    }
    OutlinedButton(
        onClick = onShowSignIn,
        enabled = !busy,
        modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
    ) {
        Text("I already have an account")
    }
    TextButton(onClick = onLinkDevice, enabled = !busy, modifier = Modifier.padding(top = 16.dp)) {
        Text("Already have Relay on another device?")
    }
}

@Composable
private fun EmailForm(
    submitLabel: String,
    confirmPassword: Boolean,
    busy: Boolean,
    onSubmit: (String, String) -> Unit,
    footnote: String? = null,
) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }

    // Supabase's own minimum. Rejecting here saves a round-trip to be told so.
    val longEnough = password.length >= 6
    val matches = !confirmPassword || password == confirm
    val valid = email.contains("@") && longEnough && matches && !busy

    OutlinedTextField(
        value = email,
        onValueChange = { email = it.trim() },
        label = { Text("Email") },
        singleLine = true,
        enabled = !busy,
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Email,
            imeAction = ImeAction.Next,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = password,
        onValueChange = { password = it },
        label = { Text("Password") },
        singleLine = true,
        enabled = !busy,
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Password,
            imeAction = if (confirmPassword) ImeAction.Next else ImeAction.Done,
        ),
        supportingText = if (confirmPassword && password.isNotEmpty() && !longEnough) {
            { Text("At least 6 characters.") }
        } else {
            null
        },
        isError = confirmPassword && password.isNotEmpty() && !longEnough,
        modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
    )
    if (confirmPassword) {
        OutlinedTextField(
            value = confirm,
            onValueChange = { confirm = it },
            label = { Text("Confirm password") },
            singleLine = true,
            enabled = !busy,
            visualTransformation = PasswordVisualTransformation(),
            isError = confirm.isNotEmpty() && !matches,
            supportingText = if (confirm.isNotEmpty() && !matches) {
                { Text("Passwords don't match.") }
            } else {
                null
            },
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Password,
                imeAction = ImeAction.Done,
            ),
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
        )
    }

    Button(
        onClick = { onSubmit(email, password) },
        enabled = valid,
        modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
    ) {
        if (busy) CircularProgressIndicator(Modifier.height(18.dp)) else Text(submitLabel)
    }

    footnote?.let {
        Text(
            it,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 16.dp),
        )
    }
}

@Composable
private fun UsernameForm(busy: Boolean, onSubmit: (String) -> Unit) {
    var username by remember { mutableStateOf("") }
    val valid = username.matches(USERNAME)

    Text(
        "Choose a username so people can find you.",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
        modifier = Modifier.padding(bottom = 16.dp),
    )
    OutlinedTextField(
        value = username,
        onValueChange = { username = it },
        label = { Text("Username") },
        singleLine = true,
        enabled = !busy,
        supportingText = { Text("Letters, numbers, dots, underscores and hyphens.") },
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        modifier = Modifier.fillMaxWidth(),
    )
    Button(
        onClick = { onSubmit(username) },
        enabled = valid && !busy,
        modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
    ) {
        if (busy) CircularProgressIndicator(Modifier.height(18.dp)) else Text("Continue")
    }
}
