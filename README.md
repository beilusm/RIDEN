# RIDEN Digital Power Supply — Flutter Desktop上位机

RIDEN 数控可调电源的跨平台桌面控制软件。通过 CH340 USB-Serial 与设备通信（Modbus RTU），提供实时波形显示、参数设定、预设管理和保护状态监控。

> **架构、通信参数、设计约束、修改禁令见 [CLAUDE.md](./CLAUDE.md)。**

## 硬件要求

- RIDEN 数控电源（Modbus RTU 地址 0x01）
- CH340 USB-Serial 转换器（`1a86:7523`）
- 通信参数：115200 baud / 8 data bits / no parity / 1 stop bit

## 软件依赖

- [Flutter](https://docs.flutter.dev/get-started/install) 3.44+
- [FVM](https://fvm.app/)（推荐版本管理）
- Linux: `libserialport-dev`
- macOS: `libserialport` (`brew install libserialport`)
- Windows: 无需额外依赖（`flutter_libserialport` 自带 DLL）

## 快速启动

```bash
# 安装依赖
fvm flutter pub get

# 连接设备后启动（自动检测串口）
fvm flutter run -d linux      # Linux
fvm flutter run -d windows    # Windows
fvm flutter run -d macos      # macOS
```

串口自动检测：Linux (`/dev/ttyUSB*`/`ttyACM*`)、macOS (`cu.usbserial*`/`cu.usbmodem*`)、Windows (`COM*`)。也可通过 `connect(port: 'COM3')` 手动指定。

## Linux 串口权限（CH340 / CH341）

Linux 默认 USB 串口设备（`/dev/ttyUSB*`）属 `dialout` 组，普通用户无读写权限。若应用启动时报 `Permission denied` 或 `Failed to open /dev/ttyUSBx`，使用以下方法之一：

### 方法 A：安装 udev 规则（推荐，永久生效）

仓库提供 `linux/udev/99-riden-ch34x.rules`，给 CH340/CH341 适配器授予 `0666` 权限并屏蔽 ModemManager，同时创建稳定 symlink `/dev/riden_serial`：

```bash
sudo cp linux/udev/99-riden-ch34x.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add \
    --subsystem-match=tty --attr-match=idVendor=1a86
# 拔插一次 CH340 适配器，或重启
```

生效后设备会同时显示为 `/dev/ttyUSB<x>` 和 `/dev/riden_serial`，无需 sudo 即可读写。

### 方法 B：加入 dialout 组（手动）

不同发行版组名不一致：

| 发行版 | 组名 |
|---|---|
| Debian / Ubuntu / Arch | `dialout` |
| openSUSE / BSD | `uucp` |
| RHEL / Fedora | `tty`（或 `dialout`） |

```bash
sudo usermod -aG dialout $USER
# 注销重新登录后生效
```

### 方法 C：临时 chmod（一次性）

```bash
sudo chmod 0666 /dev/ttyUSB0
```

设备拔插后失效，仅用于快速测试。

## 构建 Release Bundle（Linux）

```bash
fvm flutter build linux --release
# 产物位于 build/linux/x64/release/bundle/
#   riden_power_supply             可执行文件
#   data/flutter_assets/           Flutter 资源
#   data/icudtl.dat                ICU 数据
#   lib/                           Flutter engine + plugin .so + libserialport.so
```

Bundle 自包含（25 MB），RPATH=`$ORIGIN/lib`，可整体复制到任意路径独立运行，不依赖 Flutter SDK 或系统 libserialport。系统需提供 GTK3 / GLib / GIO。

## 发布工程（AppImage 打包）

`packaging/` 目录提供本地一条命令生成可分发 AppImage：

```bash
# 前置：装一次 appimagetool（系统包管理器，不入仓库）
# Arch:        sudo pacman -S appimagetool-bin
# Ubuntu:      sudo apt install appimagetool
# 其他:        见 https://github.com/AppImage/appimagetool/releases

# 一条命令发布
./packaging/scripts/build_release.sh
```

执行四阶段流水线：
1. `fetch_tools.sh` — 下载 `packaging/tools/runtime-x86_64`（923KB，type2-runtime）
2. `fvm flutter build linux --release`
3. `make_appimage.sh` — 手工组装 AppDir + `appimagetool --runtime-file`
4. `compute_checksums.sh` — 生成 `SHA256SUMS` + `RELEASE_NOTES-1.0.0.md`

最终产物在 `release/`（已 gitignored）：

```
RIDEN_PowerSupply-1.0.0-x86_64.AppImage   9.9 MB  单文件可分发
SHA256SUMS                                106 B
RELEASE_NOTES-1.0.0.md                    1.3 KB  从 metainfo 自动抽取
```

### 设计要点

- **不使用 linuxdeploy / linuxdeploy-plugin-gtk**：plugin-gtk 的 AppRun hook 强制 `GDK_BACKEND=x11` 和 `GTK_THEME`，会破坏用户系统的 HiDPI 缩放设置。
- **AppRun 仅 9 行**：不设任何 GTK 环境变量；依赖系统 GTK3（所有 Linux 桌面发行版自带），保留用户 HiDPI 主题 / font-scaling-factor 设置。
- **调试模式**：`./packaging/scripts/build_release.sh --skip-build` 跳过 `flutter build`，复用现有 bundle 用于快速验证打包脚本。

## Windows Release 构建（ZIP 打包）

### 前置依赖（开发机，仅构建时）

- Windows 10 / 11
- [Visual Studio 2022](https://visualstudio.microsoft.com/) 含 **使用 C++ 的桌面开发** 工作负载（含 MSVC + Windows 10/11 SDK）
- [Flutter](https://docs.flutter.dev/get-started/install/windows) 3.44+
- [FVM](https://fvm.app/)（推荐）
- [Python 3](https://www.python.org/downloads/windows/)（Flutter Windows 插件构建需要，且打包脚本依赖）
- Git Bash 或 WSL（运行 `packaging/scripts/` 的 bash 脚本）

### 一条命令发布

在 Windows 主机的 Git Bash / WSL 中：

```bash
fvm flutter pub get
bash packaging/scripts/build_windows_release.sh
```

执行两阶段流水线：

1. `fvm flutter build windows --release` — 产物到 `build/windows/x64/runner/Release/`
2. `make_windows_zip.sh` — 打包为 `RIDEN_PowerSupply-1.0.0-windows-x64.zip`（含 `MANIFEST.txt` 文件清单）+ `SHA256SUMS-windows.txt`

最终产物在 `release/`（已 gitignored）：

```
RIDEN_PowerSupply-1.0.0-windows-x64.zip    ~15 MB   解压即用，无需安装
SHA256SUMS-windows.txt                     74 B     zip 的 SHA256
```

仅调试打包脚本本身（跳过 flutter build）：`bash packaging/scripts/build_windows_release.sh --skip-build`。

### 用户使用说明（运行时）

- **首次插入 CH340 设备**：Windows 10/11 会自动通过 Windows Update 下载并安装 CH340 / CH341 驱动（需联网），出现 `COMx` 端口后即可正常使用。
- **未签名 exe 警告**：v1.0 的 `riden_power_supply.exe` 未做代码签名，Windows SmartScreen 首次启动可能显示 "Windows 已保护你的电脑"。点击 **更多信息 → 仍要运行** 即可。这是未签名应用的正常行为，v1.1+ 将申请代码签名证书消除该警告。
- **VC++ Runtime**：Flutter 官方 `flutter_windows.dll` 已静态链接 CRT，但项目编译的 `riden_power_supply.exe` 与 3 个插件 DLL 默认动态链接 CRT，**需要 VC++ Redistributable x64 (2015-2022)**。Windows 10/11 多数已预装（Office / Visual Studio / 常见 C++ 软件均附带）；若干净系统启动报错"找不到 VCRUNTIME140.dll"或"找不到 MSVCP140.dll"，请从 [Microsoft 官网](https://aka.ms/vs/17/release/vc_redist.x64.exe) 下载安装 `vc_redist.x64.exe`（约 14 MB，一次性）。`ucrtbase.dll` 由 Windows 10/11 Universal CRT 自带，无需 Redist。

## Linux 系统安装（cmake install）

供打包者（.deb / .rpm / AppImage 下游打包脚本）使用：

```bash
cd build/linux/x64/release
cmake --install . --prefix /usr
# 安装内容：
#   /usr/bin/riden_power_supply
#   /usr/lib/...                     (bundle/lib 内容)
#   /usr/share/.../flutter_assets/    (bundle/data 内容)
#   /usr/share/applications/io.github.beilusm.ridenps.desktop
#   /usr/share/icons/hicolor/*/apps/io.github.beilusm.ridenps.png
#   /usr/share/metainfo/io.github.beilusm.ridenps.metainfo.xml
```

应用 ID：`io.github.beilusm.ridenps`（Freedesktop reverse-DNS）。

## 项目结构

```
lib/
├── main.dart                         # 入口，Provider 注入
├── app.dart                          # MaterialApp + 响应式布局
├── theme/app_theme.dart              # 统一暗色主题
├── models/power_supply_data.dart     # 不可变数据模型 (PowerSupplyData)
├── providers/power_supply_provider.dart # 状态管理 (ChangeNotifier)
├── services/
│   ├── modbus_service.dart           # ModbusService 抽象接口
│   ├── modbus_task.dart              # ModbusTask 数据模型（优先级/aging/dedup）
│   ├── modbus_scheduler.dart          # 统一任务调度器（串行执行）
│   ├── modbus_worker.dart            # Modbus Isolate 入口 + WorkerCore + Handle
│   ├── serial_modbus_service.dart    # UI侧 proxy，转发到 worker isolate
│   └── mock_modbus_service.dart      # 开发用 mock，无需硬件
└── widgets/
    ├── power_chart.dart              # 实时双Y轴波形图 (fl_chart)
    ├── dashboard_panel.dart          # 右侧面板容器
    ├── measurement_display.dart      # V / A / W 数值显示
    ├── setpoint_panel.dart           # 设定值编辑 + Preset (M0-M9)
    ├── status_bar.dart               # 通信状态 + 能耗 / 温度 / Vin
    ├── serial_panel.dart             # 串口设置卡片 (port/baud/addr + CONNECT)
    ├── register_page.dart            # Schema 驱动寄存器表格 UI
    └── register_view.dart           # (遗留) 全页寄存器调试视图
```

## 使用 Mock 模式（无需硬件）

在 `main.dart` 中替换 service 注入：

```dart
create: (_) => PowerSupplyProvider(MockModbusService()),
```

## 调试

唯一保留的 verbose switch：

```dart
// modbus_scheduler.dart:12
static const _verboseLog = false;  // set true for per-task SCHED logs

// 生产统计 (每2秒)
[SCHED_STAT] complete=12 data_rate=6.0/s isolate=alive
```

## 许可证

MIT
