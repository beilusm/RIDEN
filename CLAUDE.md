# CLAUDE.md — RIDEN Power Supply 项目指南

## 项目概要

Flutter 桌面应用，通过 CH340 USB-Serial (Modbus RTU, 115200-8-N-1, addr=0x01) 与 RIDEN 数控电源通信。实时显示 V/A/W 波形、设定参数、保护状态、预设管理。

## 架构：双 Isolate

```
UI Isolate                        Modbus Worker Isolate
──────────                        ───────────────────
PowerSupplyProvider               PeriodicTaskSource (Timer×2)
  ChangeNotifier                    │
SerialModbusService (proxy)       ModbusScheduler
  SendPort ←────→ ReceivePort     ModbusExecutor (_accumulateRead)
                                  SerialPort (CH340 FFI)
```

**铁律：UI isolate 永远不直接访问 SerialPort。** 所有串口 I/O 在 worker isolate 执行。UI 只通过 `SendPort`/`ReceivePort` 发命令、收结果。

## 通信层文件（不要随意改）

| 文件 | 职责 | 修改风险 |
|------|------|---------|
| `modbus_task.dart` | Task 模型：priority/aging/dedup/state/Completer | 低 — 稳定 |
| `modbus_scheduler.dart` | 调度器：enqueue/sort/expire/group pause | 低 — 稳定 |
| `modbus_worker.dart` | Worker isolate + 核心逻辑 | **中** — 含通信协议和 IO |
| `serial_modbus_service.dart` | UI侧 proxy，数据合并缓存 | **中** — 含 merge 逻辑 |
| `modbus_service.dart` | 抽象接口 | 低 — 仅定义 |

## 关键设计决策

### 250ms 累积 deadline
设备 Modbus 响应有两个延迟峰：10-80ms（快）和 120-180ms（慢）。
`_accumulateRead` 用 250ms 总 budget，首次 read timeout=80ms，后续 30ms，循环直到收满或超时。这样两个峰都能覆盖。

### FAST 150ms interval
实验验证：200ms 太保守（data_rate 相同），120ms 出现 timeout。
150ms 是最佳平衡 — 不丢数据，不产生 dedup，不超过设备能力。

### drain 仅异常路径
`_drainPort(80ms)` 只在 `_accumulateRead` 超时时调用，排空迟到的残留字节。正常路径永远不触发。

### dedup 策略
- FAST: `dedupKey="fast"` — 新 pending 取消旧 pending，不碰 running
- SLOT: `dedupKey="slot_M0"`..."slot_M9" — 每个 slot 独立 dedup
- Write: 无 dedup，每次唯一 ID

### Task priority
`write(0) > userRead(5) > fastPoll(15) > slowPoll(30) > background(50)`
Aging: `effectivePriority = base - 0.0002 × waitMs`

### PowerSupplyData merge
FAST poll 和 SLOW poll 都发送 `PowerSupplyData` 到 UI。
- FAST 包含所有测量字段 → `isFast = snapshot.setVoltage > 0` → 全量更新
- SLOW 只含 slot 数据 → 仅合并 `memorySlots`

### HR19 quickSwitch 是 Memory Slot 唯一真实切换入口（Phase A.5 硬件验证）
设备固件用 HR19 (0x0013) 作为硬件 Memory Slot quick switch 入口：写 HR19=Mx 后设备固件自动加载对应 Mx 保存参数到当前工作寄存器（HR8 Vset / HR9 Iset）。Phase A.5 真机实测：HR19 0→1 触发 HR8 4.20V→5.00V + HR9 6.100A→5.000A，与 M1 preset 一致。Active OVP/OCP 由当前 slot 决定（地址 = `HR[80 + activeSlot*4 + 2/3]`，M0=82/83, M1=86/87, M2=90/91, …）；**HR82/HR83 永远是 M0 slot storage，不是顶层 active OVP/OCP**（Phase B.2 datasheet 确认，详见 `register_conflicts.dart` address 82/83 [RESOLVED]）。

**M0 = 上电默认数据组，不可通过修改 0x13 寄存器生效**（Phase B.1 真机回归确认 + 用户决策）：设备上电时 HR19=0，工作寄存器使用 M0 preset。但写 HR19=0 不触发设备 reload M0 preset 到 HR8/HR9 — HR19=0 被设备理解为"无新选择 / 停留"。因此 UI 必须不允许用户主动切回 M0；preset 选择 dialog 只显示 M1..M9，不显示 M0 选项。设备 HR8/HR9 在切到 Mx 再"回 M0"后保持切换前的最后值，并非 M0 preset。

旧 `loadMemorySlot()` 路径是软件模拟（读保存区 + 4 次写工作寄存器），现在标 `@Deprecated` 但实现保留。**UI 必须走 `quickSwitch()`**：write HR19 → 600ms 等待 → readRawRegisters HR0..HR120 → UI 用设备真实状态。

## 运行

```bash
fvm flutter pub get
fvm flutter run -d linux    # 默认连接 /dev/ttyUSB0
```

Mock 模式（无硬件）：`main.dart` 中注入 `MockModbusService`。

## 调试开关

```dart
// modbus_scheduler.dart:12 — 开启调度日志（唯一保留的 verbose switch）
static const _verboseLog = false; // set true for per-task debug logs

// 生产统计 (每2秒)
[SCHED_STAT] complete=12 data_rate=6.0/s isolate=alive
```

