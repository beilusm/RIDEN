# Phase 4 — Android Platform Migration Design Doc

> **Status**: **APPLIED** (v1.1.0 released 2026-07-25)
> **Spike**: PASS (2026-07-25 真机验证 — 见 §2)
> **实施提交链**: `db0c67a` → `e51428c` → `46228f0` → `1ce417c` → `b4b97e5` → `f56df04` → `14b01c0`
> **真机验收**: PASS (V/A/W 波形 + quickSwitch M2 + USB watcher 拔插自连 + Recording CSV STOP 弹系统文件选择器选保存位置)
> **Override scope (实施版)**: `modbus_worker.dart` driver 层 + `serial_port_enumerator.dart` + `lib/main.dart` 平台守卫 + `lib/app.dart` UI 触屏适配 + **新增** `serial_backend.dart` / `direct_android_modbus_service.dart` (UI-isolate-only)
> **铁律保留**: ModbusScheduler / `modbus_task.dart` / `_accumulateRead` 250ms / FAST 150ms / SLOW 1000ms / quickSwitch / `RegisterDefinition` / `register_conflicts` / `modbus_service.dart` 抽象接口 / `serial_port_scanner.dart` / `serial_modbus_service.dart` / `mock_modbus_service.dart` — **全部不动**

---

## 实施变更摘要（设计中未预见，实施时新增）

1. **`DirectAndroidModbusService` (UI-isolate-only)**（commit `b4b97e5`）— Flutter 3.44 `BackgroundIsolateBinaryMessenger` 无法在 worker isolate 跑 usb_serial 的 MethodChannel + EventChannel reply（`platform_message_response_dart_port.cc:53 Check failed: did_send` FATAL abort）。故 Android 不用 worker isolate，改在 UI isolate 直接跑 usb_serial（platform channel async 非 blocking，不违反"UI 不直接访问 SerialPort"铁律本意，该铁律针对同步 FFI 如 libserialport）。详见 SESSION_HANDOFF.md §Phase 4。
2. **`SystemUiMode.immersiveSticky`**（commit `f56df04`）— §8 原计划 `edgeToEdge` 让内容延伸状态栏底层只让状态栏透明覆盖，但实际真机显示时间/电池图标仍一直可见违反用户期望。改用 `immersiveSticky` 彻底隐藏，边缘向内滑临时唤出。
3. **Recording CSV Android 路径 SAF export**（commit `14b01c0`）— 用户要求"必须用 file_picker 弹系统文件选择器选保存位置"。Android SAF 是 one-shot bytes-only，不支持 IOSink 流式写入；故 Android 流程改为：START 写 app-private tmp → STOP 读 bytes → `FilePicker.saveFile(bytes:)` 弹 SAF 选位置 → 落盘 → 删 tmp。Desktop 路径保持 Phase E 原行为不变。
4. **device_filter.xml PID 修正**（commit `1ce417c`）— 设计阶段写 `product-id="29723"` (= 0x741B) 是转录错误；正确 CH340 PID 为 `0x7523` = decimal 29987。
5. **AndroidManifest orientation 实际锁 portraitUp** — §8 原计划锁 landscapeLeft/landscapeRight，但真机验证发现 portrait 模式触屏操作更稳，加上 USB OTG 接线方向与手机握持更自然，用户实际使用 portrait。`main.dart` 仍注册三种方向让用户可旋转，但首启默认 portrait。

---

## 1. 目标

把 RIDEN Power Supply 上位机从"Linux / Windows / macOS 桌面 only"扩展到 Android 5.0+ (API 21+)，支持手机通过 OTG 线 + CH340 USB-Serial 与 RIDEN 电源通信，复用全部既有 Modbus RTU 协议栈、调度器、quickSwitch、UI 响应式布局。

## 2. Spike 验证结果 (2026-07-25 真机 PASS)

工程：`/tmp/opencode/usb_serial_spike` (Flutter 3.44.6 + `usb_serial: ^0.5.2` + AGP 9.0.1)

| 验证项 | 结果 |
|-------|------|
| `UsbSerial.listDevices()` 枚举到 CH340 | ✓ `vid=0x1a86 pid=0x7523 product="USB Serial"` |
| `device.create()` 返回非 null `UsbPort` | ✓ |
| `port.open()` 返回 true | ✓ |
| `port.setPortParameters(115200, 8, 1, NONE)` + `setDTR/RTS` | ✓ |
| `port.inputStream.listen((Uint8List) {})` 收到数据 | ✓ |
| TX 8B `01 03 00 00 00 0A C5 CD` (FC03 read HR0..9, CRC16) | ✓ 返回 ↘ 8 字节写入 |
| RX 25B `01 03 14 EA A3 00 00 02 FD 00 73 ... 03 E8 72 A9` (slave/FC/byteCount/20B data/CRC) | ✓ 完整 Modbus RTU 响应 |
| TX→RX 延迟 | ~60 ms (在 _accumulateRead 250ms budget 内) |
| 两次连续读 HR0..9 数据微变化 (`00 50`↔`00 51`) | ✓ 证明设备真实在线、非缓存 |

