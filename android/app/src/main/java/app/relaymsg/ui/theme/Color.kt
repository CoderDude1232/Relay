package app.relaymsg.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Relay's palette, taken from the brand rather than from Material's defaults.
 *
 * These are the same tokens `relaymsg.app` uses, so the app, the site and iOS
 * read as one product. The magenta pair is the logo's bolt gradient: the deep
 * stop is the accent on light, the bright stop on dark.
 *
 * Contrast is measured, not assumed — the ratios in the comments below are
 * WCAG values against the ground each colour is actually used on.
 */

// --- the wordmark's black, and its steps -----------------------------------
internal val Ink = Color(0xFF12090F)
internal val Ink70 = Color(0xFF4C4046)
internal val Ink45 = Color(0xFF776A70)

internal val InkDark = Color(0xFFF6EFF3)
internal val Ink70Dark = Color(0xFFC0B2BA)
internal val Ink45Dark = Color(0xFF8F808A)

// --- the bolt gradient ------------------------------------------------------
/** Deep stop. The solid accent, and the only fill white text sits on (4.72:1). */
internal val Magenta = Color(0xFFC611D6)

/** Bright stop. 6.52:1 on the dark ground, where the deep stop manages only 4.15. */
internal val MagentaBright = Color(0xFFF63BFF)

internal val MagentaDeep = Color(0xFF7E0A8A)
internal val MagentaDeepDark = Color(0xFF9C0CAB)

/** Magenta as text on paper — 6.31:1, which the band colour would not reach. */
internal val MagentaInk = Color(0xFFA50FB4)

internal val MagentaTint = Color(0xFFF9E4FB)
internal val MagentaTintDark = Color(0xFF3A1240)

/** Dark enough to sit on the bright stop at 6.10:1. */
internal val OnMagentaBright = Color(0xFF2B0030)

// --- grounds ----------------------------------------------------------------
internal val Page = Color(0xFFFFFFFF)
internal val Grey = Color(0xFFF6F1F5)
internal val Grey2 = Color(0xFFEBE2E9)
internal val Line = Color(0xFFE4D9E1)

internal val PageDark = Color(0xFF12090F)
internal val SurfaceDark = Color(0xFF211520)
internal val GreyDark = Color(0xFF1B1018)
internal val Grey2Dark = Color(0xFF2A1C26)
internal val LineDark = Color(0xFF31222C)

// --- states -----------------------------------------------------------------
// The brand has no error colour, so these are Material's, which are tuned for
// exactly this job and do not fight the magenta.
internal val ErrorLight = Color(0xFFBA1A1A)
internal val OnErrorContainerLight = Color(0xFF410002)
internal val ErrorContainerLight = Color(0xFFFFDAD6)
internal val ErrorDark = Color(0xFFFFB4AB)
internal val ErrorContainerDark = Color(0xFF93000A)