## 不要做的事

### 通信层 / 业务逻辑
- 不要在 UI isolate 调用 SerialPort FFI
- 不要把 `_accumulateRead` deadline 改小（<200ms 会丢慢响应）
- 不要把 FAST interval 改到 <120ms（会增加 timeout）
- 不要删除 drain（需要它做异常恢复）
- 不要修改 dedup key 格式（会导致 slot 扫描互相覆盖）
- 不要移除 `_current` merge 缓存（SLOW poll 会覆盖 FAST 数据）
- 不重构架构，不改 Dashboard / RegisterPage 功能，不改通信协议，不改 Scheduler 算法，不改 FAST 150ms / SLOW 1000ms / `_accumulateRead` 250ms 三个数值
- 不修改 `modbus_task.dart` / `modbus_scheduler.dart`；`modbus_worker.dart` 仅允许稳定性修复 (P0/P1)
- 不修改 `RegisterDefinition` / `register_conflicts`
- 不删除硬编码寄存器、不改 FAST 为动态读取
- 不根据变量名猜协议

### 发布工程（Phase 3 已实施 — 见 `docs/SESSION_HANDOFF.md` Phase 3）
- **不引入 `linuxdeploy` / `linuxdeploy-plugin-gtk`** — plugin-gtk 的 AppRun hook 强制 `GDK_BACKEND=x11` 和 `GTK_THEME`，会在 HiDPI 显示器上破坏 2x 缩放（GL frame size 从 2712x1616 退到 1346x1616）
- **不在 `AppRun` 设 `GDK_BACKEND` / `GTK_THEME` / `GTK_PATH` 等环境变量** — AppRun 仅 9 行，故意不设 GTK 环境变量保留用户系统 HiDPI 主题 / font-scaling-factor
- **不改 `packaging/config/env.sh` 的 `APP_ID` / `APP_VERSION`** — 必须与 `linux/CMakeLists.txt:10` (`APPLICATION_ID`) 和 `pubspec.yaml` (`version:`) 保持一致；改一处要同步改另两处
- **不把 `release/` / `packaging/tools/` / `*.AppImage` 入库** — 已在 `.gitignore` 排除；这些是构建时产物
- **v1.0 范围不引入 zsync / `--updateinformation` / GPG 签名 / GitHub Actions CI / 多 distro 自动测试** — 详见 SESSION_HANDOFF "Not Implemented (延期到后续版本)"
- 不改 `make_appimage.sh` 的 Stage 4 (AppRun 写入逻辑) — 任何 GTK 环境变量注入都会导致 HiDPI 回归

### Windows 发布工程（Phase W1 已实施 — 见 `docs/SESSION_HANDOFF.md` Phase W1）
- **v1.0 不引入 Inno Setup / NSIS / MSIX / 代码签名** — 仅产出可分发的 ZIP，不做安装器
- **不改 `windows/runner/runner.exe.manifest`** — `PerMonitorV2` DPI + Win10/11 supportedOS 已正确；改动可能破坏 HiDPI
- **不改 `windows/CMakeLists.txt` / `windows/runner/CMakeLists.txt` 安装规则** — Flutter 默认模板的自包含 bundle 结构已可用
- **不改 `packaging/config/env_windows.sh` 的 `APP_ID` / `APP_VERSION`** — 4 处一致铁律：`linux/CMakeLists.txt:10` / `windows/runner/Runner.rc` (`CompanyName` / `ProductName`) / `pubspec.yaml` (`version:`) / `env*.sh` (`APP_VERSION`)
- **不把 Windows build 产物 / ZIP / SHA256SUMS-windows.txt 入库** — 已在 `.gitignore` 排除
- **Windows Release 构建必须在 Windows 主机执行** — Linux 无法 `flutter build windows`（需 MSVC + Windows SDK）；CI 跨平台编译不在 v1.0 范围
- **`make_windows_zip.sh` 唯一依赖 Python 3** — 不依赖 7-Zip / Inno Setup / NSIS；Python 3 是 Flutter Windows 工具链必装项
- **`windows/runner/Runner.rc` 仅允许修改 4 个字符串字段** — `CompanyName` / `FileDescription` / `LegalCopyright` / `ProductName`；其他字段（`FileVersion` / `ProductVersion` / `OriginalFilename`）由 Flutter 工具链自动注入

## 版本来源管理 (Phase L1.2 已实施)

**pubspec.yaml 是版本主来源**（`version: 1.0.0+1`）。每次发版改一处 pubspec + 两处 env*.sh，CI 自动校验一致性，metainfo.xml 由 CI 注入。

### 5 处硬编码版本来源

| # | 文件 | CI 校验 | CI 注入 | 同步责任 |
|---|------|---------|---------|---------|
| S1 | `pubspec.yaml` `version:` | ✓ 两 workflow 都校验 (strip `+build`) | — | 开发者 |
| S2 | `packaging/config/env.sh` `APP_VERSION="1.0.0"` | ✓ `release-linux.yml` Step 4 (strip `-prerelease`) | — | 开发者 |
| S3 | `packaging/config/env_windows.sh` `APP_VERSION="1.0.0"` | ✓ `release-windows.yml` Step 4 (strip `-prerelease`) | — | 开发者 |
| S4 | `windows/runner/Runner.rc` `VERSION_AS_STRING "1.0.0"` | ✗ | ✗ | Flutter 工具链已从 pubspec 注入 FileVersion/ProductVersion 数值字段 |
| S5 | `linux/metainfo/io.github.beilusm.ridenps.metainfo.xml` `<release version="1.0.0" date="2026-07-19">` | ✗ | ✓ `release-linux.yml` `sed` 注入 tag 版本 + 当天日期到 runner workspace | CI |

