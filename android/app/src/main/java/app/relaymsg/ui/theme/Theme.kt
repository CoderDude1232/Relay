package app.relaymsg.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

/**
 * Light: the deep stop of the bolt gradient on paper. White on it is 4.72:1,
 * which passes — but only just, so anything sitting on the accent is pure
 * white, never a tint.
 */
private val LightColors = lightColorScheme(
    primary = Magenta,
    onPrimary = Page,
    primaryContainer = MagentaTint,
    onPrimaryContainer = MagentaDeep,

    // Magenta as *text* needs the darker step; the band colour reaches only
    // 4.72:1 and body copy wants more headroom than that.
    secondary = MagentaInk,
    onSecondary = Page,
    secondaryContainer = MagentaTint,
    onSecondaryContainer = MagentaDeep,

    tertiary = MagentaDeep,
    onTertiary = Page,

    background = Page,
    onBackground = Ink,
    surface = Page,
    onSurface = Ink,

    surfaceVariant = Grey,
    onSurfaceVariant = Ink70,
    surfaceContainerLowest = Page,
    surfaceContainerLow = Grey,
    surfaceContainer = Grey,
    surfaceContainerHigh = Grey2,
    surfaceContainerHighest = Grey2,

    outline = Ink45,
    outlineVariant = Line,

    error = ErrorLight,
    onError = Page,
    errorContainer = ErrorContainerLight,
    onErrorContainer = OnErrorContainerLight,
)

/**
 * Dark: the wordmark's black as the ground, and the **bright** stop as the
 * accent — the deep stop manages only 4.15:1 here, which is large-text only.
 */
private val DarkColors = darkColorScheme(
    primary = MagentaBright,
    onPrimary = OnMagentaBright,
    primaryContainer = MagentaTintDark,
    onPrimaryContainer = MagentaBright,

    secondary = MagentaBright,
    onSecondary = OnMagentaBright,
    secondaryContainer = MagentaTintDark,
    onSecondaryContainer = MagentaBright,

    tertiary = MagentaDeepDark,
    onTertiary = Page,

    background = PageDark,
    onBackground = InkDark,
    // Surfaces lift *away* from the ground in dark rather than sinking, which
    // is what makes a card read as a card without a border.
    surface = PageDark,
    onSurface = InkDark,

    surfaceVariant = Grey2Dark,
    onSurfaceVariant = Ink70Dark,
    surfaceContainerLowest = PageDark,
    surfaceContainerLow = GreyDark,
    surfaceContainer = SurfaceDark,
    surfaceContainerHigh = Grey2Dark,
    surfaceContainerHighest = Grey2Dark,

    outline = Ink45Dark,
    outlineVariant = LineDark,

    error = ErrorDark,
    onError = OnErrorContainerLight,
    errorContainer = ErrorContainerDark,
    onErrorContainer = ErrorContainerLight,
)

@Composable
fun RelayTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val colorScheme = if (darkTheme) DarkColors else LightColors

    // Dynamic colour is deliberately off. It would repaint the app from the
    // user's wallpaper, which is a nice Android idea and the wrong one here:
    // the magenta is the product's identity, shared with iOS and the website,
    // and an app that changes colour per phone has none.

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            // Status-bar icons have to flip with the theme, or they vanish
            // against their own background.
            WindowCompat.getInsetsController(
                (view.context as android.app.Activity).window,
                view,
            ).isAppearanceLightStatusBars = !darkTheme
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content,
    )
}
