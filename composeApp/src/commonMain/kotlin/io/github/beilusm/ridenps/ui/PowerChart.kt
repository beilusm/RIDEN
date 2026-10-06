package io.github.beilusm.ridenps.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import io.github.beilusm.ridenps.core.PowerSnapshot
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlin.math.*

private data class ChartMetric(val key: String, val label: String, val unit: String, val color: Color, val digits: Int, val value: (PowerSnapshot) -> Double)

private fun chartClock(timestamp: Long, milliseconds: Boolean = false): String {
    val local = Instant.fromEpochMilliseconds(timestamp).toLocalDateTime(TimeZone.currentSystemDefault())
    fun pad(value: Int) = value.toString().padStart(2, '0')
    return "${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}" +
        if (milliseconds) ".${(local.nanosecond / 1000000).toString().padStart(3, '0')}" else ""
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PowerChart(history: List<PowerSnapshot>, onClear: () -> Unit, height: Dp = 220.dp, voltageDigits: Int = 2, currentDigits: Int = 3) {
    var paused by remember { mutableStateOf(false) }
    var frozen by remember { mutableStateOf(emptyList<PowerSnapshot>()) }
    var voltage by remember { mutableStateOf(true) }
    var current by remember { mutableStateOf(true) }
    var power by remember { mutableStateOf(false) }
    var fromZero by remember { mutableStateOf(true) }
    var window by remember { mutableStateOf(150) }
    var offset by remember { mutableStateOf(0f) }
    var selectedTime by remember { mutableStateOf<Long?>(null) }
    val data = if (paused) frozen else history
    val maxOffset = (data.size - window).coerceAtLeast(0)
    val end = data.size - offset.toInt().coerceIn(0, maxOffset)
    val visible = data.subList((end - window).coerceAtLeast(0), end)
    val selected = selectedTime?.let { time -> visible.firstOrNull { it.timestamp == time } }
    val reading = selected ?: visible.lastOrNull()
    val colors = LocalMeasurementColors.current
    val metrics = listOf(
        ChartMetric("voltage", "电压", "V", colors[0], voltageDigits) { it.voltage },
        ChartMetric("current", "电流", "A", colors[1], currentDigits) { it.current },
        ChartMetric("power", "功率", "W", colors[2], 2) { it.power }
    )
    val enabled = listOf(voltage, current, power)
    val shown = metrics.filterIndexed { index, _ -> enabled[index] }
    val pick: (Float, Boolean) -> Unit = { fraction, pin ->
        nearestChartSample(visible, fraction)?.let {
            if (pin && !paused) { frozen = history; paused = true }
            selectedTime = it.timestamp
        }
    }
    Column(Modifier.fillMaxWidth().testTag("power-chart"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("实时波形", style = MaterialTheme.typography.titleMedium)
                val seconds = if (visible.size > 1) (visible.last().timestamp - visible.first().timestamp) / 1000.0 else 0.0
                Text("${if (paused) "已暂停" else "实时"} · ${number(seconds, 1)} s", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            ToolButton(if (paused) Icons.Default.PlayArrow else Icons.Default.Pause, if (paused) "继续波形" else "暂停波形") {
                if (!paused) frozen = history
                paused = !paused
                offset = 0f
                selectedTime = null
            }
            ToolButton(Icons.Default.ZoomOut, "缩小", window < 300) { window = (window + 75).coerceAtMost(300); selectedTime = null }
            ToolButton(Icons.Default.ZoomIn, "放大", window > 75) { window = (window - 75).coerceAtLeast(75); selectedTime = null }
            ToolButton(Icons.Default.DeleteOutline, "清空波形") { onClear(); frozen = emptyList(); offset = 0f; selectedTime = null }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            metrics.forEachIndexed { index, metric ->
                FilterChip(enabled[index], {
                    if (!enabled[index] || shown.size > 1) when (index) { 0 -> voltage = !voltage; 1 -> current = !current; else -> power = !power }
                }, label = { Text(metric.label) }, leadingIcon = { Icon(Icons.Default.Circle, null, tint = metric.color, modifier = Modifier.size(8.dp)) })
            }
            Spacer(Modifier.weight(1f))
            TooltipBox(positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(), tooltip = { PlainTooltip { Text(if (fromZero) "从零显示" else "自动量程") } }, state = rememberTooltipState()) {
                IconToggleButton(fromZero, { fromZero = it }, Modifier.size(32.dp)) { Icon(Icons.Default.VerticalAlignBottom, if (fromZero) "从零显示" else "自动量程", Modifier.size(20.dp)) }
            }
        }
        Row(Modifier.fillMaxWidth().height(32.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(if (selected != null) "选点" else if (paused) "窗口末尾" else "最新", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(reading?.let { chartClock(it.timestamp, true) } ?: "--:--:--", Modifier.weight(1f).testTag("chart-selected-time"), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelLarge)
            TooltipBox(positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(), tooltip = { PlainTooltip { Text("返回实时") } }, state = rememberTooltipState()) {
                IconButton(onClick = { paused = false; frozen = emptyList(); selectedTime = null; offset = 0f }, enabled = paused || selected != null, modifier = Modifier.size(32.dp)) { Icon(Icons.Default.Close, "返回实时", Modifier.size(18.dp)) }
            }
        }
        shown.forEach { metric ->
            MetricPlot(metric, visible, reading, selected, fromZero, (height / shown.size - 28.dp).coerceAtLeast(90.dp), pick, { if (!paused) selectedTime = null })
        }
        BoxWithConstraints(Modifier.fillMaxWidth().padding(start = 58.dp).height(16.dp)) {
            val first = visible.firstOrNull()?.timestamp
            val last = visible.lastOrNull()?.timestamp
            val short = first != null && last != null && last - first < 3000
            val intervals = if (short) 1 else if (maxWidth < 360.dp) 2 else 3
            val ticks = if (first != null && last != null && first != last) (0..intervals).map { first + (last - first) * it / intervals } else listOfNotNull(last)
            val labelWidth = if (short) 96.dp else 64.dp
            ticks.forEachIndexed { index, time ->
                val fraction = if (ticks.size == 1) 1f else index.toFloat() / intervals
                val x = (maxWidth * fraction - labelWidth / 2).coerceIn(0.dp, (maxWidth - labelWidth).coerceAtLeast(0.dp))
                val alignment = if (index == ticks.lastIndex) TextAlign.End else if (index == 0) TextAlign.Start else TextAlign.Center
                Text(chartClock(time, short), Modifier.width(labelWidth).offset(x = x), fontFamily = FontFamily.Monospace, textAlign = alignment, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (data.size > window) Slider(offset.coerceIn(0f, maxOffset.toFloat()), { offset = it; selectedTime = null }, valueRange = 0f..maxOffset.toFloat(), modifier = Modifier.semantics { contentDescription = "波形历史位置" })
    }
}

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun MetricPlot(metric: ChartMetric, data: List<PowerSnapshot>, reading: PowerSnapshot?, selected: PowerSnapshot?, fromZero: Boolean, height: Dp, onPick: (Float, Boolean) -> Unit, onExit: () -> Unit) {
    val values = data.map(metric.value)
    val axis = chartAxis(values, fromZero, 10.0.pow(-metric.digits))
    val tickDigits = max(metric.digits, ceil(-log10(axis.step)).toInt()).coerceIn(0, 6)
    val grid = MaterialTheme.colorScheme.outlineVariant
    val cursor = MaterialTheme.colorScheme.onSurfaceVariant
    val surface = MaterialTheme.colorScheme.surface
    val latestPick by rememberUpdatedState(onPick)
    val latestExit by rememberUpdatedState(onExit)
    val minimum = values.minOrNull()
    val maximum = values.maxOrNull()
    val average = values.takeIf { it.isNotEmpty() }?.average()
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(metric.label, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge, color = metric.color)
            Text("${reading?.let { number(metric.value(it), metric.digits) } ?: "--"} ${metric.unit}", Modifier.testTag("chart-readout-${metric.key}"), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.titleMedium, color = metric.color)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("最小" to minimum, "最大" to maximum, "平均" to average).forEach { (label, value) ->
                Text("$label ${value?.let { number(it, metric.digits) } ?: "--"}", Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Row(Modifier.fillMaxWidth().height(height)) {
            BoxWithConstraints(Modifier.width(58.dp).fillMaxHeight()) {
                axis.ticks.forEach { value ->
                    Text(number(value, tickDigits), Modifier.fillMaxWidth().padding(end = 8.dp).offset(y = (maxHeight * (1f - axis.fraction(value)) - 7.dp).coerceIn(0.dp, maxHeight - 14.dp)), style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.End, color = metric.color)
                }
            }
            Box(Modifier.weight(1f).fillMaxHeight().background(MaterialTheme.colorScheme.surfaceContainerLowest)) {
                Canvas(Modifier.fillMaxSize().testTag("plot-${metric.key}")
                    .semantics { contentDescription = "${metric.label}波形，单位 ${metric.unit}" }
                    .pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) {
                                val event = awaitPointerEvent(PointerEventPass.Initial)
                                if (event.type == PointerEventType.Exit) latestExit()
                                else if (event.type == PointerEventType.Move || event.type == PointerEventType.Enter) event.changes.firstOrNull()?.let {
                                    if (it.type == PointerType.Mouse) latestPick(it.position.x / size.width, false)
                                }
                            }
                        }
                    }
                    .pointerInput(Unit) { detectTapGestures { latestPick(it.x / size.width, true) } }
                    .pointerInput(Unit) { detectHorizontalDragGestures { change, _ -> latestPick(change.position.x / size.width, true) } }
                ) {
                    axis.ticks.forEach { value ->
                        val y = size.height * (1 - axis.fraction(value))
                        drawLine(grid, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
                    }
                    val duration = if (data.size > 1) data.last().timestamp - data.first().timestamp else 0L
                    val intervals = if (duration < 3000) 1 else if (size.width < 360.dp.toPx()) 2 else 3
                    repeat(intervals + 1) { column ->
                        val x = size.width * column / intervals
                        drawLine(grid, Offset(x, 0f), Offset(x, size.height), strokeWidth = 1f)
                    }
                    if (data.isNotEmpty()) {
                        fun point(snapshot: PowerSnapshot) = Offset(size.width * chartTimeFraction(snapshot.timestamp, data.first().timestamp, data.last().timestamp), size.height * (1 - axis.fraction(metric.value(snapshot))))
                        val path = Path()
                        data.forEachIndexed { index, snapshot ->
                            val position = point(snapshot)
                            if (index == 0) path.moveTo(position.x, position.y) else path.lineTo(position.x, position.y)
                        }
                        drawPath(path, metric.color, style = Stroke(width = 2.dp.toPx()))
                        val marked = selected ?: data.last()
                        val position = point(marked)
                        if (selected != null) drawLine(cursor, Offset(position.x, 0f), Offset(position.x, size.height), strokeWidth = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())))
                        drawCircle(surface, 4.dp.toPx(), position)
                        drawCircle(metric.color, 3.dp.toPx(), position)
                    }
                }
                if (data.isEmpty()) Text("暂无采样", Modifier.align(Alignment.Center), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
