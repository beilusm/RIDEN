package io.github.beilusm.ridenps.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

@Composable
expect fun platformColorScheme(dark: Boolean): ColorScheme?

val LocalMeasurementColors = staticCompositionLocalOf {
    listOf(Color(0xff86d5b0), Color(0xff83d2e3), Color(0xffffb4a8))
}

@Composable
fun RidenTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val platformColors = platformColorScheme(dark)
    val colors = platformColors ?: if (dark) darkColorScheme(
        primary = Color(0xff86d5b0), secondary = Color(0xffc5c9cd), tertiary = Color(0xff83d2e3),
        onPrimary = Color(0xff003823), onSecondary = Color(0xff2c3135), onTertiary = Color(0xff003640),
        background = Color(0xff131517), surface = Color(0xff131517),
        primaryContainer = Color(0xff194e38), onPrimaryContainer = Color(0xffb1f1cd),
        secondaryContainer = Color(0xff34393d), onSecondaryContainer = Color(0xffe2e6ea),
        tertiaryContainer = Color(0xff164e59), onTertiaryContainer = Color(0xffb5ecf7),
        surfaceContainer = Color(0xff1f2123), surfaceContainerHigh = Color(0xff292b2e),
        surfaceContainerHighest = Color(0xff343639), surfaceContainerLow = Color(0xff191b1d),
        surfaceContainerLowest = Color(0xff0e1012), surfaceVariant = Color(0xff42464a),
        surfaceBright = Color(0xff393b3e), surfaceDim = Color(0xff131517),
        onSurface = Color(0xffe3e5e8), onSurfaceVariant = Color(0xffc3c7cb),
        outline = Color(0xff8d9297), outlineVariant = Color(0xff42464a),
        inverseSurface = Color(0xffe3e5e8), inverseOnSurface = Color(0xff2e3033),
        inversePrimary = Color(0xff176b4c), surfaceTint = Color(0xff86d5b0)
    ) else lightColorScheme(
        primary = Color(0xff176b4c), secondary = Color(0xff595f65), tertiary = Color(0xff006b7c),
        onPrimary = Color.White, onSecondary = Color.White, onTertiary = Color.White,
        background = Color(0xfff9fafb), surface = Color(0xfff9fafb),
        primaryContainer = Color(0xffb1f1cd), onPrimaryContainer = Color(0xff002113),
        secondaryContainer = Color(0xffe2e6ea), onSecondaryContainer = Color(0xff1d2226),
        tertiaryContainer = Color(0xffb5ecf7), onTertiaryContainer = Color(0xff001f26),
        surfaceContainer = Color(0xffeef0f2), surfaceContainerHigh = Color(0xffe8eaed),
        surfaceContainerHighest = Color(0xffe2e4e7), surfaceContainerLow = Color(0xfff3f5f7),
        surfaceContainerLowest = Color.White, surfaceVariant = Color(0xffe1e5e9),
        surfaceBright = Color(0xfff9fafb), surfaceDim = Color(0xffd9dbde),
        onSurface = Color(0xff1a1c1e), onSurfaceVariant = Color(0xff42474c),
        outline = Color(0xff73797f), outlineVariant = Color(0xffc3c8cd),
        inverseSurface = Color(0xff2e3033), inverseOnSurface = Color(0xfff0f2f4),
        inversePrimary = Color(0xff86d5b0), surfaceTint = Color(0xff176b4c)
    )
    val measurements = listOf(colors.primary, colors.tertiary, platformColors?.secondary ?: if (dark) Color(0xffffb4a8) else Color(0xff9c4636))
    CompositionLocalProvider(LocalMeasurementColors provides measurements) {
        MaterialTheme(colorScheme = colors, content = content)
    }
}

fun number(value: Double, digits: Int = 2): String {
    require(digits in 0..6)
    val scale = (1..digits).fold(1) { value, _ -> value * 10 }
    val raw = kotlin.math.round(kotlin.math.abs(value) * scale).toLong()
    val sign = if (value < 0 && raw != 0L) "-" else ""
    return if (digits == 0) "$sign$raw" else "$sign${raw / scale}.${(raw % scale).toString().padStart(digits, '0')}"
}
