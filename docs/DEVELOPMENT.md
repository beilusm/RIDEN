# 开发者文档

面向从源码构建、运行、打包、贡献代码的开发者。终端用户文档见 [README](../README.md)。

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
# 1. 克隆仓库
git clone https://github.com/beilusm/RIDEN.git
cd RIDEN

# 2. 安装依赖
fvm flutter pub get

# 3. 连接 RIDEN 电源后运行
fvm flutter run -d linux      # Linux Desktop
fvm flutter run -d windows    # Windows Desktop
fvm flutter run -d <device-id>  # Android（先 fvm flutter devices 查 ID）
```

串口自动检测覆盖：Linux (`/dev/ttyUSB*` / `/dev/ttyACM*`)、Windows (`COM*`)、Android（USB HOST）。
也可通过 `connect(port: 'COM3')` 在代码中手动指定。

## 项目结构

```
lib/
├── main.dart                         # 入口：Provider 注入 + 平台守卫
├── app.dart                          # MaterialApp + 响应式布局
├── theme/app_theme.dart              # 统一暗色主题
├── models/
│   ├── power_supply_data.dart        # 不可变数据模型 + MemorySlot
│   ├── power_snapshot.dart           # 录制业务快照模型（CSV 序列化）
│   └── register_definition.dart      # 寄存器 schema（datasheet 映射）
├── providers/
│   └── power_supply_provider.dart    # ChangeNotifier 状态管理
├── services/
│   ├── modbus_service.dart           # ModbusService 抽象接口
│   ├── modbus_task.dart              # Task 模型（priority/aging/dedup）
│   ├── modbus_scheduler.dart         # 统一任务调度器（串行执行）
│   ├── modbus_worker.dart            # Desktop：Modbus Isolate entry + WorkerCore
│   ├── serial_modbus_service.dart    # Desktop：UI proxy → worker isolate
│   ├── direct_android_modbus_service.dart  # Android：UI-isolate usb_serial
│   ├── serial_backend.dart           # SerialBackend 抽象（libserialport / usb_serial）
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
    ├── recording_panel.dart           # CSV 录制控制
    ├── register_page.dart            # 寄存器表格 UI（Schema 驱动）
    └── register_view.dart            # 全页寄存器调试视图
```

## 架构总览

```
UI Isolate                          Modbus Worker Isolate (Desktop only)
────────────                        ────────────────────────────────────
PowerSupplyProvider                 PeriodicTaskSource (Timer×2)
  ChangeNotifier                      │
SerialModbusService (proxy)         ModbusScheduler
  SendPort ←────→ ReceivePort       ModbusExecutor (_accumulateRead)
                                    SerialBackend (libserialport)
                                    │
                                    Android path:
                                    DirectAndroidModbusService (UI isolate only)
                                      usb_serial (Stream-based)
