# CLAUDE.md — RIDEN Power Supply 项目铁律

RIDEN 数控电源 Flutter 上位机（Linux + Windows + Android）。通过 CH340 USB-Serial (Modbus RTU, 115200-8-N-1, addr=0x01) 与 RIDEN 数控电源通信，实时显示 V/A/W 波形、设定参数、保护状态、预设管理。

架构与开发指南见 `docs/ARCHITECTURE.md`；终端用户文档见 `README.md`。

## 通信层 / 业务逻辑铁律

- **不在 UI isolate 调用 SerialPort FFI**（同步 `libserialport`）。所有串口 I/O 在 worker isolate 执行；UI 只通过 `SendPort`/`ReceivePort` 发命令、收结果。Android `usb_serial` platform channel 是例外（async 非 blocking，不持有同步 fd 句柄）
- **不改三个数值**: `_accumulateRead` 250ms 总 budget / FAST 150ms / SLOW 1000ms。(<200ms 会丢慢响应；<120ms 会 timeout；改小任何一个会破坏设备响应能力)
- **不删除 `_drainPort(80ms)`** — 它只在 `_accumulateRead` 超时时调用排空迟到残留字节，是异常恢复路径
- **不改 `ModbusScheduler` / `modbus_task.dart`** — scheduler 算法（priority/aging/dedup/state/Completer）已稳定
- **`modbus_worker.dart` 仅允许 P0/P1 稳定性修复** — 含通信协议和 IO，破坏代价高
- **不改 dedup key 格式** — `dedupKey="fast"` (FAST) / `dedupKey="slot_M0".."slot_M9"` (SLOT); 改格式会让 slot 扫描互相覆盖
- **不移除 `_current` merge 缓存** — SLOW poll 会覆盖 FAST 数据
- **不改 `RegisterDefinition` / `register_conflicts`** — datasheet 确认的寄存器 schema
- **不改 `quickSwitch` / `PowerSupplyData` 数据模型** — UI 全部走 `quickSwitch()`，旧 `loadSlot()` / `loadMemorySlot()` 标 `@Deprecated` 仅供回退测试，不重新启用
- **不重构架构，不删除硬编码寄存器，不改 FAST 为动态读取**，不根据变量名猜协议

## 发布工程铁律

- **不引入 `linuxdeploy` / `linuxdeploy-plugin-gtk`** — plugin-gtk 的 AppRun hook 强制 `GDK_BACKEND=x11` 和 `GTK_THEME`，会破坏 HiDPI 显示器 2x 缩放（GL frame size 从 2712×1616 退到 1346×1616）
- **不在 `AppRun` 设 `GDK_BACKEND` / `GTK_THEME` / `GTK_PATH` 等环境变量** — AppRun 仅 9 行，保留用户系统 HiDPI 主题 / font-scaling-factor
- **不改 `make_appimage.sh` 的 Stage 4 (AppRun 写入)** — 任何 GTK 环境变量注入会导致 HiDPI 回归
- **`env*.sh` 一致性铁律**: `packaging/config/env.sh` / `env_windows.sh` / `env_android.sh` 的 `APP_ID` / `APP_VERSION` 必须与 `pubspec.yaml` `version:` 同步；改一处要同步改另三处
- **不把 `release/` / `packaging/tools/` / `*.AppImage` / ZIP / SHA256SUMS 入库** — 已 `.gitignore` 排除，是构建产物
- **v1.0 不引入 Inno Setup / NSIS / MSIX / 代码签名 / zsync / `--updateinformation` / GPG 签名 / 多 distro 自动测试**
- **Windows Release 必须在 Windows 主机执行** — Linux 无法 `flutter build windows`（需 MSVC + Windows SDK）
- **不改 `windows/runner/runner.exe.manifest`** — `PerMonitorV2` DPI + Win10/11 supportedOS 已正确
- **不改 `windows/CMakeLists.txt` / `windows/runner/CMakeLists.txt` 安装规则** — Flutter 默认模板自包含 bundle 已可用
- **`windows/runner/Runner.rc` 仅允许修改 4 个字符串字段** — `CompanyName` / `FileDescription` / `LegalCopyright` / `ProductName`；其他字段由 Flutter 工具链自动注入