**结论**: `usb_serial` 0.5.2 + felHR85 UsbSerial Java driver + Android 11 + CH340 真机可用，可直接进入 Phase 4 实施。

## 3. 包选型决策

| 候选 | 评估 | 决策 |
|------|------|-----|
| `flutter_libserialport ^0.4.0` (现有) | 0.6 起声明 Android 支持，但 libserialport C 后端在 Android 上 `/dev/bus/usb/*` 节点权限限制，社区案例两极分化 | **不动** — Linux/macOS/Windows 路径继续用 |
| `flutter_libserialport ^0.6.0` | 同上 + 升级 breaking change | 拒绝 |
| `modbus_client_serial_android ^1.0.1` | 3 likes / 14 weekly / 15 月未更新 / 同步 API 与 _accumulateRead铁律冲突 / 已有底层方案 | 拒绝 |
| `usb_serial ^0.5.2` (采纳) | 194 likes / 15.3k weekly / verified publisher / felHR85 Java driver 内置 Ch34xSerialDriver / API 1:1 对应现有代码 / spike 已 PASS | **采纳** |

## 4. 架构影响

### 4.1 平台分层（保持铁律不变）

```
UI Isolate                       Modbus Worker Isolate
──────────                       ────────────────────
PowerSupplyProvider                PeriodicTaskSource
SerialModbusService (proxy)        ModbusScheduler
  SendPort ←────→ ReceivePort     ModbusExecutor (_accumulateRead 250ms)
                                   ↓↓ platform-conditional ↓↓
                                   Desktop: SerialPort FFI (flutter_libserialport)
                                   Android: UsbPort Stream (usb_serial)
```

**铁律保留**: 通信协议 / Scheduler / Task / deadline / FAST 150ms / SLOW 1000ms / quickSwitch / 数据模型 / 寄存器定义 — 全部不动。

### 4.2 Worker 平台分支

`modbus_worker.dart` 在 connect 路径按 `Platform.isAndroid` 选用不同 driver：

| 现有 (Desktop) | 新增 (Android) |
|---------------|---------------|
| `SerialPort.availablePorts` 字符串列表 | `UsbSerial.listDevices()` 返回 `UsbDevice` 列表，VID/PID 过滤 |
| `SerialPort(name)` + `.openReadWrite()` + `Config` | `device.create()` + `port.open()` + `setPortParameters(115200, 8, 1, NONE)` + `setDTR/RTS` |
| `_port.read(bytes)` 同步 poll | `port.inputStream.listen((Uint8List) {})` Stream → `_accumulateRead` buffer |
| `_port.write(bytes)` | `await port.write(Uint8List)` |
| `_port.close()` + `.dispose()` | `await port.close()` |
| `_port.isOpen` getter | 维护 `_portOpen` flag (由 Stream onDone/Error 触发) |

**最小破坏原则**: 不重写 _accumulateRead，只在 driver 层做适配。Stream 数据到达 → append 到现有 `_rxBuffer` → `_accumulateRead` 算法不变。

## 5. 10 步实施计划

