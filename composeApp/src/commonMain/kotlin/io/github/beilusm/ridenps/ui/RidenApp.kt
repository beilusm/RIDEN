package io.github.beilusm.ridenps.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import io.github.beilusm.ridenps.core.*
import org.jetbrains.compose.resources.painterResource
import riden.composeapp.generated.resources.Res
import riden.composeapp.generated.resources.riden
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ToolButton(icon: ImageVector, label: String, enabled: Boolean = true, onClick: () -> Unit) {
    TooltipBox(positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(), tooltip = { PlainTooltip { Text(label) } }, state = rememberTooltipState()) {
        IconButton(onClick, enabled = enabled) { Icon(icon, contentDescription = label) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RidenApp(controller: PowerController, onFloating: (() -> Unit)? = null, desktop: Boolean = false) {
    val state by controller.state.collectAsState()
    var tab by remember { mutableStateOf(0) }
    var dark by remember { mutableStateOf<Boolean?>(null) }
    val systemDark = isSystemInDarkTheme()
    var edit by remember { mutableStateOf<Int?>(null) }
    var slotEdit by remember { mutableStateOf<Int?>(null) }
    val destinations = listOf("控制台" to Icons.Default.Dashboard, "寄存器" to Icons.Default.TableChart, "连接" to Icons.Default.Usb)
    RidenTheme(dark ?: systemDark) {
        val snackbar = remember { SnackbarHostState() }
        LaunchedEffect(state.message) {
            state.message?.let { snackbar.showSnackbar(it); controller.dismissMessage() }
        }
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val sideNavigation = desktop || maxWidth >= 600.dp
            Scaffold(
            topBar = {
                val title: @Composable () -> Unit = {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Image(painterResource(Res.drawable.riden), "RIDEN", modifier = Modifier.size(32.dp))
                        Text("RIDEN", style = MaterialTheme.typography.titleLarge)
                    }
                }
                val actions: @Composable () -> Unit = {
                    onFloating?.let { ToolButton(Icons.Default.PictureInPicture, "悬浮监控", onClick = it) }
                    ToolButton(if (dark ?: systemDark) Icons.Default.LightMode else Icons.Default.DarkMode, "切换主题") { dark = !(dark ?: systemDark) }
                }
                if (desktop) {
                    Column {
                        Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                            title()
                            Spacer(Modifier.weight(1f))
                            actions()
                        }
                        HorizontalDivider()
                    }
                } else TopAppBar(title = title, actions = { actions() })
            }, snackbarHost = { SnackbarHost(snackbar) },
            bottomBar = {
                if (!sideNavigation) NavigationBar(Modifier.testTag("bottom-navigation")) {
                    destinations.forEachIndexed { index, (name, icon) ->
                        NavigationBarItem(selected = tab == index, onClick = { tab = index }, icon = { Icon(icon, name) }, label = { Text(name) })
                    }
                }
            }
        ) { padding ->
            Row(Modifier.fillMaxSize().padding(padding)) {
                if (sideNavigation) {
                    NavigationRail(Modifier.fillMaxHeight().testTag("side-navigation"), containerColor = MaterialTheme.colorScheme.surfaceContainer) {
                        Spacer(Modifier.height(12.dp))
                        destinations.forEachIndexed { index, (name, icon) ->
                            NavigationRailItem(selected = tab == index, onClick = { tab = index }, icon = { Icon(icon, name) }, label = { Text(name) })
                            Spacer(Modifier.height(8.dp))
                        }
                    }
                    VerticalDivider()
                }
                BoxWithConstraints(Modifier.weight(1f).fillMaxHeight()) {
                    val wide = maxWidth >= 840.dp
                    Column(Modifier.fillMaxSize()) {
                        ConnectionStrip(state)
                        when (tab) {
                            0 -> Dashboard(state, controller, wide, { edit = it }, { slotEdit = it })
                            1 -> RegisterPage(state, controller, { edit = it })
                            2 -> ConnectionPage(state, controller)
                        }
                    }
                }
            }
        }
        }
        edit?.let { address ->
            val definition = state.device.definitions[address]
            ValueDialog(definition.name, listOf(definition), listOf((state.device.registers[address] ?: 0).toDouble() / definition.scale), onDismiss = { edit = null }) {
                controller.write(address, it.single()); edit = null
            }
        }
        slotEdit?.let { slot ->
            val definitions = state.device.definitions.subList(80 + slot * 4, 84 + slot * 4)
            ValueDialog("编辑 M$slot", definitions, definitions.map { (state.device.registers[it.address] ?: 0).toDouble() / it.scale }, onDismiss = { slotEdit = null }) {
                controller.saveSlot(slot, it); slotEdit = null
            }
        }
    }
}