### 发版流程（v1.0.1+）

1. 改 `pubspec.yaml` `version:` (S1) — 主来源
2. 改 `packaging/config/env.sh` `APP_VERSION="..."` (S2)
3. 改 `packaging/config/env_windows.sh` `APP_VERSION="..."` (S3)
4. **不改** `linux/metainfo/...metainfo.xml` `<release>` — Linux release workflow CI 自动注入 tag 版本 + 当前日期到 runner workspace 工作副本
5. **不改** `windows/runner/Runner.rc` `VERSION_AS_STRING` — 该字符串字段仅影响 VS_VERSION_INFO 资源块中的一个条目；Flutter 工具链已从 `pubspec.yaml` 自动注入 `FileVersion` / `ProductVersion` 数值字段。Phase L1.2-A 接受不校验 S4
6. 打 tag `v1.0.1` → 两 workflow 同步触发 → CI 校验 S1+S2 (Linux) / S1+S3 (Windows) → Linux 注入 S5 → 双平台 assets 上传到同一 Release

### CI 校验语义

- `tag_semver = tag_version` 去掉 `-prerelease` 后缀（用 `%%-*` longest match，例如 `1.0.0-l12-test` → `1.0.0`）
- `pubspec_semver = pubspec_version` 去掉 `+build` 后缀
- `env APP_VERSION` 无 prerelease 后缀（与 pubspec `+` 前部分同步为纯 semver）
- 三者必须严格字符串相等，否则 CI fail 通知同步

### 版本来源不做的事

- **不创建 `sync_versions.sh` 自动同步脚本** — 五来源手工同步足够，避免脚本运行时机 / 共谋 / 修改 repo 内容等复杂度
- **不自动修改 `Runner.rc`** — 二进制资源文件 sed 改易破坏 MSVC .rc 编译；Flutter 工具链已注入主要版本字段
- **不改 `env.sh` / `env_windows.sh` / `metainfo.xml` 仓库文件本身** — CI 只校验 (S2/S3) 或只改 workspace 副本 (S5)，不 commit 不 push
- **不扩展 dev CI**（`windows-build.yml` / `linux-build.yml`）— 版本校验只在 tag 触发的 release workflow 生效，dev CI 不变
- **不改本地打包脚本**（`packaging/scripts/*.sh` / `make_appimage.sh`）— metainfo 注入由 CI workflow 内联 step 完成，不注入到本地构建链路

### 通用
- 不主动提交 git，除非用户明确要求
- 不新增业务功能（当前阶段只做稳定性修复；**发布工程相关除外**，见 Phase 3 / Phase W1 / Phase L1.2 / **Phase 4 Android** / **Phase 5 Slot Edit** 章节）
- 任何代码修改完成后必须运行 `fvm flutter analyze` 验证 0 新 issue
- 不重新启用 `@Deprecated` 的 `loadSlot()` / `loadMemorySlot()` — HR19 quickSwitch 已硬件验证为设备唯一真实切换入口，旧路径软件模拟仅供回退测试保留
- **Phase 4 Android 移植 override 仅限 `modbus_worker.dart` driver 层 / `serial_port_enumerator.dart` / `lib/main.dart` 平台守卫 / `lib/app.dart` UI 触屏适配**；其他铁律全部保留，详见 `docs/PHASE_4_ANDROID.md` §6

## 当前 Patch 状态

见 `docs/SESSION_HANDOFF.md`：