| # | 步骤 | 文件 | 改动量 | 铁律 |
|---|------|------|--------|------|
| 1 | 加 Android 平台 scaffold | `flutter create --platforms=android .` (在 RIDEN 工程内执行) | 自动生成 `android/` 目录 | 新增，非 override |
| 2 | pubspec 加 `usb_serial: ^0.5.2` | `pubspec.yaml` | +1 行 | 新增 dep |
| 3 | pub-cache patch 一次性步骤 | `~/.pub-cache/hosted/pub.dev/usb_serial-0.5.2/android/build.gradle`: `jcenter()`→`mavenCentral()` + `compileSdkVersion 33`→`compileSdk 34` + 删 `classpath 'com.android.tools.build:gradle:4.1.0'` | 7 行 | 一次性，见 §7 |
| 4 | AndroidManifest USB host + device_filter | `android/app/src/main/AndroidManifest.xml` (加 `<uses-feature android:name="android.hardware.usb.host"/>` + USB_DEVICE_ATTACHED intent + meta-data 指向 `@xml/device_filter`) + `android/app/src/main/res/xml/device_filter.xml` (CH340 `vendor-id="6790" product-id="29723"`) | ~10 行 | 新增 |
| 5 | compileSdk/buildTools/minSdk 显式 pin | `android/app/build.gradle.kts` (`compileSdk=34`, `buildToolsVersion="35.0.0"`, `minSdk=21`, `targetSdk=34`; 删 `ndkVersion = flutter.ndkVersion`; 加 `packagingOptions { jniLibs { useLegacyPackaging true } }`) | ~5 行 | 新增 |
| 6 | Worker driver 层 Android 分支 | `lib/services/modbus_worker.dart:160-201` (在 `_detectPort` / `_connect` 按 `Platform.isAndroid` 选 `usb_serial` API；新增 `_portSubscription` 字段持有 Stream listen；`_rxBuffer` append 替代同步 read；`_drainPort` 改为 cancel subscription + 80ms drain window) | ~60 行 | **铁律 override** (worker 仅 driver 层) |
| 7 | Enumerator Android 分支 | `lib/services/serial_port_enumerator.dart` (新增 `enumerateUsbPortsViaAndroidIsolate` 入口用 `UsbSerial.listDevices()` + VID/PID 过滤；现有 Linux/macOS/Windows 路径继续用 `SerialPort.availablePorts`) | ~30 行 | **铁律 override** (enumerator) |
| 8 | main.dart 平台守卫 | `lib/main.dart` (`if (!Platform.isAndroid) { windowManager.* }`; Android 路径 setPreferredOrientations 横屏锁定) | ~10 行 | 新增 |
| 9 | UI 触屏适配 | `lib/app.dart` (响应式 900px 阈值已就绪 — 仅校验); 各 widget hover → long-press (InkWell 方式基本兼容，predict 低破坏) | ~20 行 | 新增 |
| 10 | CI workflow (延期到后续版本) | `.github/workflows/release-android.yml` | 50 行 | 新增 — **v1.0 不在本阶段范围** |

## 6. CLAUDE.md 铁律 override 范围（用户 2026-07-25 决策）

### 6.1 本次 override 项（仅 Phase 4）

- "不改 `modbus_worker.dart`（仅稳定性修复 P0/P1）" → **本次 override 到 driver 层**（connect/disconnect/read/write/enumerate 分支）
- "不改 `serial_port_enumerator.dart`" → **本次 override**
- "不新增业务功能" → **本次 override**（Android 平台移植算新增平台不算业务功能）

### 6.2 始终保留的铁律（即使在 Android 移植期间也不动）

- 不改 `ModbusScheduler` / `modbus_task.dart` — `/`,`scheduler` 算法不变
- 不改 `_accumulateRead` 250ms deadline / FAST 150ms / SLOW 1000ms — 三个数值保留
- 不改 quickSwitch / `power_supply_data.dart` / `RegisterDefinition` / `register_conflicts`
- 不改 `modbus_service.dart` 抽象接口 / `serial_modbus_service.dart` / `mock_modbus_service.dart` / `serial_port_scanner.dart`
- 不改 dedup key 格式 / priority 算法
- 不主动提交 git，除非用户明确要求

## 7. pub-cache patch 步骤（开发机一次性，CI 必须自动化）

### 7.1 本机 patch

`~/.pub-cache/hosted/pub.dev/usb_serial-0.5.2/android/build.gradle` 需手工修改：

- 删 `buildscript.dependencies.classpath 'com.android.tools.build:gradle:4.1.0'`（让 Flutter settings.gradle.kts 的 AGP 版本生效）
- `jcenter()` → `mavenCentral()`（Gradle 9 已删除 jcenter()）
- `compileSdkVersion 33` → `compileSdk 34`（新 AGP DSL 语法）

### 7.2 替代方案（更优雅，CI 必须）

把 `usb_serial` fork 到 `github.com/beilusm/RIDEN`，在 fork 里做上述 patch，pubspec 用 git dependency：

```yaml
usb_serial:
  git:
    url: https://github.com/beilusm/RIDEN-usb-serial-fork.git
    ref: agp9-mavencentral
```

**决策**: Phase 4 v1.1 先用 pub-cache patch (§7.1)，**v1.2 fork 并改 git dep**（消除开发机手工步骤 + CI 自动可靠）。fork 工作量 ~1h。

## 8. 风险登记

