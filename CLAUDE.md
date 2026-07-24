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
- 不新增业务功能（当前阶段只做稳定性修复；**发布工程相关除外**，见 Phase 3 / Phase W1 / Phase L1.2 章节）
- 任何代码修改完成后必须运行 `fvm flutter analyze` 验证 0 新 issue
- 不重新启用 `@Deprecated` 的 `loadSlot()` / `loadMemorySlot()` — HR19 quickSwitch 已硬件验证为设备唯一真实切换入口，旧路径软件模拟仅供回退测试保留

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