@Composable
private fun ConnectionStrip(state: AppState) {
    val color = when (state.connection) {
        Connection.ONLINE -> MaterialTheme.colorScheme.primary
        Connection.ERROR, Connection.TIMEOUT -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val label = when (state.connection) {
        Connection.ONLINE -> if (state.port == "demo") "演示模式" else "已连接"
        Connection.CONNECTING -> "连接中"
        Connection.TIMEOUT -> "响应超时"
        Connection.ERROR -> "通信异常"
        Connection.OFFLINE -> "未连接"
    }
    Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).padding(horizontal = 20.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(Icons.Default.Circle, null, tint = color, modifier = Modifier.size(8.dp))
        Text(label, style = MaterialTheme.typography.labelLarge, color = color)
        Text(state.port ?: "USB Serial", Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelMedium)
        if (state.device.model != 0) Text("${state.device.capabilities?.name ?: "ID ${state.device.model}"} · FW ${state.device.firmware}", style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
fun MeasurementRow(snapshot: PowerSnapshot, compact: Boolean = false, available: Boolean = true, voltageDigits: Int = 2, currentDigits: Int = 3) {
    val colors = LocalMeasurementColors.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        listOf(Triple("电压", number(snapshot.voltage, voltageDigits), "V"), Triple("电流", number(snapshot.current, currentDigits), "A"), Triple("功率", number(snapshot.power), "W")).forEachIndexed { i, (label, value, unit) ->
            Column(Modifier.weight(1f).padding(vertical = if (compact) 4.dp else 16.dp)) {
                Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                BoxWithConstraints {
                    Text(if (available) value else "--", maxLines = 1, fontFamily = FontFamily.Monospace, style = if (compact || maxWidth < 110.dp) MaterialTheme.typography.titleLarge else MaterialTheme.typography.headlineMedium, color = colors[i])
                }
                Text(unit, style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

@Composable
private fun Dashboard(state: AppState, controller: PowerController, wide: Boolean, onEdit: (Int) -> Unit, onSlotEdit: (Int) -> Unit) {
    if (wide) {
        Row(Modifier.fillMaxSize().padding(20.dp), horizontalArrangement = Arrangement.spacedBy(28.dp)) {
            Column(Modifier.width(330.dp).fillMaxHeight().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                DashboardControls(state, controller, onEdit, onSlotEdit)
            }
            VerticalDivider()
            Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                PowerChart(state.history, onClear = controller::clearHistory, height = 320.dp, voltageDigits = state.device.definitions[10].digits, currentDigits = state.device.definitions[11].digits)
                HorizontalDivider()
                RecordingControls(state, controller)
            }
        }
    } else {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            DashboardControls(state, controller, onEdit, onSlotEdit)
            PowerChart(state.history, onClear = controller::clearHistory, voltageDigits = state.device.definitions[10].digits, currentDigits = state.device.definitions[11].digits)
            HorizontalDivider()
            RecordingControls(state, controller)
        }
    }
}

@Composable
private fun DashboardControls(state: AppState, controller: PowerController, onEdit: (Int) -> Unit, onSlotEdit: (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Text("输出", style = MaterialTheme.typography.titleMedium)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(state.device.mode, style = MaterialTheme.typography.labelLarge)
                Switch(state.device.registers[18] == 1, { controller.setOutput(it) }, enabled = state.port != null && state.connection != Connection.CONNECTING && !state.busy && (state.device.capabilities != null || state.device.registers[18] == 1), modifier = Modifier.semantics { contentDescription = "输出开关" })
            }
        }
        MeasurementRow(state.device.snapshot, available = state.device.capabilities != null, voltageDigits = state.device.definitions[10].digits, currentDigits = state.device.definitions[11].digits)
        if (state.device.model != 0 && state.device.capabilities == null) Text("型号 ${state.device.model} 尚未支持，参数只读", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("输入 ${number(state.device.snapshot.inputVoltage)} V", style = MaterialTheme.typography.bodyMedium)
            Text("温度 ${number(state.device.snapshot.temperature, 1)} °C", style = MaterialTheme.typography.bodyMedium)
            Text("${state.device.capacity} mAh", style = MaterialTheme.typography.bodyMedium)
            Text("${state.device.energy} mWh", style = MaterialTheme.typography.bodyMedium)
            val protection = listOf("保护正常", "OVP", "OCP", "OTP").getOrElse(state.device.snapshot.protection) { "未知保护状态" }
            Text(protection, color = if (state.device.snapshot.protection == 0) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error, style = MaterialTheme.typography.labelLarge)
        }
        HorizontalDivider()
        Text("设定 · M${state.device.activeSlot}", style = MaterialTheme.typography.titleMedium)
        val definitions = listOf(8, 9, 80 + state.device.activeSlot * 4 + 2, 80 + state.device.activeSlot * 4 + 3)
        val chunks = definitions.chunked(2)
        chunks.forEach { addresses ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                addresses.forEach { address ->
                    OutlinedCard(onClick = { onEdit(address) }, enabled = state.port != null && !state.busy && state.device.registers[address] != null && state.device.definitions[address].writable, modifier = Modifier.weight(1f)) {
                        Column(Modifier.padding(14.dp)) {
                            Text(when (address) { 8 -> "电压设定"; 9 -> "电流设定"; else -> if (address % 4 == 2) "OVP" else "OCP" }, style = MaterialTheme.typography.labelMedium)
                            val d = state.device.definitions[address]
                            Text(if (state.device.capabilities == null) "--" else "${number((state.device.registers[address] ?: 0).toDouble() / d.scale, d.digits)} ${d.unit}", style = MaterialTheme.typography.titleLarge, maxLines = 1)
                        }
                    }
                }
            }
        }
        HorizontalDivider()
        Presets(state, controller, onSlotEdit)
    }
}

@Composable
private fun RecordingControls(state: AppState, controller: PowerController) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(if (state.recording) Icons.Default.FiberManualRecord else Icons.Default.SaveAlt, null, tint = if (state.recording) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            Column(Modifier.weight(1f)) {
                Text("CSV 录制", style = MaterialTheme.typography.titleSmall)
                Text("${state.recorded} 个采样点", style = MaterialTheme.typography.bodySmall)
            }
            FilledTonalButton(onClick = { controller.toggleRecording() }, enabled = state.recordingOpen || (state.port != null && state.device.capabilities != null)) {
                Icon(if (state.recordingOpen) Icons.Default.Stop else Icons.Default.FiberManualRecord, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp)); Text(if (state.recordingOpen) "停止" else "录制")
            }
        }
        state.recordingPath?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun Presets(state: AppState, controller: PowerController, onEdit: (Int) -> Unit) {
    var selected by remember(state.device.activeSlot) { mutableStateOf(state.device.activeSlot.coerceIn(1, 9)) }
    var expanded by remember { mutableStateOf(false) }
    val base = 80 + selected * 4
    val known = state.device.capabilities != null && (base until base + 4).all { state.device.registers[it] != null }
    Column(Modifier.fillMaxWidth().testTag("preset-controls"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("预设", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            Box {
                OutlinedButton(onClick = { expanded = true }, modifier = Modifier.semantics { contentDescription = "选择预设" }) {
                    Text("M$selected")
                    Icon(Icons.Default.ArrowDropDown, null, Modifier.size(20.dp))
                }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    (1..9).forEach { slot ->
                        DropdownMenuItem(text = { Text("M$slot") }, onClick = { selected = slot; expanded = false },
                            trailingIcon = { if (state.device.activeSlot == slot) Icon(Icons.Default.Check, "当前预设") })
                    }
                }
            }
        }
        (0..3).toList().chunked(2).forEach { indices ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                indices.forEach { i ->
                    val d = state.device.definitions[base + i]
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(listOf("电压", "电流", "OVP", "OCP")[i], style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text("${if (known) state.device.registers[base + i]?.let { number(it.toDouble() / d.scale, d.digits) } ?: "--" else "--"} ${d.unit}", style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(if (state.device.activeSlot == selected) "当前预设" else "当前 M${state.device.activeSlot}", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            ToolButton(Icons.Default.Edit, "编辑 M$selected", state.port != null && !state.busy && known) { onEdit(selected) }
            FilledTonalButton(onClick = { controller.quickSwitch(selected) }, enabled = state.port != null && !state.busy && state.device.capabilities != null) {
                Icon(Icons.Default.FileDownload, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("载入")
            }
        }
    }
}

@Composable
private fun RegisterPage(state: AppState, controller: PowerController, onEdit: (Int) -> Unit) {
    var query by remember { mutableStateOf("") }
    var writableOnly by remember { mutableStateOf(false) }
    var autoRefresh by remember { mutableStateOf(true) }
    var displayed by remember(state.device.capabilities) { mutableStateOf(state.device.registers) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(autoRefresh, state.device.registers) { if (autoRefresh) displayed = state.device.registers }
    LaunchedEffect(autoRefresh, state.port) {
        while (autoRefresh && state.port != null) {
            controller.refreshRegisters(automatic = true).join()
            delay(500)
        }
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(query, { query = it }, label = { Text("搜索寄存器") }, leadingIcon = { Icon(Icons.Default.Search, null) }, modifier = Modifier.weight(1f), singleLine = true)
            ToolButton(if (autoRefresh) Icons.Default.Pause else Icons.Default.Autorenew, if (autoRefresh) "暂停寄存器刷新" else "自动刷新寄存器") { autoRefresh = !autoRefresh }
            ToolButton(Icons.Default.Refresh, "读取全部", state.port != null && !state.busy) { scope.launch { controller.refreshRegisters().join(); displayed = controller.state.value.device.registers } }
            ToolButton(Icons.Default.Download, "导出寄存器 CSV") { controller.exportRegisters() }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(writableOnly, { writableOnly = it }); Text("仅可写", style = MaterialTheme.typography.bodyMedium)
        }
        LazyColumn(Modifier.weight(1f)) {
            items(state.device.definitions.filter { (!writableOnly || it.writable) && (query.isBlank() || it.name.contains(query, true) || it.address.toString().contains(query)) }, key = { it.address }) { d ->
                Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(d.address.toString().padStart(3, '0'), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyMedium)
                    Column(Modifier.weight(1f)) {
                        Text(d.name, style = MaterialTheme.typography.bodyMedium)
                        Text("${if (d.source == "unknown") "?" else if (d.writable) "R/W" else "R/O"} · ${d.source}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    val raw = displayed[d.address]
                    Column(horizontalAlignment = Alignment.End) {
                        Text(raw?.let { "${number(it.toDouble() / d.scale, d.digits)} ${d.unit}" } ?: "--", style = MaterialTheme.typography.bodyMedium)
                        Text(raw?.let { "$it · 0x${it.toString(16).padStart(4, '0')}" } ?: "--", style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    ToolButton(Icons.Default.Edit, "写入 HR${d.address}", d.writable && raw != null && state.port != null && !state.busy) { onEdit(d.address) }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectionPage(state: AppState, controller: PowerController) {
    var selected by remember { mutableStateOf<SerialDevice?>(null) }
    var expanded by remember { mutableStateOf(false) }
    var baud by remember { mutableStateOf(state.config.baud.toString()) }
    var address by remember { mutableStateOf(state.config.address.toString()) }
    val ports = state.devices + SerialDevice("demo", "演示设备")
    LaunchedEffect(state.devices, state.port) {
        if (state.port != null) selected = ports.firstOrNull { it.id == state.port }
        else if (selected == null) selected = state.devices.firstOrNull { it.preferred } ?: state.devices.firstOrNull()
    }
    LaunchedEffect(state.config) { baud = state.config.baud.toString(); address = state.config.address.toString() }
    val connected = state.port != null
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("串口连接", style = MaterialTheme.typography.titleMedium)
        ExposedDropdownMenuBox(expanded, { if (!connected) expanded = it }) {
            OutlinedTextField(selected?.label ?: "选择串口", {}, readOnly = true, label = { Text("设备") }, trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) }, modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable), enabled = !connected)
            ExposedDropdownMenu(expanded, { expanded = false }) {
                ports.forEach { device -> DropdownMenuItem(text = { Text(device.label) }, onClick = { selected = device; expanded = false }) }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(baud, { baud = it }, label = { Text("波特率") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true, enabled = !connected, modifier = Modifier.weight(1f))
            OutlinedTextField(address, { address = it }, label = { Text("地址 · 1–247") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true, enabled = !connected, modifier = Modifier.weight(1f))
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Text("自动连接 / 重连")
            Switch(state.autoConnect, controller::setAutoConnect)
        }
        Button(onClick = {
            if (connected) controller.disconnect() else selected?.let { controller.connect(it, SerialConfig(baud.toInt(), address.toInt())) }
        }, enabled = state.connection != Connection.CONNECTING && (connected || (selected != null && baud.toIntOrNull() in listOf(9600, 19200, 38400, 57600, 115200, 230400, 460800) && address.toIntOrNull() in 1..247))) {
            Icon(if (connected) Icons.Default.LinkOff else Icons.Default.Link, null)
            Spacer(Modifier.width(8.dp)); Text(if (connected) "断开" else "连接")
        }
        HorizontalDivider()
        if (state.device.model != 0) {
            Text("${state.device.capabilities?.name ?: "未识别型号"} · ID ${state.device.model}", style = MaterialTheme.typography.titleMedium)
            state.device.capabilities?.let { capability ->
                Text("额定 ${number(capability.ratedVoltage)} V / ${number(capability.ratedCurrent)} A", style = MaterialTheme.typography.bodyMedium)
                Text("设定上限 ${number(capability.maxVoltage)} V / ${number(capability.maxCurrent)} A", style = MaterialTheme.typography.bodyMedium)
                Text("保护上限 ${number(capability.maxOvp)} V / ${number(capability.maxOcp)} A", style = MaterialTheme.typography.bodyMedium)
            }
            HorizontalDivider()
        }
        Text("调度器", style = MaterialTheme.typography.titleMedium)
        Text("队列 ${state.scheduler.queued} · 完成 ${state.scheduler.completed} · 失败 ${state.scheduler.failed}", style = MaterialTheme.typography.bodyMedium)
        Text("${state.config.baud} · 8N1 · Modbus RTU · ${state.config.address}", style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun ValueDialog(title: String, definitions: List<RegisterDefinition>, initial: List<Double>, onDismiss: () -> Unit, onSave: (List<Double>) -> Unit) {
    var values by remember(title, definitions) { mutableStateOf(initial.mapIndexed { i, value -> number(value, definitions[i].digits) }) }
    val valid = values.mapIndexed { i, text -> text.toDoubleOrNull()?.let { runCatching { definitions[i].encode(it) }.isSuccess } ?: false }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(title) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            definitions.forEachIndexed { i, definition ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ToolButton(Icons.Default.Remove, "减少 ${definition.name}") {
                        val v = ((values[i].toDoubleOrNull() ?: definition.min) - 1.0 / definition.scale).coerceIn(definition.min, definition.max)
                        values = values.toMutableList().also { it[i] = number(v, definition.digits) }
                    }
                    OutlinedTextField(values[i], { v -> values = values.toMutableList().also { it[i] = v } }, modifier = Modifier.weight(1f), label = { Text(definition.name) }, suffix = { Text(definition.unit) }, supportingText = { Text("${definition.min}–${definition.max}") }, isError = !valid[i], keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), singleLine = true)
                    ToolButton(Icons.Default.Add, "增加 ${definition.name}") {
                        val v = ((values[i].toDoubleOrNull() ?: definition.min) + 1.0 / definition.scale).coerceIn(definition.min, definition.max)
                        values = values.toMutableList().also { it[i] = number(v, definition.digits) }
                    }
                }
            }
        }
    }, confirmButton = { TextButton(onClick = { onSave(values.map { it.toDouble() }) }, enabled = valid.all { it }) { Text("写入") } }, dismissButton = { TextButton(onDismiss) { Text("取消") } })
}