- **Phase 1** — Release 验证：APPLIED（25MB bundle，干净环境启动正常，SIGTERM 3s 退出）
- **Phase 2** — Linux Desktop Integration：APPLIED（App ID / 图标 / .desktop / metainfo / udev 全部完成）
- **Phase 3** — Release Engineering：APPLIED（4 个 packaging 脚本，9.9MB AppImage，HiDPI 验证通过）
- **Phase W1** — Windows Resource + ZIP Pipeline：APPLIED（Runner.rc 4 字段 + main.cpp 标题 + 20KB .ico + env_windows.sh + make_windows_zip.sh + build_windows_release.sh）
- **Phase W2** — Windows Release 实测：v1.0.0 已通过 `release-windows.yml` CI 发布 (Windows-only Latest)；本地 `make_windows_zip.sh` 路径仍待用户在 Windows 主机实测
- **Phase L1.1** — Linux GitHub Release automation：APPLIED（`release-linux.yml` 17 steps，`gh release` fallback，AppImage + SHA256SUMS-linux.txt）
- **Phase L1.2** — 版本来源 CI 校验 + metainfo 注入：APPLIED（双 workflow +env*.sh 校验 / Linux +metainfo sed 注入；见"版本来源管理"章节）
- **P0 修复 + P1-3 修复 + Option B refactor**：APPLIED
- **P1-1 (`_onPollMiss` 死代码)**：仍 OPEN
- **P1-2 (zombie `_worker` 阻塞自动 reconnect)**：APPLIED（`ModbusWorkerHandle.isDead` getter + `_cleanup()` 同步 `_dead=true` + `SerialModbusService._handleWorkerError` 与 connect/disconnect/listPorts fast-path + `PowerSupplyProvider._onData` `CommStatus.error` 传播；`test/serial_worker_lifecycle_test.dart` 7 test PASS）
- **Phase A — Register Schema 与 Worker 解码对齐**：APPLIED（HR3/HR7/HR15/HR16 新字段；auxVoltage/statusFlags `@Deprecated` 保留；quickSwitch 接口 + SerialImpl + Mock 实现）
- **Phase A.5 — HR19 硬件快速切换验证**：APPLIED（真机 PASS — HR19 0→1 触发 HR8 4.20V→5.00V + HR9 6.100A→5.000A，与 M1 preset 一致；HR19 (0x0013) 是设备硬件 Memory Slot 切换入口）
- **Phase B — UI 迁移到 quickSwitch**：APPLIED（UI 全部 loadSlot→quickSwitch；`loadSlot` / `loadMemorySlot` 标 `@Deprecated`，实现保留；`PowerSupplyProvider.quickSwitch` = write HR19 → 600ms 等待 → readRawRegisters HR0..HR120 → `_data.copyWith` 全字段刷新）
- **Phase B.1 — quickSwitch 稳定性优化**：APPLIED（quickSwitch copyWith 中 ovp/ocp 源从 `raw[82]/raw[83]` 改为 `raw[80+slot*4+2/3]`；`[QSW] before/after` debug 日志；`readAllMemorySlots()` 单次 bulk read 代替 10 次 `readMemorySlot(i)` 循环）
- **Phase B.2 — Active OVP/OCP 数据同步修复**：APPLIED（修复 FAST poll 读 HR82/HR83 覆盖 active 值导致 quickSwitch 后 UI 闪回 M0 的 bug。三层守卫：service `_sub.listen` 不让 `snapshot.ovp/ocp` 覆盖 `_current`；service `_parseAllRegs` 不再填 ovp/ocp；provider `_onData` merged 守卫 + SLOW poll SLOT-sync 把 active slot storage 升到 `_data.ovp/ocp`。`register_conflicts.dart` HR14/HR82/HR83/HR2 标 [RESOLVED]；`register_definition.dart` HR14/HR82/HR83 `conflict: false`（RegisterPage 感叹号 0x0E/0x52/0x53 消失）；`_parseAllRegs` + Mock `inputVoltageAlt` /10 路径删除。`flutter analyze` 28→21 issues / 0 新增；`flutter test` 24/24 PASS）
- **Phase C — CH340 串口自动扫描 + 400ms 自动重试**：APPLIED — **已被 Phase D 替代**（用户后续反馈"持续监控但不要压垮下位机响应性能"，见 Phase D）。Phase C 实现保留作为底层基础：`serial_port_scanner.dart` 纯 Dart 类 + `serial_port_enumerator.dart` FFI isolate 入口；`SerialModbusService.connect` 新增 `scannerFactory` 构造参数 + scan-before-spawn reorder；explicit port 路径 bypass scanner (手动选择保留)。Phase C 的 400ms `_autoScanTimer` + `startAutoScan` / `stopAutoScan` / `isAutoScanning` 已被 Phase D 的 1s `_usbWatchTimer` + `startUsbWatch` / `stopUsbWatch` / `isUsbWatching` 取代；`test/auto_scan_retry_test.dart` 被 `test/usb_watcher_test.dart` 取代。
- **Phase D — USB watcher (1s scanCh340 替代 400ms blind connect retry) + follow-up (currentPort API + flag-based disconnect)**：APPLIED（用户明确请求"持续监控串口设备又不消耗下位机那可怜的响应性能" + 后续 3 个 UX bug 反馈，override CLAUDE.md "不新增业务功能" 禁令，仅本次会话）。核心改动：
  - `ModbusService` 抽象接口新增 `Future<SerialPortScanResult> scanCh340()` — 轻量 USB 探测，**不发 Modbus / 不 spawn worker / 不开 serial port fd**；`SerialModbusService.scanCh340()` 转发 `_scannerFactory().scanCh340()` 不依赖 `_worker`；`MockModbusService.scanCh340()` 默认返回 `found('MOCK')`（mock 模式代表"虚拟设备在场"，语义对齐 mock 启动 polling 这一事实 — 不能让 watcher 在 mock polling 起来后 1s 就主动 disconnect）
  - `ModbusService` 新增 `String? get currentPort` — UI port 显示 bug 修复：auto-scan 路径调 `connect(port: null)` → service scanner 解析真实端口 (e.g. `/dev/ttyUSB0`) 存入 `_currentPort`，provider.connect 改 `_connectedPort = _service.currentPort ?? port` 优先从 service 读，让 UI SerialPanel 显示真实端口名而非 panel 自己的状态。`disconnect` / `connect-fail` 都清 `_currentPort = null`，`MockModbusService.currentPort` 默认 `null`。
  - `PowerSupplyProvider._usbWatchTimer` 1s `Timer.periodic`，`_usbWatchTick` 状态机：`!found && _connected` → 主动 `disconnect(userInitiated: false)` 撕 worker 节省 ~250ms 在途 `_accumulateRead` timeout，watcher 留着；`!found && !_connected && _userDisconnected` → **清 `_userDisconnected` flag**（物理拔出事件否决用户意图 → 下次插回会自动重连）；`!found && !_connected` → no-op **device stays cold**（用户核心需求）；`found && _userDisconnected` → no-op（尊重用户的 disconnect 决定，不打脸）；`found && _connected` → no-op polling 自保活；`found && !_connected && !_userDisconnected` → `connect()`。
  - **`disconnect({bool userInitiated = true})`** — Phase D follow-up 重命名 `stopWatcher` → `userInitiated`。用户 explicit disconnect (`userInitiated: true` 默认) **不再 stopUsbWatch**，而是设 `_userDisconnected = true` flag 保持 watcher armed，让后续 unplug + replug 仍能自动重连；watcher 自己的 proactive disconnect 调 `userInitiated: false` 不设 flag（已物理拔走，无用户意图需要尊重）。
  - **`connect()` 入口和 finally** — 入口清 `_userDisconnected = false`（用户主动 connect 消费之前残留的 disconnect 意图），finally 调 `startUsbWatch()`（即使某条路径停了 watcher，connect 成功后立即重启 — idempotent，已 armed 时 no-op）。`dispose()` 仍 `stopUsbWatch()` 兜底防泄漏。
  - **flag-based disconnect 解决的 3 个用户报告 UX bug**：UI 不显示端口名、手动几次 connect/disconnect 后自动连接失效、手动 disconnect + 拔 + 插不会自动重连。核心洞察：watcher 永远 armed（除非 dispose），用户的 disconnect 意图是 transient flag 而非 stop signal；物理 unplug 事件清 flag，下次 plug-in 自动重连。这是用户的"实体 unplug 是新 session 的开始"心智模型。
  - Worker crash (P1-2) 不碰 timer → 下次 1s tick relight connect。不改 ModbusScheduler / ModbusWorker / _accumulateRead 250ms / FAST 150ms / SLOW 1000ms / quickSwitch / 数据模型 / 寄存器定义 / `serial_port_scanner.dart` / `serial_port_enumerator.dart`。
  - `flutter analyze` 21 issues / 0 新增；`flutter test` 48→52 PASS（删 8 旧 auto-scan test + 加 12 新 usb-watcher test 含 3 个 flag-based disconnect 回归 + 修 2 个 fakeAsync async-body caveat 测试）。
