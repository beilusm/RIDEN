package io.github.beilusm.ridenps.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import io.github.beilusm.ridenps.core.*

data class HudSettings(val voltage: Boolean = true, val current: Boolean = true, val power: Boolean = true, val chart: Boolean = true, val opacity: Float = 0.94f, val locked: Boolean = false)

@Composable
fun FloatingMonitor(state: AppState, settings: HudSettings, onSettings: (HudSettings) -> Unit, onRestore: () -> Unit, header: @Composable (@Composable () -> Unit) -> Unit = { it() }) {
    var dialog by remember { mutableStateOf(false) }
    RidenTheme {
        Surface(Modifier.fillMaxSize().alpha(settings.opacity)) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                header {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("RIDEN", Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
                        ToolButton(if (settings.locked) Icons.Default.Lock else Icons.Default.LockOpen, if (settings.locked) "解锁悬浮窗" else "锁定悬浮窗") { onSettings(settings.copy(locked = !settings.locked)) }
                        ToolButton(Icons.Default.Tune, "悬浮窗设置") { dialog = true }
                        ToolButton(Icons.Default.OpenInFull, "恢复主窗口", onClick = onRestore)
                    }
                }
                val colors = LocalMeasurementColors.current
                val enabled = listOf(settings.voltage, settings.current, settings.power)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    enabled.forEachIndexed { i, visible ->
                        if (visible) Column(Modifier.weight(1f)) {
                            val value = when (i) { 0 -> state.device.snapshot.voltage; 1 -> state.device.snapshot.current; else -> state.device.snapshot.power }
                            Text(listOf("V", "A", "W")[i], style = MaterialTheme.typography.labelSmall, color = colors[i])
                            BoxWithConstraints {
                                val digits = when (i) { 0 -> state.device.definitions[10].digits; 1 -> state.device.definitions[11].digits; else -> 2 }
                                Text(if (state.device.capabilities != null) number(value, digits) else "--", fontFamily = FontFamily.Monospace, style = if (maxWidth < 100.dp) MaterialTheme.typography.titleMedium else MaterialTheme.typography.titleLarge, color = colors[i], maxLines = 1)
                            }
                        }
                    }
                }
                if (settings.chart) Canvas(Modifier.fillMaxWidth().weight(1f)) {
                    val points = state.history.takeLast(100)
                    if (points.size > 1) enabled.forEachIndexed { metric, visible ->
                        if (visible) {
                            fun value(point: PowerSnapshot) = when (metric) { 0 -> point.voltage; 1 -> point.current; else -> point.power }
                            val maximum = points.maxOf { value(it) }.coerceAtLeast(0.1) * 1.1
                            val path = Path()
                            points.forEachIndexed { index, point ->
                                val x = size.width * index / (points.size - 1)
                                val y = size.height * (1 - value(point) / maximum).toFloat()
                                if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
                            }
                            drawPath(path, colors[metric], style = Stroke(2.dp.toPx()))
                        }
                    }
                }
                Text("${state.connection} · ${state.device.mode}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (dialog) HudSettingsDialog(settings, onDismiss = { dialog = false }) { onSettings(it); dialog = false }
    }
}

@Composable
private fun HudSettingsDialog(initial: HudSettings, onDismiss: () -> Unit, onApply: (HudSettings) -> Unit) {
    var settings by remember { mutableStateOf(initial) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("悬浮窗设置") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("电压" to settings.voltage, "电流" to settings.current, "功率" to settings.power, "趋势图" to settings.chart).forEachIndexed { index, (label, value) ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(label)
                    Switch(value, { checked -> settings = when (index) { 0 -> settings.copy(voltage = checked); 1 -> settings.copy(current = checked); 2 -> settings.copy(power = checked); else -> settings.copy(chart = checked) } })
                }
            }
            Text("透明度 ${kotlin.math.round(settings.opacity * 100).toInt()}%", style = MaterialTheme.typography.labelLarge)
            Slider(settings.opacity, { settings = settings.copy(opacity = it) }, valueRange = 0.55f..1f, steps = 8)
        }
    }, confirmButton = { TextButton({ onApply(settings) }) { Text("应用") } }, dismissButton = { TextButton(onDismiss) { Text("取消") } })
}
