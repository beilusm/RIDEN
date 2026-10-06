package io.github.beilusm.ridenps

import androidx.compose.ui.graphics.asSkiaBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.github.beilusm.ridenps.core.*
import io.github.beilusm.ridenps.ui.RidenApp
import io.github.beilusm.ridenps.ui.FloatingMonitor
import io.github.beilusm.ridenps.ui.HudSettings
import io.github.beilusm.ridenps.ui.PowerChart
import io.github.beilusm.ridenps.ui.RidenTheme
import io.github.beilusm.ridenps.ui.number
import androidx.compose.runtime.*
import kotlinx.coroutines.runBlocking
import org.jetbrains.skia.EncodedImageFormat
import org.junit.Test
import java.io.File

@OptIn(ExperimentalTestApi::class)
class AppUiTest {
    private fun chartSamples() = List(300) { index ->
        val voltage = when (index) { in 0..39, in 230..259, in 280..284 -> 0.0; in 40..109 -> 12.0; in 110..189 -> 10.0; else -> 60.0 }
        val current = if (voltage == 0.0) 0.0 else 1.3 + kotlin.math.sin(index / 12.0) * 0.08
        PowerSnapshot(timestamp = 1700000000000L + index * 300L + if (index >= 120) 5000L else 0L, voltage = voltage, current = current)
    }

    @Test fun chartMouseSelectionFreezesReadingsAndResumeUsesLiveData() = runSkikoComposeUiTest(size = Size(1000f, 820f)) {
        val samples = chartSamples()
        lateinit var replace: (List<PowerSnapshot>) -> Unit
        setContent {
            var data by remember { mutableStateOf(samples) }
            replace = { data = it }
            RidenTheme(dark = false) {
                Surface(Modifier.fillMaxSize()) {
                    Column(Modifier.padding(20.dp)) { Text("RIDEN"); PowerChart(data, { data = emptyList() }, height = 420.dp) }
                }
            }
        }
        onNodeWithTag("chart-readout-voltage").assertTextEquals("60.00 V")
        onNodeWithTag("plot-voltage").performMouseInput { moveTo(Offset(width * 0.1f, height / 2f)) }
        onNodeWithTag("chart-readout-voltage").assertTextEquals("10.00 V")
        onNodeWithTag("chart-readout-current").assertTextEquals("${number(samples[165].current, 3)} A")
        onNodeWithContentDescription("暂停波形").assertExists()
        onNodeWithTag("plot-voltage").performTouchInput { click(Offset(width * 0.1f, height / 2f)) }
        onNodeWithContentDescription("继续波形").assertExists()
        runOnIdle { replace(emptyList()) }
        onNodeWithTag("chart-readout-voltage").assertTextEquals("10.00 V")
        onNodeWithText("功率").performClick()
        onNodeWithTag("chart-readout-power").assertTextEquals("${number(samples[165].power)} W")
        screenshot("chart-desktop-selected")
        onNodeWithContentDescription("返回实时").performClick()
        onNodeWithTag("chart-readout-voltage").assertTextEquals("-- V")
    }

    @Test fun chartTouchDragKeepsAllMetricsAlignedOnCompactScreen() = runSkikoComposeUiTest(size = Size(360f, 900f)) {
        val samples = chartSamples()
        setContent {
            RidenTheme(dark = false) {
                Surface(Modifier.fillMaxSize()) {
                    Column(Modifier.padding(20.dp)) { Text("RIDEN"); PowerChart(samples, {}, height = 320.dp) }
                }
            }
        }
        onNodeWithText("功率").performClick()
        onNodeWithTag("plot-voltage").performTouchInput { click(Offset(width * 0.1f, height / 2f)) }
        onNodeWithTag("chart-readout-voltage").assertTextEquals("10.00 V")
        onNodeWithTag("plot-current").performTouchInput {
            swipe(Offset(width * 0.1f, height / 2f), Offset(width * 0.95f, height / 2f), durationMillis = 500)
        }
        onNodeWithTag("chart-readout-voltage").assertTextEquals("60.00 V")
        onNodeWithText("选点").assertExists()
        onNodeWithContentDescription("继续波形").assertExists()
        onNodeWithContentDescription("从零显示").performClick()
        onNodeWithContentDescription("自动量程").assertExists()
        screenshot("chart-mobile-selected")
    }

