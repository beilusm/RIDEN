# RIDEN

使用 Compose Multiplatform 的 RIDEN 数控电源上位机，共享 Kotlin 通信核心与 Material 3 界面，目标平台为 Linux、Windows 和 Android。

当前版本 **2.0.0-1**。[下载发布包](https://github.com/beilusm/RIDEN/releases/latest)。新版本按 `2.0.1` 递增，同版补丁使用 `2.0.0-1` 后缀；版本来源与发布流程见 [发布说明](docs/RELEASING.md)。

Flutter 旧版完整保存在分支 `legacy/flutter`（`7baebf8`）。当前重构的验收进度见 [迁移记录](docs/MIGRATION.md)。

## 功能

- 电压、电流、功率实时显示，150 ms 轮询、300 点波形历史；分图刻度、实际时间轴、最小/最大/平均值、悬停读数及触摸选点，支持暂停、缩放和自动量程。
- 电压、电流、OVP、OCP 参数编辑；设定下方直接选择、载入及编辑 M1-M9 预设。
- 按型号区分设定与保护上限及寄存器精度，识别 60067 衍生型号；能力表和待核对项见 [型号能力](docs/DEVICE_CAPABILITIES.md)。
- 输入电压、温度、CV/CC、保护状态、累计容量与能量。
- CH340 USB 串口自动发现、重连，手动选择端口、波特率和 Modbus 地址。
- CSV 逐点录制、121 个寄存器查看、受控写入与 CSV 导出。
- 桌面悬浮监控、中性灰明暗主题与独立 V/A/W 数据色；Android 12+ Material You 动态配色。桌面默认使用固定配色。
- PC 使用左侧导航与紧凑顶栏；手机窄屏底部导航，横屏/平板按宽度切换侧边导航。

## 开发运行

需要 JDK 17；Android 构建另需 Android SDK 35。Gradle Wrapper 固定版本，无需安装系统 Gradle。

```bash
./gradlew :composeApp:run
./gradlew :composeApp:run --args="--demo"
./gradlew :composeApp:desktopTest

# Android
export ANDROID_HOME="$HOME/Android/Sdk"
./gradlew :composeApp:assembleDebug
adb install -r composeApp/build/outputs/apk/debug/composeApp-debug.apk

# 自带运行时的桌面应用目录
./gradlew :composeApp:createDistributable
# 按主机平台生成 deb/rpm/msi/dmg
./gradlew :composeApp:packageDistributionForCurrentOS
# Linux AppImage（另需 appimagetool）
bash packaging/scripts/make_appimage.sh
```

桌面构建产物位于 `composeApp/build/compose/binaries/`。Windows 安装包必须在 Windows 构建。
Linux deb/rpm 打包需要对应的 `dpkg-deb` / `rpmbuild` 工具；AppImage 位于 `release/`，包含 Java 运行时。
Android Release APK 必须配置发布签名；本机私有签名和 GitHub Actions secrets 的配置方式见 [发布说明](docs/RELEASING.md)。发布 APK 可直接安装，早期 2.0 Debug 版需导出数据、卸载后再安装发布版。
无显示服务的 CI 可用 `-PskipUiTests=true` 只运行核心测试；界面测试会输出 `composeApp/build/screenshots/`。
Android 无硬件演示可用 `adb shell am start -n io.github.beilusm.ridenps/.MainActivity --ez demo true`。

## 连接硬件

默认通信：`115200 · 8N1 · Modbus RTU · address 1`。打开连接页可修改。
自动连接优先识别 WCH（VID `1a86`）设备；手动断开会关闭自动连接。

Linux 串口权限：

```bash
sudo cp linux/udev/99-riden-ch34x.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=tty
```

也可加入发行版的串口用户组（通常是 `dialout` 或 `uucp`），重新登录后生效。
Windows 需要 CH340 驱动；Android 需要 OTG，首次连接授权 USB 访问。

M0 是设备上电默认组，写入 HR19=0 不会重新载入，因此仅提供 M1-M9 切换。
保护值使用活动预设的存储地址 `80 + HR19 * 4 + 2/3`，操作后回读。
寄存器表中未知地址只能查看，所有写入经过类型、范围和精度校验。

## 数据录制

桌面开始录制时选择文件，采样期间增量写入；停止时排空缓冲并关闭文件。
Android 先写应用私有临时文件，停止时使用系统文件选择器导出，取消导出会保留私有文件。
CSV 列保留旧版名称，时间使用本地 ISO-8601 格式，电流保留设备的毫安精度。

架构和实现约束见 [开发指南](docs/ARCHITECTURE.md) 与 [CLAUDE.md](CLAUDE.md)。