## 版本来源管理铁律

6 处硬编码版本来源（见 `docs/ARCHITECTURE.md` 表格）：S1 pubspec + S2/S3/S6 env*.sh 发版手工改；S4 Runner.rc + S5 metainfo.xml 由 Flutter 工具链 / CI 自动注入，不手动改。

- **不创建 `sync_versions.sh` 自动同步脚本** — 六来源手工同步足够
- **不自动修改 `Runner.rc`** — 二进制 .rc 资源 sed 改易破坏 MSVC 编译
- **不改 `env*.sh` / `metainfo.xml` 仓库文件本身** — CI 只校验 (S2/S3/S6) 或只改 workspace 副本 (S5)，不 commit 不 push
- **不扩展 dev CI**（`windows-build.yml` / `linux-build.yml`）— 版本校验只在 tag 触发的 release workflow 生效
- **不改本地打包脚本**（`packaging/scripts/*.sh` / `make_appimage.sh`）— metainfo 注入由 CI workflow 内联 step 完成

## Phase 4 Android override 范围（已 APPLIED）

仅以下文件允许 Android 平台分支，其他铁律全部保留：

- `modbus_worker.dart` driver 层（connect/disconnect/read/write/enumerate `Platform.isAndroid` 分支；Android 不 spawn worker）
- `serial_port_enumerator.dart`（`UsbSerial.listDevices()` Android 入口，绕 `Isolate.run`）
- `lib/main.dart` 平台守卫（`if (!Platform.isAndroid) windowManager.*` + `SystemUiMode.immersiveSticky`）
- `lib/app.dart` UI 触屏适配
- **新增** `lib/services/serial_backend.dart` / `lib/services/direct_android_modbus_service.dart` (Android UI-isolate-only usb_serial 路径 — Flutter 3.44 worker isolate 跑不了 `usb_serial` 的 MethodChannel/EventChannel reply)

`MockModbusService` 抽象接口 / `serial_modbus_service.dart` / `mock_modbus_service.dart` / `serial_port_scanner.dart` 全部不动。

## 通用铁律

- **不主动提交 git**，除非用户明确要求
- **不新增业务功能** — 当前阶段只做稳定性修复；**发布工程 / Android 移植 / 已授权的 Phase 范围除外**
- **任何代码修改完成后必须运行 `fvm flutter analyze` 验证 0 新 issue**（baseline 21 issues 全部 pre-existing）
- **不删除已发版的 Phase 设计文档变更叙述** — git log + commit message 是更权威档案，文档只放当前活跃信息

## 当前活跃 OPEN 项

| 优先级 | 项 | 位置 | 说明 |
|---|---|---|---|
| medium | **P1-1 `_onPollMiss` 死代码** | `lib/providers/power_supply_provider.dart:~599` | `_consecutiveFails` 永远=0 → `CommStatus.error` 永不达到，UI 健康检查仅升级到 `timeout`。修复建议：FAST/SLOW poll miss 路径接入 `_onPollMiss()` 调用 |
| medium | **setOVP/setOCP 写入路径仍指向 HR82/HR83** | `serial_modbus_service.dart` | active≠0 时改不到 active slot OVP/OCP。需 datasheet 硬件写入语义验证 (Phase B.3 候选) |
| low | **Phase 4.1 Android share/export 二次入口** | `lib/widgets/recording_panel.dart` | 录制完成后加 "Share / Open with CSV viewer" 按钮，调用 `share_intent` 或 `ACTION_VIEW` |
| low | **v1.1.2 fork `usb_serial` git dep** | `pubspec.yaml` | 消除 `packaging/scripts/patch_pub_cache_android.sh` 4 处手工 pub-cache patch |
| low | **Phase B.5 旧路径残留 audit** | `lib/providers/` `lib/services/` | grep `loadSlot(` `loadMemorySlot(` 确认无内部调用后真删除 `@Deprecated` 实现 |
| low | **quickSwitch 延迟优化** | `lib/providers/power_supply_provider.dart` `quickSwitch()` | 当前固定 `await 600ms` → 改 200ms × 5 次短轮询检测 HR8 变化 |
