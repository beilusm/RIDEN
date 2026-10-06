package io.github.beilusm.ridenps.ui

import io.github.beilusm.ridenps.core.PowerSnapshot
import kotlin.test.*

class ChartDataTest {
    @Test fun timestampSpacingAndSelectionRespectMissingSamples() {
        val data = listOf(1000L, 1150L, 4000L).map { PowerSnapshot(timestamp = it) }
        assertEquals(0.05f, chartTimeFraction(1150, 1000, 4000), 0.00001f)
        assertEquals(1150L, nearestChartSample(data, 0.05f)?.timestamp)
        assertEquals(4000L, nearestChartSample(data, 0.9f)?.timestamp)
        assertEquals(1000L, nearestChartSample(data, -1f)?.timestamp)
        assertEquals(4000L, nearestChartSample(data, 2f)?.timestamp)
        assertNull(nearestChartSample(emptyList(), 0.5f))
    }
    @Test fun axesCoverZeroConstantAndNegativeValues() {
        for (values in listOf(emptyList(), listOf(0.0), listOf(60.0, 60.01), listOf(-0.001, 0.001), listOf(1.5, 6.1))) {
            for (fromZero in listOf(false, true)) {
                val axis = chartAxis(values, fromZero, 0.001)
                assertTrue(axis.maximum > axis.minimum)
                assertTrue(axis.step > 0)
                assertTrue(axis.ticks.size in 2..8)
                values.forEach { assertTrue(it >= axis.minimum && it <= axis.maximum) }
                if (fromZero) assertTrue(axis.minimum <= 0 && axis.maximum >= 0)
            }
        }
        val zoomed = chartAxis(listOf(60.0, 60.01), false, 0.01)
        assertTrue(zoomed.minimum > 59.0)
        assertTrue(zoomed.maximum < 61.0)
    }
    @Test fun displayPreservesHighPrecisionAndAvoidsNegativeZero() {
        assertEquals("6.1000", number(6.1, 4))
        assertEquals("0.0001", number(0.0001, 4))
        assertEquals("0.000", number(-0.00001, 3))
        assertEquals("12.10", number(12.1, 2))
    }
}
