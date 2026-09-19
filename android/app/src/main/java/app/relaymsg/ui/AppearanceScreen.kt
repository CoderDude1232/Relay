package app.relaymsg.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.relaymsg.ui.theme.Magenta
import app.relaymsg.ui.theme.MagentaDeep

/**
 * Wallpaper and bubble colour for one conversation.
 *
 * Per-conversation rather than app-wide, and never sent — the other side keeps
 * whatever they chose. Shown over a live preview, because a bubble gradient
 * against a wallpaper is not something anyone can judge from two swatches.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppearanceScreen(
    title: String,
    wallpaperId: String?,
    bubbleKey: String?,
    onPick: (wallpaperId: String?, bubbleKey: String?) -> Unit,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Appearance") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    TextButton(onClick = { onPick(null, null) }) { Text("Reset") }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()),
        ) {
            Preview(title, wallpaperId, bubbleKey)

            Header("Themes")
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ChatAppearance.themes.take(3).forEach { theme ->
                    ThemeChip(theme, Modifier.weight(1f)) {
                        onPick(theme.wallpaperId, theme.bubbleKey)
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ChatAppearance.themes.drop(3).forEach { theme ->
                    ThemeChip(theme, Modifier.weight(1f)) {
                        onPick(theme.wallpaperId, theme.bubbleKey)
                    }
                }
            }

            Header("Wallpaper")
            LazyVerticalGrid(
                columns = GridCells.Adaptive(88.dp),
                modifier = Modifier.fillMaxWidth().height(200.dp).padding(horizontal = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(ChatAppearance.wallpapers, key = { it.id }) { wallpaper ->
                    Swatch(
                        brush = wallpaper.brush,
                        label = wallpaper.title,
                        selected = wallpaper.id == (wallpaperId ?: "none"),
                        onClick = { onPick(wallpaper.id, bubbleKey) },
                    )
                }
            }

            Header("Your bubbles")
            LazyVerticalGrid(
                columns = GridCells.Adaptive(72.dp),
                modifier = Modifier.fillMaxWidth().height(170.dp).padding(horizontal = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(ChatAppearance.bubbleTints, key = { it.key }) { tint ->
                    Swatch(
                        brush = Brush.linearGradient(tint.stops),
                        label = "",
                        selected = tint.key == bubbleKey,
                        onClick = { onPick(wallpaperId, tint.key) },
                    )
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun Preview(title: String, wallpaperId: String?, bubbleKey: String?) {
    val wallpaper = ChatAppearance.wallpaper(wallpaperId).brush
    val bubble = Brush.linearGradient(
        ChatAppearance.bubbleTint(bubbleKey) ?: listOf(MagentaDeep, Magenta),
    )
    Column(
        Modifier
            .fillMaxWidth()
            .padding(16.dp)
            .clip(RoundedCornerShape(16.dp))
            .then(
                if (wallpaper != null) {
                    Modifier.background(wallpaper)
                } else {
                    Modifier.background(MaterialTheme.colorScheme.surfaceVariant)
                },
            )
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row {
            Text(
                "Looks good",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier
                    .clip(RoundedCornerShape(16.dp, 16.dp, 16.dp, 4.dp))
                    .background(MaterialTheme.colorScheme.surface)
                    .padding(horizontal = 12.dp, vertical = 7.dp),
            )
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Text(
                "In $title",
                style = MaterialTheme.typography.bodyMedium,
                color = Color.White,
                modifier = Modifier
                    .clip(RoundedCornerShape(16.dp, 16.dp, 4.dp, 16.dp))
                    .background(bubble)
                    .padding(horizontal = 12.dp, vertical = 7.dp),
            )
        }
    }
}

@Composable
private fun Header(text: String) = Text(
    text = text.uppercase(),
    style = MaterialTheme.typography.labelMedium,
    fontWeight = FontWeight.SemiBold,
    color = MaterialTheme.colorScheme.primary,
    modifier = Modifier.padding(start = 20.dp, top = 16.dp, bottom = 8.dp),
)

@Composable
private fun ThemeChip(theme: ChatAppearance.Theme, modifier: Modifier, onClick: () -> Unit) {
    val wallpaper = ChatAppearance.wallpaper(theme.wallpaperId).brush
    Column(
        modifier.clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(1.4f)
                .clip(RoundedCornerShape(12.dp))
                .then(if (wallpaper != null) Modifier.background(wallpaper) else Modifier),
            contentAlignment = Alignment.BottomEnd,
        ) {
            ChatAppearance.bubbleTint(theme.bubbleKey)?.let { stops ->
                Box(
                    Modifier
                        .padding(8.dp)
                        .size(width = 34.dp, height = 14.dp)
                        .clip(RoundedCornerShape(7.dp))
                        .background(Brush.linearGradient(stops)),
                )
            }
        }
        Text(
            theme.name,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

@Composable
private fun Swatch(brush: Brush?, label: String, selected: Boolean, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(CircleShape)
                .then(
                    if (brush != null) {
                        Modifier.background(brush)
                    } else {
                        Modifier.background(MaterialTheme.colorScheme.surfaceVariant)
                    },
                )
                .then(
                    // The ring is the only affordance a gradient circle has;
                    // a checkmark on top of some of these would vanish.
                    if (selected) {
                        Modifier.border(3.dp, MaterialTheme.colorScheme.primary, CircleShape)
                    } else {
                        Modifier
                    },
                )
                .clickable(onClick = onClick),
        )
        if (label.isNotEmpty()) {
            Text(
                label,
                style = MaterialTheme.typography.labelSmall,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}
