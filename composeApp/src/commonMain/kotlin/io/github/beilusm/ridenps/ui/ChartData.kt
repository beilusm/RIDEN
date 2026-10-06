package io.github.beilusm.ridenps.ui

import io.github.beilusm.ridenps.core.PowerSnapshot
import kotlin.math.*

data class ChartAxis(val minimum: Double, val maximum: Double, val step: Double) {
    val ticks: List<Double> get() = (0..((maximum - minimum) / step).roundToInt()).map { maximum - it * step }
    fun fraction(value: Double) = ((value - minimum) / (maximum - minimum)).toFloat().coerceIn(0f, 1f)
}

fun chartAxis(values: List<Double>, fromZero: Boolean, resolution: Double): ChartAxis {
    val finite = values.filter { it.isFinite() }
    val low = finite.minOrNull() ?: 0.0
    val high = finite.maxOrNull() ?: 0.0
    val padding = max((high - low) * 0.08, max(abs(high) * 0.005, resolution * 2))
    val bottom = if (fromZero) min(0.0, low - if (low < 0) padding else 0.0) else if (low >= 0) max(0.0, low - padding) else low - padding
    val top = if (fromZero) max(high + padding, resolution * 4) else high + padding
    val rawStep = (top - bottom) / 4
    val magnitude = 10.0.pow(floor(log10(rawStep)))
    val ratio = rawStep / magnitude
    val step = magnitude * when { ratio <= 1 -> 1; ratio <= 2 -> 2; ratio <= 5 -> 5; else -> 10 }
    return ChartAxis(floor(bottom / step) * step, ceil(top / step) * step, step)
}

fun chartTimeFraction(timestamp: Long, first: Long, last: Long): Float =
    if (last <= first) 1f else ((timestamp - first).toDouble() / (last - first)).toFloat().coerceIn(0f, 1f)

fun nearestChartSample(data: List<PowerSnapshot>, fraction: Float): PowerSnapshot? {
    if (data.isEmpty()) return null
    val timestamp = data.first().timestamp + ((data.last().timestamp - data.first().timestamp) * fraction.coerceIn(0f, 1f)).toLong()
    return data.minByOrNull { abs(it.timestamp - timestamp) }
}