- **Phase E — Measurement Recording 数据记录 (event-driven record + Save dialog + UI + 39 测试)**：APPLIED（仅本次会话，override CLAUDE.md "不新增业务功能" 禁令 — 数据记录是 Post-Release 阶段候选功能，用户认可。**已发布 v1.0.4**：commit `d047ed2` + tag `v1.0.4` + 双 CI 全绿 + 4 assets）。核心改动：
  - `lib/models/power_snapshot.dart` — `PowerSnapshot` 业务数据模型（9 字段：timestamp/voltage/current/power/inputVoltage/temperature/outputEnable/protectionState/activeSlot）；`PowerSnapshot.from(PowerSupplyData, {required int activeSlot})` 工厂；`toCsvRow()` 输出 9 列 CSV 行（ISO-8601 秒精度截断 fractional seconds，double `toStringAsFixed(2)` + 去 trailing zeros 但保留 `.0`，bool 小写 `true`/`false`）。**不含 HR 地址 / 原始寄存器值 / Modbus scaling** — Logger 消费者只看物理单位 + 高层枚举，用户明确要求 "Logger 只能消费业务数据模型"。
  - `lib/services/snapshot_store.dart` — `SnapshotStore` 单 isolate 内存缓存（`update(snap)` / `latest()` / `clear()`）；**无 Timer / 无 Modbus / 无 Scheduler 交互**，纯被动接收 provider `_onData` 回调写入。`latest()` 返回缓存引用直接，调用方契约 = read-only（不 mutate）。无 dedup（throttling 是 DataLogger 层职责）。`clear()` 由 provider `disconnect` 调用防止跨 session 数据泄漏。
  - `lib/services/data_logger.dart` — `DataLogger` + `RecordingSession`；**event-driven 写 CSV（无 Timer）**。Provider 在 `_onData`（每次波形刷新 FAST ~150ms + SLOW ~1000ms）调 `record(PowerSnapshot)`，每次 `_onData` = 一行 CSV，与图表点 1:1 对应、无漏采样。`IOSink.writeln` 缓冲写入，FAST 频率调用 record 不等于每秒 6-7 次 disk sync — 字节在内存 chunk 累积，buffer 满或 `stop()` 才真正落盘。`record()` 用 `_sink != null` 守卫（start 设 sink，stop/dispose 都清 sink；比 `isRecording` 更精确 — dispose 不翻转 isRecording 但同样要阻断 record）。`start({String? filePath})` — 接受用户从 Save dialog 选的路径（生产），或回退到 `<app_support>/recordings/riden_recording_<yyyyMMdd_HHmmss>.csv`（`recordingDirFactory` 注入点供测试，本地时间非 UTC）。filePath 非空时绕过 `recordingDirFactory`，且若父目录不存在则 `parent.create(recursive: true)` 防御性补建。`stop()` / `dispose()`；**Logger 是消费者不是通信任务** — 不发 Modbus / 不 spawn worker / 不开 serial port fd。`stop()` `await sink.flush()` + `await sink.close()` 保证磁盘可见；`dispose()` 同步 close 不阻塞 shutdown。CSV header = `time,voltage,current,power,inputVoltage,temperature,outputEnable,protectionState,activeSlot`。
  - `lib/services/event_logger.dart` — `EventLogger` 预留接口（`log(String type, Map payload)` → `debugPrint` only）；Phase E 本阶段只实现接口不实现完整 UI。预留事件类型：`ovp_trigger` / `ocp_trigger` / `otp_trigger` / `protection_clear` / `slot_change` / `usb_disconnect` / `usb_reconnect` / `param_write` / `recording_start` / `recording_stop`。
  - `lib/widgets/recording_panel.dart` — `RecordingPanel` StatelessWidget 最小 UI：START/STOP toggle button + elapsed (HH:MM:SS) + sample count + file path（>56 字符截断 `.../<filename>`）+ recording pulse dot 动画（0.7s opacity oscillation，纯装饰）。**START 按下先弹原生 Save File dialog**（`file_picker` 包 `FilePicker.platform.saveFile(dialogTitle: 'Save recording as…', fileName: 'riden_recording_<yyyyMMdd_HHmmss>.csv', type: FileType.custom, allowedExtensions: ['csv'], lockParentWindow: true)`），用户选完路径 → `provider.startRecording(filePath: picked)`；Cancel → 灰色 SnackBar "Recording cancelled — no file selected."，不动 logger session。无 session list / replay / export（Phase E 设计明确 "不要设计复杂历史管理"，用户自行管理 recordings 目录）。
  - `lib/widgets/dashboard_panel.dart` — 接入 `RecordingPanel` 在 `SerialPanel` 之后；用 `SingleChildScrollView` 包 Column（Phase E 加 RecordingPanel 后总高超过最小窗口 640 → 原 `Spacer()` 布局溢出；改为滚动 + `mainAxisSize.min`）。
  - `lib/providers/power_supply_provider.dart` — imports 新增 3 module；`_store = SnapshotStore()` + `_logger = DataLogger()` + `_eventLogger = EventLogger()` 字段（DataLogger 已不再依赖 SnapshotStore — event-driven 后 logger 直接接收 snap，store 保留为 latest 缓存）；`recordingSession` getter；`_onData` 在 SLOT-sync 后构建 `final snap = PowerSnapshot.from(_data, activeSlot: _activeSlot)` 一次，**同时** `_store.update(snap)` + `_logger.record(snap)` — CSV 行与图表点一一对应；`disconnect` 中 `_store.clear()`（**不清 logger session** — 用户可能 unplug+replug 中途录制，file 保持 open，reconnect 后继续写同一 session；无 _onData 期间 record 不被调用，文件自然停增长）；`dispose` 中 `_logger.dispose()`；新增 `startRecording({String? filePath})` / `stopRecording()` 公共方法（try/catch + rethrow 让 UI surface 为 SnackBar + notifyListeners；`filePath` 透传给 `DataLogger.start`，`null` 时走 recordingDirFactory fallback 路径供测试）。
  - `pubspec.yaml` — `path_provider: ^2.1.4` + `file_picker: ^8.1.0` dependency 新增。
  - 测试：`test/power_snapshot_test.dart`（9 个）+ `test/snapshot_store_test.dart`（8 个）+ `test/data_logger_test.dart`（22 个 — 全部同步；包含 `start({filePath})` 组：验证用户路径绕过 recordingDirFactory + 父目录缺失时 recursive create）= 39 个 Phase E 测试。
  - `flutter analyze` 21 issues / 0 新增；`flutter test` 91 PASS（39 Phase E + 0 回归）。
  - **UI bug 修复** (v1.0.4 hot-fix)：`recording_panel.dart` 的 `color.withValues(alpha: 0x18)` 是误用 — Flutter 3.32+ 新 `Color.withValues({double? a})` 期望 0.0-1.0 浮点，传 `0x18` (=`24`) 被 clamp 到 `1.0` = 100% 不透明，绿/红实色盖住按钮文字 — 用户报告"记录卡牌上看不到字，要么全绿要么全红"。改用 codebase 一致的 `withAlpha(0x18)` (int 0..255 API)，与 `serial_panel.dart:332` 习惯对齐。
  - **已发布 v1.0.4**：commit `d047ed2` + tag `v1.0.4` + 双 CI 全绿 + 4 assets (AppImage + Windows ZIP + 2 SHA256SUMS)。Release notes 极简版（更新日志 + 校验命令 + 前置依赖）：https://github.com/beilusm/RIDEN/releases/tag/v1.0.4
  - **铁律保持**：不改 ModbusScheduler / ModbusWorker / `_accumulateRead` 250ms / FAST 150ms / SLOW 1000ms / quickSwitch / 数据模型 / 寄存器定义 / `serial_port_scanner.dart` / `serial_port_enumerator.dart` / `modbus_task.dart` / `modbus_service.dart` 抽象接口 / `serial_modbus_service.dart` / `mock_modbus_service.dart`。Phase E 全部在 UI isolate 新增模块 + provider 字段接入，零通信层改动。
