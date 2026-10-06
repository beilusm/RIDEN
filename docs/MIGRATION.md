# Compose Multiplatform migration

目标：用 Compose Multiplatform 和 Material 3 重建现有 Linux、Windows、Android 功能，并重新实现调度器。

## 旧版本

分支 `legacy/flutter` 固定在 `7baebf8`，保存完整 Flutter 源码、测试和发布脚本。
未提交的 `labview/` 是已有用户文件，不属于迁移代码。
用户已授权将当前版本定为 `2.0.0`，提交、推送并通过 GitHub Actions 编译 Windows 及发布三平台产物。

## 功能对应

| 旧功能 | 新实现 |
| --- | --- |
| USB 串口 Linux / Windows | `DesktopTransport` / jSerialComm |
| Android OTG / USB 权限 | `AndroidTransport` / usb-serial-for-android |
| 自动连接、拔插检测、手动断开 | `PowerController` 1 秒枚举；手动断开关闭自动连接 |
| 参数及保护值编辑 | 物理量校验、步进输入、写后回读；OVP/OCP 指向活动预设 |
| M1-M9 预设载入与编辑 | 控制台设定下方选择、载入及编辑；HR19 硬件切换，600 ms 后整表回读；4 个字段串行写入 |
| 保护、CV/CC、温度、容量与能量 | 合并寄存器缓存驱动 UI |
| 150 ms 波形、300 点历史 | Canvas 曲线、V/A/W 开关、暂停、缩放、历史滑块 |
| CSV 录制 | FAST 业务快照逐点写入，停止排空；Android 私有临时文件 + SAF |
| 121 个寄存器查看、写入、导出 | 共享 schema；500 ms 自动刷新、暂停、搜索和写入校验 |
| 桌面悬浮监控 | 透明置顶窗口、拖动/缩放锁定、V/A/W 与趋势开关、透明度、恢复主窗 |
| Material You | Material 3 控件、明暗主题，Android 12+ 动态配色 |

## 验收状态

2026-10-07 Windows 补丁 `2.0.0-1`：用户报告主窗口最大化/全屏时桌面闪烁，以及 MSI 安装后快捷方式缺失。Windows 启动默认改为软件渲染并禁用 Java2D Direct3D；MSI 现有两项快捷方式改为无条件安装。已通过本地 37 项测试，Windows 专用窗口测试在 Linux 跳过。[三平台 CI 37501703130](https://github.com/beilusm/RIDEN/actions/runs/37501703130) 通过；Windows 实际窗口的最大化、全屏、恢复画面非空且使用软件渲染，截图已检查。MSI 实际新装、删除快捷方式后修复、卸载清理、从缺少快捷方式的 2.0.0 升级检查均通过，桌面和开始菜单 `.lnk` 正确指向安装后的 `RIDEN.exe`。受影响 Windows 主机仍需回归确认。

2026-10-07：按用户要求完成软件移植和 2.0.0 发布准备，真机串口和物理 Windows 主机验收延后。

已通过：

- 37 项测试：调度器 5、协议 7、型号能力 5、控制器 9、波形计算与格式 3、界面 8，零失败。
- 调度优先级、FIFO、老化、读取去重、任务过期、关闭结算与错误后继续处理。
- CRC 向量、损坏帧/错误地址、异常短帧、分片响应、写回显和寄存器写入限制。
- 演示连接、输出切换、M2 切换及活动组保护值、300 点历史、重连、逐点 CSV、录制失败与断连清理；文件选择未完成时，轮询和输出命令继续执行。
- 型号能力、设定与保护独立上限、衍生 ID、RD6006P 精度、6012 电流缩放、未知型号只读、预设载入前校验；覆盖控制器和界面。各型号能力来源及未核对配置见 `docs/DEVICE_CAPABILITIES.md`。
- 波形按 V/A/W 分图显示，独立刻度及最小/最大/平均值；X 轴使用真实时间间隔。桌面悬停、手机选点和拖动同步三项读数，选点暂停后数据保持不变，返回实时使用最新数据。截图 `chart-desktop-selected.png`、`chart-mobile-selected.png`。
- 1120×820 桌面、680×820 窄桌面、360×800 手机、960×540 横屏及悬浮监控界面测试；桌面始终使用侧边导航，手机窄屏保留底部导航。预设整合到控制台设定下方，桌面 M2 与窄屏 M9 选择、载入通过演示测试。深浅主题截图位于 `composeApp/build/screenshots/`。
- Android Debug 和发布签名 Release APK 构建；签名 v1/v2 校验通过，versionName 为 `2.0.0`。Android lint 零错误。
- Android 手机演示启动、输出及曲线显示、SAF 导出。实际导出的 CSV 包含 383 个采样点，行数为 384（含表头）。取消第二次导出后，661 点录制保留在应用私有文件中。
- Linux 自带 Java 运行时的应用目录和 AppImage 构建；桌面演示运行、透明悬浮监控、原生缩放、锁定和恢复主窗。
- 最终 AppImage 的桌面文件选择和 CSV 录制验证通过：172 个采样点、173 行（含表头），文件保存在 `composeApp/build/screenshots/linux-demo.csv`。文件选择期间轮询继续运行。
- Flutter 源码、旧测试和旧发布流程已退出当前工作树；完整版本由 `legacy/flutter` 保存。新 Android/Linux/Windows 构建工作流已配置。
- GitHub Actions 三平台干净环境构建通过：[运行 37495763267](https://github.com/beilusm/RIDEN/actions/runs/37495763267)。Linux 完成 37 项测试及 DEB 构建，Windows 完成核心测试、自带运行时应用目录、ZIP 和 MSI 构建，Android 完成 Debug 构建及 lint。已下载检查 Windows ZIP 的 `RIDEN.exe`、Java 运行时及 Windows 原生依赖。

环境限制及延后验收：

- 没有 RIDEN / CH340 接入，USB 权限、拔插、预设与保护值写入、长时间通信仍需设备回归。演示及协议测试不等同于硬件验证。
- Windows 串口和物理主机运行尚未验收；编译打包已在 GitHub Actions Windows runner 完成。
- 本机缺少 `dpkg-deb` / `rpmbuild`；DEB 已在 GitHub Actions 构建，RPM 不在此次发布资产中。
- Hyprland 默认平铺监控窗口，测试时手动切为浮动。使用平铺窗口管理器时，应为 `RIDEN · Monitor` 配置浮动规则。
- Android 发布签名已配置为本机私有文件及 GitHub 加密 Secrets；当前 Android 手机 ADB 已离线，最新发布构建未再次安装。

发布编号和签名配置见 `docs/RELEASING.md`。已有未跟踪的 `labview/` 未修改。