    private fun controller(model: Int = 6006): PowerController = PowerController(object : PlatformServices {
        override val transport = object : SerialTransport by DemoTransport(model) {
            override suspend fun devices() = listOf(SerialDevice("test", "Test"))
        }
        override suspend fun startRecording(): RecordingSink? = null
        override suspend fun exportText(name: String, text: String): String? = null
    }).also {
        it.setAutoConnect(false)
        it.connect(SerialDevice("test", "Test"), SerialConfig())
    }
    @Test fun highCurrentModelUsesItsLimitsAndPrecision() = runSkikoComposeUiTest(size = Size(1120f, 820f)) {
        val controller = controller(60121)
        try {
            setContent { RidenApp(controller, desktop = true) }
            waitUntil(timeoutMillis = 10000) { controller.state.value.connection == Connection.ONLINE }
            onNodeWithText("电流设定").performClick()
            onNodeWithText("0.0–12.1").assertExists()
            onNode(hasText("Set current") and hasSetTextAction()).performTextReplacement("12.20")
            onNodeWithText("写入").assertIsNotEnabled()
            onNode(hasText("Set current") and hasSetTextAction()).performTextReplacement("12.101")
            onNodeWithText("写入").assertIsNotEnabled()
            onNode(hasText("Set current") and hasSetTextAction()).performTextReplacement("12.10")
            onNodeWithText("写入").assertIsEnabled().performClick()
            waitUntil(timeoutMillis = 5000) { controller.state.value.device.registers[9] == 1210 && !controller.state.value.busy }
            onNodeWithContentDescription("编辑 M1").performScrollTo().performClick()
            onNodeWithText("0.0–12.2").assertExists()
            onNodeWithText("取消").performClick()
            onNodeWithText("连接").performClick()
            onNodeWithText("RD6012 · ID 60121").assertExists()
            screenshot("desktop-capabilities")
        } finally { runBlocking { controller.close() } }
    }
    @Test fun desktopWorkflow() = runSkikoComposeUiTest(size = Size(1120f, 820f)) {
        val controller = controller()
        try {
            setContent { RidenApp(controller, desktop = true) }
            waitUntil(timeoutMillis = 10000) { controller.state.value.connection == Connection.ONLINE }
            onNodeWithText("RIDEN").assertExists()
            onNodeWithTag("side-navigation").assertExists()
            onNodeWithTag("bottom-navigation").assertDoesNotExist()
            onNodeWithContentDescription("输出开关").performClick()
            waitUntil(timeoutMillis = 5000) { controller.state.value.device.snapshot.outputEnabled }
            onNodeWithTag("side-navigation").onChildren().filter(hasText("预设")).assertCountEquals(0)
            onNodeWithContentDescription("选择预设").performScrollTo().performClick()
            onNodeWithText("M2").performClick()
            onNodeWithText("载入").performScrollTo().performClick()
            waitUntil(timeoutMillis = 5000) { controller.state.value.device.activeSlot == 2 && !controller.state.value.busy }
            onNodeWithContentDescription("编辑 M2").performScrollTo().performClick()
            onNodeWithText("编辑 M2").assertExists()
            onNodeWithText("取消").performClick()
            onNodeWithText("寄存器").performClick()
            onNodeWithContentDescription("暂停寄存器刷新").performClick()
            waitUntil(timeoutMillis = 5000) { !controller.state.value.busy }
            onNodeWithText("搜索寄存器").performTextInput("Set voltage")
            onAllNodesWithText("Set voltage").assertCountEquals(2)
            onNodeWithContentDescription("写入 HR8").performClick()
            onNodeWithText("写入").assertExists()
            onNodeWithText("取消").performClick()
            onNodeWithText("控制台").performClick()
            screenshot("desktop")
            onNodeWithContentDescription("切换主题").performClick()
            screenshot("desktop-light")
        } finally { runBlocking { controller.close() } }
    }
    @Test fun compactDashboard() = runSkikoComposeUiTest(size = Size(360f, 800f)) {
        val controller = controller()
        try {
            setContent { RidenApp(controller) }
            onNodeWithTag("bottom-navigation").assertExists()
            onNodeWithTag("side-navigation").assertDoesNotExist()
            waitUntil(timeoutMillis = 10000) { controller.state.value.history.size >= 2 }
            onNodeWithContentDescription("输出开关").performClick()
            waitUntil(timeoutMillis = 5000) { controller.state.value.device.snapshot.outputEnabled }
            onNodeWithText("实时波形").assertExists()
            screenshot("compact")
            onNodeWithContentDescription("选择预设").performScrollTo().performClick()
            onNodeWithText("M9").performClick()
            onNodeWithText("载入").performScrollTo().performClick()
            waitUntil(timeoutMillis = 5000) { controller.state.value.device.activeSlot == 9 && !controller.state.value.busy }
            screenshot("compact-presets")
            onNodeWithContentDescription("输出开关").performScrollTo()
            onNodeWithContentDescription("切换主题").performClick()
            screenshot("compact-light")
        } finally { runBlocking { controller.close() } }
    }
    @Test fun narrowDesktopKeepsSideNavigation() = runSkikoComposeUiTest(size = Size(680f, 820f)) {
        val controller = controller()
        try {
            setContent { RidenApp(controller, desktop = true) }
            waitUntil(timeoutMillis = 10000) { controller.state.value.connection == Connection.ONLINE }
            onNodeWithTag("side-navigation").assertExists()
            onNodeWithTag("bottom-navigation").assertDoesNotExist()
            onNodeWithText("连接").performClick()
            onNodeWithText("控制台").performClick()
            screenshot("desktop-narrow")
        } finally { runBlocking { controller.close() } }
    }
    @Test fun landscapeUsesSideNavigation() = runSkikoComposeUiTest(size = Size(960f, 540f)) {
        val controller = controller()
        try {
            setContent { RidenApp(controller) }
            onNodeWithTag("side-navigation").assertExists()
            onNodeWithTag("bottom-navigation").assertDoesNotExist()
            screenshot("landscape")
        } finally { runBlocking { controller.close() } }
    }
    private fun ComposeUiTest.screenshot(name: String) {
        waitForIdle()
        val bitmap = onNode(isRoot() and hasAnyDescendant(hasText("RIDEN"))).captureToImage().asSkiaBitmap()
        File("build/screenshots").mkdirs()
        File("build/screenshots/$name.png").writeBytes(requireNotNull(org.jetbrains.skia.Image.makeFromBitmap(bitmap).encodeToData(EncodedImageFormat.PNG)).bytes)
    }
    @Test fun floatingSettingsAndRestore() = runSkikoComposeUiTest(size = Size(460f, 280f)) {
        var settings = HudSettings()
        var restored = false
        setContent {
            var config by remember { mutableStateOf(settings) }
            FloatingMonitor(AppState(), config, { settings = it; config = it }, { restored = true })
        }
        onNodeWithContentDescription("锁定悬浮窗").performClick()
        kotlin.test.assertTrue(settings.locked)
        onNodeWithContentDescription("悬浮窗设置").performClick()
        onNodeWithText("悬浮窗设置").assertExists()
        onNodeWithText("应用").performClick()
        screenshot("floating")
        onNodeWithContentDescription("恢复主窗口").performClick()
        kotlin.test.assertTrue(restored)
    }
}
