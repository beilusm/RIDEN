package io.github.beilusm.ridenps

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.window.WindowDraggableArea
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DragIndicator
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.*
import io.github.beilusm.ridenps.core.PowerController
import io.github.beilusm.ridenps.ui.*
import kotlinx.coroutines.launch

fun main(args: Array<String>) = application {
    val controller = remember { PowerController(DesktopServices()) }
    val scope = rememberCoroutineScope()
    val state by controller.state.collectAsState()
    var floating by remember { mutableStateOf(false) }
    var visible by remember { mutableStateOf(true) }
    var hudSettings by remember { mutableStateOf(HudSettings()) }
    val hudWindow = rememberWindowState(width = 460.dp, height = 280.dp)
    val close: () -> Unit = { scope.launch { try { controller.close() } finally { exitApplication() } }; Unit }
    LaunchedEffect(Unit) {
        if ("--demo" in args) {
            controller.setAutoConnect(false)
            controller.connect(io.github.beilusm.ridenps.core.SerialDevice("demo", "Demo"), io.github.beilusm.ridenps.core.SerialConfig())
        }
    }
    Window(onCloseRequest = close, title = "RIDEN", visible = visible, state = rememberWindowState(width = 1120.dp, height = 820.dp)) {
        RidenTheme { RidenApp(controller, onFloating = { floating = true; visible = false }, desktop = true) }
    }
    if (floating) Window(
        onCloseRequest = { floating = false; visible = true }, title = "RIDEN · Monitor", alwaysOnTop = true,
        undecorated = true, transparent = true, resizable = !hudSettings.locked, state = hudWindow
    ) {
        val density = LocalDensity.current.density
        LaunchedEffect(Unit) { window.minimumSize = java.awt.Dimension(300, 180) }
        Box(Modifier.fillMaxSize()) {
            FloatingMonitor(state, hudSettings, { hudSettings = it }, { floating = false; visible = true }, header = { content ->
                if (hudSettings.locked) content() else WindowDraggableArea { content() }
            })
            if (!hudSettings.locked) Icon(Icons.Default.DragIndicator, "调整大小", modifier = Modifier.align(Alignment.BottomEnd).size(20.dp).pointerInput(Unit) {
                detectDragGestures { change, delta ->
                    change.consume()
                    hudWindow.size = DpSize((hudWindow.size.width + (delta.x / density).dp).coerceAtLeast(300.dp), (hudWindow.size.height + (delta.y / density).dp).coerceAtLeast(180.dp))
                }
            }, tint = androidx.compose.ui.graphics.Color.Gray)
        }
    }
}
