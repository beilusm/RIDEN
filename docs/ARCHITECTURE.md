# 架构与开发指南

RIDEN 数控电源 Flutter 上位机（Linux + Windows + Android）。本文档面向从源码构建、运行、贡献代码的开发者。终端用户文档见 [README](../README.md)；项目修改禁令见 [CLAUDE.md](../CLAUDE.md)。

## 开发环境

| 工具 | 版本 | 用途 |
|---|---|---|
| [Flutter](https://docs.flutter.dev/get-started/install) | 3.44+ | UI 框架 + Dart SDK |
| [FVM](https://fvm.app/) | 最新 | Flutter 版本管理（推荐） |
| Linux 开发机 | Ubuntu 20.04+ | 需 `libserialport-dev` |
| Windows 开发机 | Windows 10/11 + VS 2022 | 需"使用 C++ 的桌面开发"工作负载 |
| Android 开发机 | Android SDK 36 | `ANDROID_HOME=$HOME/Android/Sdk` |

## 源码运行

```bash
git clone https://github.com/beilusm/RIDEN.git
cd RIDEN
fvm flutter pub get

fvm flutter run -d linux         # Linux Desktop
fvm flutter run -d windows       # Windows Desktop
fvm flutter run -d <device-id>   # Android (先 fvm flutter devices 查 ID)
```

串口自动检测覆盖 Linux (`/dev/ttyUSB*` / `/dev/ttyACM*`)、Windows (`COM*`)、Android（USB HOST）；也可 `connect(port: 'COM3')` 手动指定。

## 项目结构

```
lib/
├── main.dart                         # 入口：Provider 注入 + 平台守卫
├── app.dart                          # MaterialApp + 响应式布局
├── theme/app_theme.dart              # 统一暗色主题
├── models/
│   ├── power_supply_data.dart        # 不可变数据模型 + MemorySlot
│   ├── power_snapshot.dart           # 录制业务快照（CSV 序列化）
│   └── register_definition.dart      # 寄存器 schema（datasheet 映射）
├── providers/
│   └── power_supply_provider.dart    # ChangeNotifier 状态管理
├── services/
│   ├── modbus_service.dart           # ModbusService 抽象接口
│   ├── modbus_task.dart              # Task 模型 (priority/aging/dedup)
│   ├── modbus_scheduler.dart         # 统一任务调度器（串行执行）
│   ├── modbus_worker.dart            # Desktop：Modbus Isolate entry + WorkerCore
│   ├── serial_modbus_service.dart    # Desktop：UI proxy → worker isolate
│   ├── direct_android_modbus_service.dart  # Android：UI-isolate usb_serial
│   ├── serial_backend.dart           # SerialBackend 抽象
│   ├── serial_port_scanner.dart      # USB 扫描封装
│   ├── serial_port_enumerator.dart   # FFI / usb_serial 枚举入口
│   ├── mock_modbus_service.dart      # 无硬件 mock
│   ├── data_logger.dart              # CSV event-driven 录制器
│   ├── snapshot_store.dart           # latest 快照缓存
│   └── event_logger.dart             # 事件日志接口（预留）
└── widgets/
    ├── dashboard_panel.dart          # 主面板容器
    ├── power_chart.dart              # 实时双 Y 轴波形图 (fl_chart)
    ├── measurement_display.dart      # V / A / W 数值显示
    ├── setpoint_panel.dart           # 设定值编辑 + PRESET (M1-M9)
    ├── status_bar.dart               # 通信状态 + 能耗 / 温度 / Vin
    ├── serial_panel.dart             # 串口设置卡片
    ├── recording_panel.dart          # CSV 录制控制
    ├── register_page.dart            # 寄存器表格 UI（Schema 驱动）
    └── register_view.dart            # 全页寄存器调试视图
```

## 双 Isolate 架构

```
UI Isolate                          Modbus Worker Isolate (Desktop only)
────────────                        ────────────────────────────────────
PowerSupplyProvider                 PeriodicTaskSource (Timer×2)
  ChangeNotifier                      │
SerialModbusService (proxy)         ModbusScheduler
  SendPort ←────→ ReceivePort       ModbusExecutor (_accumulateRead 250ms)
                                    SerialBackend (libserialport FFI)

Android 路径：
DirectAndroidModbusService 在 UI isolate 直接跑 usb_serial
  (Flutter 3.44 worker isolate 跑不了 usb_serial 的 MethodChannel)
```

**铁律**：UI isolate 不直接接触同步 FFI（`libserialport`）。Android 用 `usb_serial` platform channel（async 非 blocking）属于例外 — 它不持有原生 fd 同步句柄。

## 心智模型 — 真机实测得来的关键事实

避免在以下问题上踩坑或重新调查：

### HR19 quickSwitch — M0 不可切回

设备固件用 HR19 (`0x0013`) 作为硬件 Memory Slot quick switch 入口。写 `HR19=Mx` 后固件自动把 Mx 的 preset 加载到当前工作寄存器（HR8 Vset / HR9 Iset）。**但 `HR19=0` 是 no-op** — 设备上电时 `HR19=0` 使用 M0 preset，但写 `0` 不会触发 reload。这导致 UI 切到 M1..M9 后无法主动切回 M0；用户需要物理重上电才能复位。UI 因此隐藏 M0 选项，preset dialog 只显示 M1..M9。

旧 `loadMemorySlot()` 路径是软件模拟（读保存区 + 4 次写工作寄存器），保留 `@Deprecated` 仅供回退测试。UI 必须走 `quickSwitch()`：write HR19 → 等 600ms → readRawRegisters HR0..HR120 → `_data.copyWith` 全字段刷新。

### HR82 / HR83 = M0 slot storage，不是 active OVP/OCP

Phase B.2 datasheet 确认：HR[80 + activeSlot*4 + 2/3] 才是当前 active 的 OVP/OCP（M0=82/83, M1=86/87, M2=90/91, …）。HR82/HR83 只是 M0 自己的存储值，与 active slot 无关，不会随 quickSwitch 改变。

FAST poll 硬读 HR5..83 会把 HR82/83 注入 `snapshot.ovp/ocp`，曾导致 quickSwitch 切到 M1 后 UI 闪 150ms 正确值又回退到 M0 stored 的 bug。修复：`SerialModbusService._sub.listen` 不让 `snapshot.ovp/ocp` 覆盖 `_current`；`_parseAllRegs` 不再填 ovp/ocp；provider `_onData` merged 守卫 + SLOW poll SLOT-sync 把 active slot storage 升到 `_data.ovp/ocp`。详见 `register_conflicts.dart` HR82/83 [RESOLVED]。

### Recording — PowerSnapshot 与 PowerSupplyData 的边界

- `PowerSupplyData`：worker→UI wire model，含 HR 地址、原始寄存器值、Modbus scaling、memorySlots
- `PowerSnapshot`：Logger 消费模型，9 字段纯业务语义（timestamp/V/A/W/Vin/温度/outputEnable/protectionState/activeSlot），**不含任何 HR 地址 / scaling**。这种区分是用户明确要求 "Logger 只能消费业务数据模型"

`DataLogger` 是 event-driven：provider 在 `_onData`（每次波形刷新 FAST ~150ms / SLOW ~1000ms）调 `record(PowerSnapshot)` = 一行 CSV，与图表点 1:1 对应。`IOSink.writeln` 缓冲写入，FAST 频率调用不等于每秒 6-7 次 disk sync。

### Android SAF — 录制必须 tmp + bytes 模式

Android SAF (Storage Access Framework) 是 one-shot bytes-only — `FilePicker.saveFile(bytes:)` 写 bytes 到 `content://` URI，**无 "open writable stream" 模式**，不支持 IOSink 流式写入。故 Android 录制流程：

1. START 立即开始写 app-private tmp（`path_provider` application support dir）
2. 录制期间 IOSink 流式追加 CSV 行（与 Desktop 完全一致）
3. STOP：flush + close → 读 tmp bytes → `FilePicker.saveFile(bytes:)` 弹 SAF 文件选择器
4. 用户选保存位置 → 落盘 → 删 tmp + SnackBar 提示路径
5. Cancel：保留 tmp + SnackBar 提示路径供 `adb pull`

Desktop 路径保持 Phase E 原行为：START 前弹原生 Save dialog 选 path → IOSink 增量写入。

## Mock 模式（无硬件开发）

`main.dart` 注入 `MockModbusService()`：

```dart
create: (_) => PowerSupplyProvider(MockModbusService()),
```

mock 模拟设备轮询 250ms 一帧、CH340 持续在线，UI 可无硬件预览。`MockModbusService.scanCh340()` 默认返回 `found('MOCK')` — 不让 USB watcher 在 mock polling 起来后 1s 就主动 disconnect。

## 调试日志

唯一保留的 verbose switch在 `lib/services/modbus_scheduler.dart:12`：

```dart
static const _verboseLog = false;  // set true for per-task SCHED logs
```

生产统计每 2s 打印 `[SCHED_STAT] complete=12 data_rate=6.0/s isolate=alive`。

其他按需 grep 启用的调试 marker：

- `[QSW]` — quickSwitch 600ms round-trip（HR19 / HR8 / HR9 / M-active OVP/OCP）
- `[SLOT_EDIT]` — Memory Slot 数据组编辑（before / after + changed 标记）
- `[PROVIDER]` — provider 层错误与生命周期事件

## 构建 Release

### Linux AppImage

```bash
# 一次性前置：装 appimagetool (不入仓库)
# Arch:    sudo pacman -S appimagetool-bin
# Ubuntu:  sudo apt install appimagetool
# 其他:    https://github.com/AppImage/appimagetool/releases

./packaging/scripts/build_release.sh
# 流水线: fetch_tools.sh → flutter build linux → make_appimage.sh → compute_checksums.sh
# 产物:  release/RIDEN_PowerSupply-x.x.x-x86_64.AppImage (~10 MB) + SHA256SUMS + RELEASE_NOTES
```

设计要点：不用 `linuxdeploy` / `linuxdeploy-plugin-gtk` — plugin-gtk 的 AppRun hook 强制 `GDK_BACKEND=x11` 和 `GTK_THEME`，在 HiDPI 显示器上破坏 2x 缩放（GL frame size 2712×1616 → 1346×1616）。`AppRun` 仅 9 行，不设任何 GTK 环境变量。Debug：`--skip-build` 复用现有 bundle 验证打包脚本。

### Windows ZIP

```bash
# 前置：Windows 10/11 + VS 2022 (含"使用 C++ 的桌面开发") + Python 3 + Git Bash/WSL
fvm flutter pub get
bash packaging/scripts/build_windows_release.sh
# 流水线: flutter build windows → make_windows_zip.sh
# 产物:  release/RIDEN_PowerSupply-x.x.x-windows-x64.zip (~15 MB) + SHA256SUMS-windows.txt
```

未签名 exe 会触发 SmartScreen 警告（README 已说明用户点击 "更多信息 → 仍要运行"）。v1.0 不引入 Inno Setup / NSIS / MSIX / 代码签名。

### Android APK

```bash
# 前置：Flutter 3.44+ + Android SDK 36 + ANDROID_HOME=$HOME/Android/Sdk
packaging/scripts/patch_pub_cache_android.sh   # 必跑：4 处 pub-cache patch
fvm flutter build apk --release --target-platform android-arm64
# 产物: build/app/outputs/flutter_apk/app-release.apk
```

`patch_pub_cache_android.sh` 修复 4 处 pub-cache 兼容性：usb_serial 0.5.2 (删 jcenter + AGP 4.1) / flutter_libserialport 0.4.0 (删 jcenter + AGP 4.1 + CMake + sourceSets + JVM 17，外加 Kotlin plugin v2 stub) / file_picker 8.3.7 (删 AGP 7.4.2 + compileSdk 跟随 rootProject)。脚本幂等，CI 自动运行，本地手动跑必须执行一次。

### Linux 系统安装（供 .deb / .rpm 打包者）

```bash
cd build/linux/x64/release
cmake --install . --prefix /usr
# 安装内容:
#   /usr/bin/riden_power_supply
#   /usr/lib/.../                            (bundle/lib)
#   /usr/share/.../flutter_assets/           (bundle/data)
#   /usr/share/applications/io.github.beilusm.ridenps.desktop
#   /usr/share/icons/hicolor/*/apps/io.github.beilusm.ridenps.png
#   /usr/share/metainfo/io.github.beilusm.ridenps.metainfo.xml
```

应用 ID：`io.github.beilusm.ridenps`（Freedesktop reverse-DNS）。

## 版本来源管理

**pubspec.yaml 是版本主来源**（`version: x.x.x+N`）。每次发版改一处 pubspec + 三处 env*.sh，CI 自动校验一致性，metainfo.xml 由 CI 注入。

| # | 文件 | 位置 | 校验 |
|---|------|------|------|
| S1 | `pubspec.yaml` | `version: x.x.x+N` | CI 校验（主来源） |
| S2 | `packaging/config/env.sh` | `APP_VERSION="x.x.x"` | Linux CI 校验 |
| S3 | `packaging/config/env_windows.sh` | `APP_VERSION="x.x.x"` | Windows CI 校验 |
| S4 | `windows/runner/Runner.rc` | `VERSION_AS_STRING "x.x.x"` | 不校验（Flutter 工具链自动注入 FileVersion / ProductVersion 数值） |
| S5 | `linux/metainfo/...metainfo.xml` | `<release version="..." date="...">` | 不校验（Linux CI 注入 tag 版本 + 当前日期到 workspace） |
| S6 | `packaging/config/env_android.sh` | `APP_VERSION="x.x.x"` | Android CI 校验 |

发版流程：

1. 改 S1 `pubspec.yaml` `version:`
2. 改 S2 / S3 / S6 `APP_VERSION="..."`
3. **不改** S4 `Runner.rc`（Flutter 工具链自动注入）
4. **不改** S5 `metainfo.xml`（CI `sed` 注入到 workspace 副本）
5. commit + tag `vx.x.x` → 三平台 release workflow 同步触发 → CI 校验版本一致性 → Linux 注入 metainfo → 三平台 assets 上传到同一 Release

CI 校验语义：`tag_semver = tag_version` 去 `-prerelease` 后缀；`pubspec_semver` 去 `+build` 后缀；`env APP_VERSION` 无 prerelease；三者必须严格字符串相等。

## 测试

```bash
fvm flutter analyze    # 静态分析（基线 21 issues，全部 pre-existing）
fvm flutter test       # 单元测试（98 PASS）
```

## 许可证

MIT License — 见仓库源文件头注释。
