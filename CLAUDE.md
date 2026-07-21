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

### 通用
- 不主动提交 git，除非用户明确要求
- 不新增业务功能（当前阶段只做稳定性修复；**发布工程相关除外**，见 Phase 3 / Phase W1 章节）
- 任何代码修改完成后必须运行 `fvm flutter analyze` 验证 0 新 issue

## 当前 Patch 状态

见 `docs/SESSION_HANDOFF.md`：

- **Phase 1** — Release 验证：APPLIED（25MB bundle，干净环境启动正常，SIGTERM 3s 退出）
- **Phase 2** — Linux Desktop Integration：APPLIED（App ID / 图标 / .desktop / metainfo / udev 全部完成）
- **Phase 3** — Release Engineering：APPLIED（4 个 packaging 脚本，9.9MB AppImage，HiDPI 验证通过）
- **Phase W1** — Windows Resource + ZIP Pipeline：APPLIED（Runner.rc 4 字段 + main.cpp 标题 + 20KB .ico + env_windows.sh + make_windows_zip.sh + build_windows_release.sh）
- **Phase W2** — Windows Release 实测：待用户在 Windows 主机执行 `flutter build windows --release` + `make_windows_zip.sh` 验证
- **P0 修复 + P1-3 修复 + Option B refactor**：APPLIED
- **P1-1 (`_onPollMiss` 死代码)**：仍 OPEN
- **P1-2 (zombie `_worker` 阻塞自动 reconnect)**：仍 OPEN