| 风险 | 等级 | 缓解 |
|------|------|-----|
| Android 系统级 USB 权限弹窗每次连接都要点 | 中 | `<intent-filter USB_DEVICE_ATTACHED>` + `device_filter.xml` 让首次插拔自动启动 app 并授权；后续会话保留授权 |
| `usb_serial` 0.5.2 在 Android 11+ scoped storage 改动下偶发 inputStream 抖动 | 低 | spike 真机 Android 11 PASS；_accumulateRead 250ms deadline 容忍抖动 |
| TX→RX 60ms 与 _accumulateRead 80ms 首读 timeout 冲突 | 低 | spike 实测 60ms < 80ms，不触发 drain |
| `usb_serial` 已 2 年未更新，潜在 Android 14/15 兼容问题 | 低 | felHR85 Java driver 是事实标准，社区维护活跃；最坏我们 fork |
| pub-cache patch 在 `pub get --force` 后丢失 | 中 | 文档化 + Phase 4 启动前 rerecord; v1.2 fork 替代 |
| 手机只有 1 USB-C 口，PC 调试 + OTG CH340 需要切换 | 低 | apk 装完后切线，app 自带 Phase D USB watcher 自动重连 |
| Flutter 3.44.6 默认 compileSdk=36 / NDK=28.2.13676358 与 Android Studio 工具链不匹配 | 中 | `app/build.gradle.kts` 显式 pin `compileSdk=34` `buildToolsVersion="35.0.0"`，规避新 SDK 安装 |
| CI 跨平台构建 Android 需 Linux runner + Android SDK | 中 | Phase 4 v1.0 不上 CI，本地 build APK 自分发；CI 留待后续版本 |

## 9. 验收标准

1. `flutter analyze` 0 新增 issue (从 21 → 21，允许 info-level Android 平台条件分支 no-op warning)
2. `flutter test` 91 PASS 全保留 — 不得回归（modbus_worker / enumerator 改动需保证 scheduler / task / scanner 测试层不变）
3. **真机 PASS**: Android 设备通过 OTG + CH340 + RIDEN 启动 → 主界面显示 V/A/W 实时波形数据（与 desktop 验收等价）
4. **quickSwitch 真机回归**: 切到 M1 → HR8/HR9 显示 M1 preset；切回 M2 → HR8/HR9 显示 M2 preset（与 Phase A.5 desktop verify 等价）
5. **USB watcher 真机回归**: 拔 OTG → UI 显示 disconnected；插回 → 1s 内自动重连，无需要重启 app
6. **记录功能真机回归**: START 弹 SAF Save dialog → 选路径 → CSV 文件写入 (路径在 Android 是 content URI 派生，需验证 `file_picker` Android 路径语义适配)

## 10. 发布计划

- **v1.1.0** — Android alpha：完成 §5 步骤 1–9，真机验证全部 PASS，GitHub Release `RIDEN-1.1.0-android-arm64.apk` (debug 自签名，~20–30MB) 自分发，不上 Play Store
- **v1.1.1** — fork `usb_serial` (§7.2)，消除开发机手工 patch
- **v1.2.0** — release-android.yml CI workflow 自动构建 + 签名 + GitHub Release 上传 (§5 步骤 10)
- **v2.0.0** — Play Store 上架（不在本阶段讨论）

## 11. 版本来源同步

Phase 4 新增 S6 (Android) 版本来源文件，纳入 CLAUDE.md "版本来源管理"表：

| # | 文件 | CI 校验 | CI 注入 | 同步责任 |
|---|------|---------|---------|---------|
| S6 | `packaging/config/env_android.sh` `APP_VERSION="1.1.0"` | ✓ `release-android.yml` Step 4 | — | 开发者 |

5 处一致性铁律扩展为 **S1 pubspec + S2 env.sh + S3 env_windows.sh + S6 env_android.sh** 4 处 env 版本同步 (S4 Runner.rc / S5 metainfo.xml 各自继续不走 CI 校验)。Linux metainfo (S5) 继续由 linux workflow sed 注入；Android 不存在 metainfo 等价物。

## 12. 用户硬件要求

- Android 5.0+ (API 21+) 手机 (USB Host feature 必备，中低端机多数支持)
- OTG 线 (Type-C 转 USB-A 母) 或 Type-C 直连 CH340 模块
- 已开启手机 USB 调试（仅开发期 APK 安装使用）

## 13. 不在 Phase 4 范围

- iOS 移植（iOS 没有官方 USB host 框架 + Apple MFi 限制，工作量大且不在用户需求里）
- Play Store 上架（需 Google Play 开发者账号 / 内容分级 / 隐私政策）
- Android 5.0 以下兼容（USB Host 必须 API 21+）
- Android 平板专属布局优化（先用手机横屏适配，平板留待后续）
- 横屏外其他 orientation 支持（Phase 4 仅锁 `landscapeLeft/landscapeRight`）
- Android widget / 通知栏 / 前台服务（电源 UI 一个 Activity 足够）
- 录制功能 SAF 路径优化的 Phase E 之后回归 — 任何 `file_picker` Android 路径 bug 单列后续 Phase 4.1 修复