```

**铁律：UI isolate 永远不直接访问 SerialPort。**

- Desktop：`SerialModbusService` 通过 `SendPort` / `ReceivePort` 与 worker isolate 通信；worker 内部跑 `SerialBackend` (`libserialport` FFI)
- Android：Flutter 3.44 worker isolate 无法跑 usb_serial 的 platform channel，故 `DirectAndroidModbusService` 在 UI isolate 直接跑（async 非 blocking，不违反铁律本意）

详见 `CLAUDE.md` "架构：双 Isolate" 章节。

## Mock 模式（无硬件开发）

`main.dart` 中将 service 注入替换为 `MockModbusService()`：

```dart
create: (_) => PowerSupplyProvider(MockModbusService()),
```

mock 模拟设备轮询 250ms 一帧、CH340 持续在线，UI 可无硬件预览。
Mock 路径在 `lib/services/mock_modbus_service.dart`，可调整虚拟 V/A/W 漂移幅度。

## 调试

唯一保留的 verbose switch在 `lib/services/modbus_scheduler.dart:12`：

```dart
static const _verboseLog = false;  // set true for per-task SCHED logs
```

生产统计每 2s 打印：

```
[SCHED_STAT] complete=12 data_rate=6.0/s isolate=alive
```

其他调试日志开关（按需 grep 启用）：

- `[QSW]` — quickSwitch 600ms round-trip（HR19 / HR8 / HR9 / M-active OVP / OCP）
- `[SLOT_EDIT]` — Memory Slot 数据组编辑（before / after + changed 标记）
- `[PROVIDER]` — provider 层错误与生命周期事件

## 构建 Release

### Linux AppImage

前置：装一次 `appimagetool`（不入仓库）

```bash
# Arch:       sudo pacman -S appimagetool-bin
# Ubuntu:     sudo apt install appimagetool
# 其他:       https://github.com/AppImage/appimagetool/releases
```

一条命令：

```bash
./packaging/scripts/build_release.sh
```

执行四阶段流水线：

1. `fetch_tools.sh` — 下载 `packaging/tools/runtime-x86_64`（923 KB，type2-runtime）
2. `fvm flutter build linux --release`
3. `make_appimage.sh` — 手工组装 AppDir + `appimagetool --runtime-file`
4. `compute_checksums.sh` — 生成 `SHA256SUMS` + `RELEASE_NOTES-*.md`

最终产物在 `release/`（已 gitignored）：

```
RIDEN_PowerSupply-x.x.x-x86_64.AppImage   ~10 MB   单文件可分发
SHA256SUMS                                ~1 KB
RELEASE_NOTES-x.x.x.md                    从 metainfo 自动抽取
```

**设计要点**：
- 不使用 `linuxdeploy` / `linuxdeploy-plugin-gtk` — plugin-gtk 的 AppRun hook 强制 `GDK_BACKEND=x11` 和 `GTK_THEME`，在 HiDPI 显示器上破坏 2x 缩放
- `AppRun` 仅 9 行，不设任何 GTK 环境变量；保留用户系统 HiDPI 主题 / font-scaling-factor 设置
- Debug 模式：`./packaging/scripts/build_release.sh --skip-build` 跳过 `flutter build`，复用现有 bundle 用于快速验证打包脚本

### Windows ZIP

前置：

- Windows 10 / 11
- Visual Studio 2022 含 "使用 C++ 的桌面开发" 工作负载（MSVC + Windows 10/11 SDK）
- [Python 3](https://www.python.org/downloads/windows/)（Flutter Windows 插件构建 + 打包脚本依赖）
- Git Bash 或 WSL（运行 `packaging/scripts/` 的 bash 脚本）

一条命令（Git Bash / WSL）：

```bash
fvm flutter pub get
bash packaging/scripts/build_windows_release.sh
```

执行两阶段：

1. `fvm flutter build windows --release` — 产物到 `build/windows/x64/runner/Release/`
2. `make_windows_zip.sh` — 打包为 ZIP（含 `MANIFEST.txt` 文件清单）+ `SHA256SUMS-windows.txt`

最终产物在 `release/`：

```
RIDEN_PowerSupply-x.x.x-windows-x64.zip   ~15 MB   解压即用，无需安装
SHA256SUMS-windows.txt                    ~1 KB    ZIP 的 SHA256
```

Debug 模式：`bash packaging/scripts/build_windows_release.sh --skip-build` 跳过 `flutter build`。

### Android APK

前置：

- Flutter 3.44+
- Android SDK 36 (`compileSdk = flutter.compileSdkVersion`)
- `ANDROID_HOME=$HOME/Android/Sdk`（或你的 SDK 路径）
- **必须**先运行 `packaging/scripts/patch_pub_cache_android.sh` — 4 处 pub-cache patch（usb_serial 0.5.2 / flutter_libserialport 0.4.0 / file_picker 8.3.7 build.gradle 兼容性修复）

本地构建：

```bash
packaging/scripts/patch_pub_cache_android.sh
fvm flutter build apk --release --target-platform android-arm64
```

> CI 自动运行 pub-cache patch；本地手动跑必须先执行一次该脚本，否则 Gradle sync 会因 jcenter / AGP 版本不兼容报错。

### Linux 系统安装（cmake install，供 .deb / .rpm 打包者）

```bash
cd build/linux/x64/release
cmake --install . --prefix /usr
# 安装内容：
#   /usr/bin/riden_power_supply
#   /usr/lib/...                          (bundle/lib 内容)
#   /usr/share/.../flutter_assets/         (bundle/data 内容)
#   /usr/share/applications/io.github.beilusm.ridenps.desktop
#   /usr/share/icons/hicolor/*/apps/io.github.beilusm.ridenps.png
#   /usr/share/metainfo/io.github.beilusm.ridenps.metainfo.xml
```

应用 ID：`io.github.beilusm.ridenps`（Freedesktop reverse-DNS）。

## 版本来源管理

5 处版本来源需保持一致，每次发版同步：

| # | 文件 | 位置 | 校验 |
|---|------|------|------|
| S1 | `pubspec.yaml` | `version: x.x.x+N` | CI 校验 (主来源) |
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

## AI 协作文档

- **[CLAUDE.md](../CLAUDE.md)** — 项目铁律 / 架构约束 / 修改禁令 / Phase 历史
- **[docs/SESSION_HANDOFF.md](SESSION_HANDOFF.md)** — 跨会话状态交接 / 当前 patch 状态 / Phase 实施记录
- **[docs/PHASE_4_ANDROID.md](PHASE_4_ANDROID.md)** — Android 平台移植设计与实施
- **[docs/PHASE_5_SLOT_EDIT.md](PHASE_5_SLOT_EDIT.md)** — Memory Slot 数据组编辑设计与实施

## 测试

```bash
fvm flutter analyze    # 静态分析（基线 21 issues，预存 Among prior phases）
fvm flutter test       # 单元测试（98 PASS，含 7 个 Phase 5 saveSlotValues 测试）
```

## 许可证

MIT License — 见仓库源文件头注释。