- **Phase 4 — Android 平台移植**：**APPLIED** (v1.1.0，真机 PASS 2026-07-25；spike 验证 → 实施 → 三个后续 fix commit `1ce417c` / `b4b97e5` / `f56df04` / `14b01c0`)。`usb_serial ^0.5.2`（felHR85 Java driver，内置 Ch34xSerialDriver）替代 `flutter_libserialport` 在 Android 路径的角色 — spike 真机三项 PASS：(1) `UsbSerial.listDevices()` 枚举到 CH340 (vid=0x1a86 pid=0x7523 / product="USB Serial")；(2) `device.create()` + `port.open()` + `setPortParameters(115200, 8, 1, NONE)` + `setDTR/RTS` + `inputStream.listen` 全通；(3) TX 8B `01 03 00 00 00 0A C5 CD` → ~60ms 后 RX 25B 完整 Modbus RTU 响应（slave/FC/byteCount/20B data/CRC16），两次读 HR0..9 数据微变化证明设备真实在线。
  - **铁律 override 范围（Phase 4 限）**：`modbus_worker.dart` driver 层（connect/disconnect/read/write/enumerate `Platform.isAndroid` 分支；worker isolate 仅 Desktop 路径用）+ `serial_port_enumerator.dart`（`UsbSerial.listDevices()` Android 入口）+ `lib/main.dart` 平台守卫（`if (!Platform.isAndroid) windowManager.*` + `SystemUiMode.immersiveSticky`）+ `lib/app.dart` UI 触屏适配。其他铁律全部保留 — 不改 ModbusScheduler / `modbus_task.dart` / `_accumulateRead` 250ms / FAST 150ms / SLOW 1000ms / quickSwitch / 数据模型 / `RegisterDefinition` / `register_conflicts` / `modbus_service.dart` 抽象接口 / `serial_modbus_service.dart` / `mock_modbus_service.dart` / `serial_port_scanner.dart`。
  - **DirectAndroidModbusService (UI-isolate-only)**（commit `b4b97e5`）：Flutter 3.44 `BackgroundIsolateBinaryMessenger` 无法在 worker isolate 跑 usb_serial 的 MethodChannel + EventChannel reply — `platform_message_response_dart_port.cc:53 Check failed: did_send` FATAL abort。故 Android 不用 worker isolate，改用 `DirectAndroidModbusService` 在 UI isolate 直接跑 usb_serial（platform channel async 非 blocking，不违反"UI 不直接访问 SerialPort"铁律本意，该铁律针对同步 FFI 如 libserialport）。复用 `ModbusScheduler` / `_accumulateRead` / frame builder / CRC16 1:1。
  - **新增模块**：`lib/services/serial_backend.dart` — `SerialBackend` 抽象 + `_LibserialportBackend` (Desktop) + `_AndroidUsbBackend` (Android usb_serial Stream)；`lib/services/direct_android_modbus_service.dart` — Android UI-isolate-only ModbusService 实现。
  - **包选型**：`flutter_libserialport ^0.4.0` 在 Desktop 路径保留不动；`usb_serial ^0.5.2` 仅 Android 路径用。`modbus_client_serial_android` 拒绝（3 likes / 14 weekly / 同步 API 与架构铁律冲突）。`flutter_libserialport ^0.6.0` Android 路径拒绝（社区案例两极分化）。
  - **pub-cache 前置 patch**：统一在 `packaging/scripts/patch_pub_cache_android.sh`，CI 和本地都调用，4 处：(1) `usb_serial-0.5.2/android/build.gradle` 删 `jcenter()` + AGP 4.1 classpath；(2) `flutter_libserialport-0.4.0/android/build.gradle` 删 jcenter + AGP 4.1 + CMake native + sourceSets 全空 + JVM 17；(3) `flutter_libserialport-0.4.0/android/.../FlutterLibserialportPlugin.kt` v2 embedding stub（删 v1 Registrar 引用）；(4) `file_picker-8.3.7/android/build.gradle` 删 AGP 7.4.2 classpath + compileSdk 跟随 rootProject (36)。
  - **Android SDK 配置**：`android/app/build.gradle.kts` `compileSdk = flutter.compileSdkVersion` (不硬 pin，Flutter 3.44.6 默认 36 满足传递依赖) / `minSdk = 21` / `targetSdk = 34`，删 `ndkVersion = flutter.ndkVersion`（usb_serial 是纯 Java 无 native build，不需要 NDK）。本机 SDK 路径 `~/Android/Sdk`（不是 `/opt/android-sdk`），需 `export ANDROID_HOME=$HOME/Android/Sdk`。
  - **AndroidManifest**：`<uses-feature android:name="android.hardware.usb.host"/>` + `<intent-filter USB_DEVICE_ATTACHED>` + `@xml/device_filter` 含 CH340 `vendor-id="6790" product-id="29987"` (= 0x7523 decimal，不是 29723 = 0x741B)。
  - **SystemUiMode**：`immersiveSticky`（commit `f56df04`）— `edgeToEdge` 只让状态栏透明覆盖，时间/电池图标仍一直可见；immersiveSticky 彻底隐藏，边缘向内滑临时唤出。
  - **Recording CSV Android 路径**（commit `14b01c0`）：Android SAF (Storage Access Framework) 是 one-shot bytes-only — `FilePicker.saveFile(bytes:)` 写 bytes 到 content:// URI，无"open writable stream"模式。故 Android 流程：START 立即开始写 app 私有 tmp 文件（path_provider application support dir）→ STOP 时 flush+close → 读 tmp bytes → `FilePicker.saveFile(bytes:)` 弹系统文件选择器选保存位置 → SAF 落盘 → 删 tmp。Cancel 保留 tmp 并 SnackBar 提示路径。Desktop 路径保持原 Save dialog 先行不变。
  - **版本来源 S6**：新增 `packaging/config/env_android.sh` `APP_VERSION="1.1.0"`，纳入 4 处 env 一致性同步（S2 env.sh + S3 env_windows.sh + S6 env_android.sh 与 S1 pubspec）。
  - **CI workflows**：`release-android.yml` (tag 触发 + GitHub Release 上传 APK + SHA256SUMS-android.txt) + `android-build.yml` (push 触发 dev CI, 4m39s PASS)。
  - **验收**：`flutter analyze` 21 issues / 0 新增；`flutter test` 91 PASS / 0 回归；真机 V/A/W 波形显示 + quickSwitch M2 切换 + USB watcher 拔插自连 + Recording CSV STOP 弹系统文件选择器选保存位置全验证 PASS。
