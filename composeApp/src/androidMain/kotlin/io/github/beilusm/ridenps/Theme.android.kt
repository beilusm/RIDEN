package io.github.beilusm.ridenps.ui

import android.os.Build
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

@Composable
actual fun platformColorScheme(dark: Boolean): ColorScheme? = if (Build.VERSION.SDK_INT >= 31) {
    if (dark) dynamicDarkColorScheme(LocalContext.current) else dynamicLightColorScheme(LocalContext.current)
} else null
