# RIDEN Power Supply

> 跨平台桌面/移动端上位机，通过 CH340 USB-Serial 与 RIDEN 数控电源通信，提供实时波形、参数设定、预设管理与保护监控。

支持 **Linux**、**Windows**、**Android** 三平台，同一份代码、同一套功能。

## 功能

- ⚡ **实时波形** — V / A / W 滚动曲线（150ms 刷新）
- 🎛️ **参数设定** — 电压 / 电流 / OVP / OCP 步进编辑
- 📌 **预设管理** — M1-M9 共 9 组数据组，快速切换 / 编辑
- 🛡️ **保护监控** — OVP / OCP / OTP 状态实时显示
- 📼 **数据录制** — CSV 逐点落盘，与波形 1:1 对应
- 🔌 **自动连接** — 拔插 USB 电缆自识别、自重连
- 📊 **300 点历史** — 滚动累积，可滚动查看近期趋势

## 下载安装

前往 [ Releases 页面](https://github.com/beilusm/RIDEN/releases) 下载最新版本对应平台包：

| 平台 | 文件 | 安装方式 |
|---|---|---|
| 🐧 **Linux** | `RIDEN_PowerSupply-x.x.x-linux-x86_64.AppImage` | `chmod +x` 后直接双击运行 |
| 🪟 **Windows** | `RIDEN_PowerSupply-x.x.x-windows-x64.zip` | 解压后双击 `riden_power_supply.exe` |
| 📱 **Android** | `RIDEN_PowerSupply-x.x.x-android-arm64-v8a.apk` | 允许"未知来源"后点击安装 |

> 下载后建议用 `SHA256SUMS-*.txt` 校验文件完整性。

## 硬件要求

- RIDEN 系列数控电源（Modbus RTU 地址 `0x01`）
- CH340 USB-Serial 转换器（USB VID `1a86` / PID `7523`）
- 通信参数：`115200 baud · 8 data bits · no parity · 1 stop bit`

## 系统要求

| 平台 | 系统 | 备注 |
|---|---|---|
| Linux | Ubuntu 20.04+ / Fedora 32+ / Mint 20+ | glibc ≥ 2.31，AppImage 自包含 GTK |
| Windows | Windows 10 / 11 x64 | 需 [VC++ Redistributable x64](https://aka.ms/vs/17/release/vc_redist.x64.exe)（多数系统已预装） |
| Android | Android 5.0+ (API 21+) | arm64-v8a 架构 |

## 常见问题

<details>
<summary><b>Linux 启动报 "Permission denied /dev/ttyUSBx"</b></summary>

USB 串口默认属 `dialout` 组，普通用户无权限。两种解决方法任选其一：

**方法 A：安装 udev 规则（推荐，永久生效）**

```bash
sudo cp linux/udev/99-riden-ch34x.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=tty --attr-match=idVendor=1a86
# 拔插一次 CH340 适配器或重启
```

**方法 B：加入 dialout 组**

```bash
# Arch / Debian / Ubuntu:  dialout
# Fedora / RHEL:           dialout  (或 tty)
# openSUSE / BSD:           uucp
sudo usermod -aG dialout $USER
# 注销重新登录后生效
```

</details>

<details>
<summary><b>Windows 首次插入 CH340 后未识别</b></summary>

Windows 10 / 11 通常会通过 Windows Update 自动安装 CH340 / CH341 驱动，需联网等待 1-2 分钟。如仍未出现 `COMx` 端口，从 [WCH 官网](http://www.wch.cn/downloads/CH341SER_EXE.html) 手动下载驱动安装。

</details>

<details>
<summary><b>Windows 启动报 "找不到 VCRUNTIME140.dll"</b></summary>

下载安装 [VC++ Redistributable x64](https://aka.ms/vs/17/release/vc_redist.x64.exe)（约 14 MB，一次性安装）。

</details>

<details>
<summary><b>Windows SmartScreen 显示 "已保护你的电脑"</b></summary>

应用未做代码签名，首次启动会显示该警告。点击 **更多信息 → 仍要运行** 即可。后续版本将申请代码签名证书消除该警告。

</details>

<details>
<summary><b>Android 连接 RIDEN 电源后没反应</b></summary>

确认手机 OTG 功能可用且 OTG 线支持数据传输（部分充电线无数据引脚）。应用需要 USB HOST 权限，首次插入 CH340 系统会弹"打开 RIDEN_PowerSupply"prompt，允许后自动连接。

</details>

## 使用

启动应用后插入 CH340 OTG 线连接 RIDEN 电源，应用会自动识别并连接。主面板包含：

- **顶部** — 通信状态 / 输入电压 / 设备温度 / 固件版本
- **中部** — V / A / W 大字号实时读数 + 输出开关
- **SETTINGS** — 电压 / 电流 / OVP / OCP 设定（点击编辑）
- **PRESET M$x$** — M1-M9 预设选择（点击切换 / 编辑）
- ** SERIAL** — 串口状态 + 手动连接 / 断开
- **RECORDING** — CSV 数据录制开始 / 停止
- **底部** — 实时波形图（V / A 双 Y 轴滚动 300 点）

## 开发者文档

如果你是开发者或想从源码构建打包，请参见 [**开发者文档**](docs/DEVELOPMENT.md)。

## 许可证

MIT License — 见仓库源文件头注释。