- **Phase 5 — Memory Slot 数据组值编辑 (preset dialog EDIT 入口 + saveSlotValues API + 4 鲁棒性修复 + 7 测试)**: **APPLIED**（仅本次会话，override CLAUDE.md "不新增业务功能" 禁令 — 用户明确请求 "加入编辑 M1-M9 数据组值功能，入口在打开数据组菜单里面"。**已发布 v1.1.1**)。核心改动：
  - **设计**：编辑入口设在 `SetpointPanel._showPresets` 预设 dialog（dashboard 上的实际入口 — `BottomStatus` 是孤立旧 widget 不出现在 `dashboard_panel.dart`）。每行尾部 `IconButton(Icons.edit)` → 弹出 4 字段 (V SET / I SET / OVP / OCP) 编辑子 dialog，带 +/- spin button + 0..62V/0..6.2A clamp（与 `_editDialog` 一致），Save 写入设备。 preset dialog 用 `Consumer<PowerSupplyProvider>` 包裹，编辑后 subtitle 自动刷新不关对话框。
  - **Storage-only edit 语义**：Writing slot storage registers (HR[80 + index*4 + 0..3]) only — 不动 HR8/HR9 live Vset/Iset。OVP/OCP edit on *active* slot happens to land on the same physical register (HR[80+activeSlot*4+2/3] is also the active protection register per Phase B.2)，但 V-Set/I-Set storage edits 需要 [quickSwitch] round-trip 才能应用到 live Vset/Iset。UI 提示用户 "tap LOAD (quickSwitch) after EDIT to activate"。
  - **Authority routing**：UI → `provider.saveSlotValues(index, v, i, ovp, ocp)` → `_service.saveMemorySlot` (existing method，三 ModbusService 实现均已有 HR[80+i*4+0..3] 写入路径，未改) → `_loadOneSlot(index)` refresh 缓存 + `notifyListeners`。
  - **鲁棒性修复 4 (UI + provider)**：
    - **#1 try/catch + SnackBar 友好提示** — `commit()` async + try/catch；成功绿色 SnackBar `M$index preset saved`，失败红色 `Save M$index failed: $e`（沿用 recording_panel 风格 + `AppTheme.voltGreen`/`errorRed`）。失败时 dialog 不关，用户可重试。
    - **#2 无效输入 SnackBar 非静默吞** — 4 字段任一 `double.tryParse` 返回 null 时弹红色 SnackBar `Invalid value — use a decimal number` 并 **不关闭 dialog**，让用户能修正。`Navigator.pop` 只在 `saveSlotValues` 成功路径后执行。
    - **#3 onSubmitted commit** — `_editField` 加 `ValueChanged<String> onSubmitted` 参数；4 字段共用 `(_) => commit()` 回调，回车键直接 commit（与 `_editDialog` 一致）。
    - **#10 `[SLOT_EDIT]` debugPrint** — provider 成功路径写 `[SLOT_EDIT] before M$index <oldVals> → <newVals>` / `[SLOT_EDIT] after M$index <refreshedVals> (changed|no change — write same as before)`，风格与 `[QSW]` 一致，真机调试可观测设备真实回值。
  - **新增文件**：`test/save_slot_values_test.dart`（7 个新测试 — 写入缓存刷新 / 覆盖已 seed slot / notifyListeners / 越界 no-op / storage-only 不动 live V/I / M0 边界守卫 / 服务失败 rethrow 不吞错 + `_ThrowingSaveMock` test double）。
  - **铁律保持**：不改 ModbusScheduler / `modbus_task.dart` / `modbus_service.dart` 抽象接口 / `serial_modbus_service.dart` / `mock_modbus_service.dart` / `direct_android_modbus_service.dart` / `modbus_worker.dart` / `_accumulateRead` 250ms / FAST 150ms / SLOW 1000ms / quickSwitch / 数据模型 / `RegisterDefinition` / `register_conflicts` / `serial_port_scanner.dart` / `serial_port_enumerator.dart` / `serial_backend.dart`。Phase 5 全部在 UI isolate 新增方法 + UI dialog，复用 `service.saveMemorySlot` 既有写入路径，零通信层改动。
  - **验证**：`flutter analyze` 21 issues / 0 新增；`flutter test` 98 PASS / 0 回归（91 旧 + 7 新）。
