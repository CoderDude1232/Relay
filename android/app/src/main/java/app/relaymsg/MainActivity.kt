package app.relaymsg

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import app.relaymsg.ui.ChatScreen
import app.relaymsg.ui.ConversationListScreen
import app.relaymsg.ui.OnboardingScreen
import app.relaymsg.ui.theme.RelayTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            RelayTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    RelayApp()
                }
            }
        }
    }
}

@Composable
private fun RelayApp(viewModel: RelayViewModel = viewModel()) {
    val phase by viewModel.phase.collectAsState()
    val busy by viewModel.busy.collectAsState()

    when (val current = phase) {
        is AppPhase.Loading -> Centered { CircularProgressIndicator() }

        is AppPhase.SignedOut -> OnboardingScreen(
            busy = busy,
            error = null,
            onRegister = viewModel::register,
        )

        is AppPhase.Failed -> Centered {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(current.message, style = MaterialTheme.typography.bodyLarge)
                Button(onClick = viewModel::retry, modifier = Modifier.padding(top = 12.dp)) {
                    Text("Try again")
                }
            }
        }

        is AppPhase.Ready -> SignedIn(viewModel, current)
    }
}

@Composable
private fun SignedIn(viewModel: RelayViewModel, phase: AppPhase.Ready) {
    // From API 33 notifications need runtime consent. Asked once on first reach
    // of the signed-in UI; declining costs only the banner, not delivery.
    val permissionLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission(),
    ) { }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            permissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    val conversations by viewModel.conversations.collectAsState()
    val messages by viewModel.activeMessages.collectAsState()
    val connection by viewModel.connection.collectAsState()
    val busy by viewModel.busy.collectAsState()

    var openConversationId by remember { mutableStateOf<String?>(null) }

    val open = openConversationId
    if (open == null) {
        ConversationListScreen(
            username = phase.service.username,
            connection = connection,
            conversations = conversations,
            titleFor = viewModel::titleFor,
            busy = busy,
            onOpen = { id -> viewModel.openConversation(id); openConversationId = id },
            onStartConversation = viewModel::startConversation,
        )
    } else {
        val conversation = conversations.firstOrNull { it.id == open }
        ChatScreen(
            title = conversation?.let(viewModel::titleFor) ?: "Conversation",
            messages = messages,
            onSend = { body -> viewModel.send(open, body) },
            onBack = { viewModel.closeConversation(); openConversationId = null },
        )
    }
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { content() }
}
