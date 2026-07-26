# Phase 4 — Android Platform Migration Design Doc

> **Status**: APPLIED (v1.1.0 released 2026-07-25，真机 PASS)
> **实施提交链**: `db0c67a` → `e51428c` → `46228f0` → `1ce417c` → `b4b97e5` → `f56df04` → `14b01c0`（加上 CI 微调 `12a1dff` / `eee9528`）
> **铁律保留**: ModbusScheduler / `modbus_task.dart` / `_accumulateRead` 250ms / FAST 150ms / SLOW 1000ms / quickSwitch / `RegisterDefinition` / `register_conflicts` / `modbus_service.dart` 接口 / `serial_modbus_service.dart` / `mock_modbus_service.dart` / `serial_port_scanner.dart` — 全部不动

## 实施变更摘要（设计中未预见）

1. **`DirectAndroidModbusService` (UI-isolate-only)**（commit `b4b97e5`）— Flutter 3.44 `BackgroundIsolateBinaryMessenger` 无法在 worker isolate 跑 usb_serial 的 MethodChannel + EventChannel reply（`platform_message_response_dart_port.cc:53 Check failed: did_send` FATAL abort）。故 Android 不用 worker isolate，改在 UI isolate 直接跑 usb_serial（platform channel async 非 blocking，不违反"UI 不直接访问 SerialPort"铁律本意，该铁律针对同步 FFI 如 libserialport）
2. **`SystemUiMode.immersiveSticky`**（commit `f56df04`）— `edgeToEdge` 只让状态栏透明覆盖，时间/电池图标仍一直可见；改用 `immersiveSticky` 彻底隐藏，边缘向内滑临时唤出
3. **Recording CSV Android 路径 SAF export**（commit `14b01c0`）— 用户要求"必须用 file_picker 弹系统文件选择器选保存位置"。Android SAF 是 one-shot bytes-only，不支持 IOSink 流式写入；故流程改为：START 写 app-private tmp → STOP 读 bytes → `FilePicker.saveFile(bytes:)` 弹 SAF 选位置 → 落盘 → 删 tmp。Desktop 路径保持 Phase E 原行为不变
4. **device_filter.xml PID 修正**（commit `1ce417c`）— 设计阶段写 `product-id="29723"` (= 0x741B) 是转录错误；正确 CH340 PID 为 `0x7523` = decimal **29987**
5. **orientation** — 设计锁 landscape，真机验证 portrait 握持 + OTG 接线方向更自然；`main.dart` 注册三种方向让用户可旋转，首启默认 portrait

## 1. 目标

把 RIDEN Power Supply 上位机从"Linux / Windows / macOS 桌面 only"扩展到 Android 5.0+ (API 21+)，通过 OTG 线 + CH340 USB-Serial 与 RIDEN 电源通信，复用全部既有 Modbus RTU 协议栈、调度器、quickSwitch、UI 响应式布局。

## 2. Spike 验证结果 (2026-07-25 真机 PASS)

工程：`/tmp/opencode/usb_serial_spike` (Flutter 3.44.6 + `usb_serial: ^0.5.2` + AGP 9.0.1)

| 验证项 | 结果 |
|-------|------|
| `UsbSerial.listDevices()` 枚举到 CH340 | ✓ `vid=0x1a86 pid=0x7523 product="USB Serial"` |
| `device.create()` 返回非 null `UsbPort` | ✓ |
| `port.open()` 返回 true | ✓ |
| `port.setPortParameters(115200, 8, 1, NONE)` + `setDTR/RTS` | ✓ |
| `port.inputStream.listen((Uint8List) {})` 收到数据 | ✓ |
| TX 8B `01 03 00 00 00 0A C5 CD` (FC03 read HR0..9, CRC16) | ✓ 8 字节写入 |
| RX 25B `01 03 14 EA A3 00 00 02 FD 00 73 ... 03 E8 72 A9` (slave/FC/byteCount/20B data/CRC) | ✓ 完整 Modbus RTU 响应 |
| TX→RX 延迟 | ~60 ms (在 `_accumulateRead` 250ms budget 内) |
| 两次连续读 HR0..9 数据微变化 (`00 50`↔`00 51`) | ✓ 设备真实在线、非缓存 |

**结论**: `usb_serial` 0.5.2 + felHR85 UsbSerial Java driver + Android 11 + CH340 真机可用，可直接进入 Phase 4 实施。

## 3. 包选型决策

| 候选 | 评估 | 决策 |
|------|------|-----|
| `flutter_libserialport ^0.4.0` (现有) | Desktop 路径稳定，Android 0.6 声明支持但社区案例两极分化 | **保留** — Desktop 路径继续用 |
| `flutter_libserialport ^0.6.0` | 升级 breaking change + Android 不确定性 | 拒绝 |
| `modbus_client_serial_android ^1.0.1` | 3 likes / 14 weekly / 15 月未更新 / 同步 API 与 `_accumulateRead` 铁律冲突 | 拒绝 |
| `usb_serial ^0.5.2` (采纳) | 194 likes / 15.3k weekly / verified publisher / felHR85 Java driver 内置 `Ch34xSerialDriver` / API 1:1 对应现有代码 / spike 已 PASS | **采纳** |

## 4. 架构影响

```
UI Isolate                       Modbus Worker Isolate (Desktop only)
────────────                     ────────────────────────────────────
PowerSupplyProvider                PeriodicTaskSource
SerialModbusService (proxy)        ModbusScheduler
  SendPort ←────→ ReceivePort     ModbusExecutor (_accumulateRead 250ms)
                                    ↓↓ platform-conditional ↓↓
                                    Desktop: SerialPort FFI (flutter_libserialport)
                                    Android: DirectAndroidModbusService (UI isolate only)
                                      usb_serial Stream → _accumulateRead buffer
```

**铁律保留**: 通信协议 / Scheduler / Task / deadline / FAST 150ms / SLOW 1000ms / quickSwitch / 数据模型 / 寄存器定义 — 全部不动。

Worker 平台 driver API 对比：

| 现有 (Desktop) | 新增 (Android) |
|---------------|---------------|
| `SerialPort.availablePorts` 字符串列表 | `UsbSerial.listDevices()` 返回 `UsbDevice` 列表，VID/PID 过滤 |
| `SerialPort(name)` + `.openReadWrite()` + `Config` | `device.create()` + `port.open()` + `setPortParameters(115200, 8, 1, NONE)` + `setDTR/RTS` |
| `_port.read(bytes)` 同步 poll | `port.inputStream.listen((Uint8List) {})` Stream → `_accumulateRead` buffer |
| `_port.write(bytes)` | `await port.write(Uint8List)` |
| `_port.close()` + `.dispose()` | `await port.close()` |

**最小破坏原则**: 不重写 `_accumulateRead`，只在 driver 层做适配。Stream 数据到达 → append 到现有 `_rxBuffer` → `_accumulateRead` 算法不变。

## 5. 实施步骤

| # | 步骤 | 文件 | 铁律 |
|---|------|------|------|
| 1 | 加 Android 平台 scaffold | `flutter create --platforms=android .` | 新增 |
| 2 | pubspec 加 `usb_serial: ^0.5.2` | `pubspec.yaml` | 新增 dep |
| 3 | pub-cache patch (CI 与本地一键脚本化) | `packaging/scripts/patch_pub_cache_android.sh` — 4 处 patch（usb_serial 0.5.2 / flutter_libserialport 0.4.0 / FlutterLibserialportPlugin.kt v2 embedding stub / file_picker 8.3.7 build.gradle 兼容性）| 一次性，见 §7 |
| 4 | AndroidManifest USB host + device_filter | `android/app/src/main/AndroidManifest.xml` (`<uses-feature android.hardware.usb.host>` + USB_DEVICE_ATTACHED intent + `@xml/device_filter`) + `android/app/src/main/res/xml/device_filter.xml` (`vendor-id="6790" product-id="29987"`) | 新增 |
| 5 | compileSdk / minSdk / targetSdk 显式 pin | `android/app/build.gradle.kts` (`compileSdk=flutter.compileSdkVersion` / `minSdk=21` / `targetSdk=34`) | 新增 |
| 6 | Worker driver 层 Android 分支 | `lib/services/modbus_worker.dart` — Desktop 路径用，Android 不 spawn worker | **铁律 override** (worker 仅 driver 层，Desktop only) |
| 7 | Enumerator Android 分支 | `lib/services/serial_port_enumerator.dart` — Android 绕 `Isolate.run` 直接 `usb_serial.listDevices()` | **铁律 override** |
| 8 | main.dart 平台守卫 | `lib/main.dart` — `if (!Platform.isAndroid) windowManager.*` + `SystemUiMode.immersiveSticky` | 新增 |
| 9 | UI 触屏适配 | `lib/app.dart` 响应式 900px 阈值已就绪 + 触屏 InkWell 兼容校验 | 新增 |
| 10 | CI workflow | `.github/workflows/release-android.yml` (tag 触发) + `android-build.yml` (push 触发 dev CI) | 新增 |

## 6. 铁律 override 范围（用户 2026-07-25 决策）

### 6.1 本次 override 项（仅 Phase 4）

- "不改 `modbus_worker.dart`（仅稳定性修复 P0/P1）" → **本次 override 到 driver 层**（connect/disconnect/read/write/enumerate 分支；Android 路径不 spawn worker）
- "不改 `serial_port_enumerator.dart`" → **本次 override**
- "不新增业务功能" → **本次 override**（Android 平台移植算新增平台不算业务功能）

### 6.2 始终保留的铁律（即使在 Android 移植期间也不动）

- 不改 `ModbusScheduler` / `modbus_task.dart` — scheduler 算法不变
- 不改 `_accumulateRead` 250ms deadline / FAST 150ms / SLOW 1000ms — 三个数值保留
- 不改 quickSwitch / `power_supply_data.dart` / `RegisterDefinition` / `register_conflicts`
- 不改 `modbus_service.dart` 抽象接口 / `serial_modbus_service.dart` / `mock_modbus_service.dart` / `serial_port_scanner.dart`
- 不改 dedup key 格式 / priority 算法
- 不主动提交 git，除非用户明确要求

## 7. pub-cache patch

`packaging/scripts/patch_pub_cache_android.sh` 一键脚本，CI 与本地都调用，4 处 patch：

1. `usb_serial-0.5.2/android/build.gradle` — 删 `jcenter()` + AGP 4.1 classpath
2. `flutter_libserialport-0.4.0/android/build.gradle` — 删 jcenter + AGP 4.1 + CMake native + sourceSets 全空 + JVM 17
3. `flutter_libserialport-0.4.0/android/.../FlutterLibserialportPlugin.kt` — v2 embedding stub (删 v1 Registrar 引用)
4. `file_picker-8.3.7/android/build.gradle` — 删 AGP 7.4.2 classpath + compileSdk 跟随 rootProject (36)

替代方案（后续版本可考虑）：fork `usb_serial` 到 `github.com/beilusm` 加上述 patch，pubspec 用 git dep — 消除开发机 / CI 的 pub-cache 手工步骤。

## 8. 剩余风险

| 风险 | 等级 | 缓解 |
|------|------|-----|
| pub-cache patch 在 `pub get --force` 后丢失 | 中 | 一键脚本化 + CI 也跑；fork 替代待后续版本 |
| 手机只有 1 USB-C 口，PC 调试 + OTG CH340 需切换 | 低 | APK 装完后切线，Phase D USB watcher 自动重连 |

风险登记全部其他项已被真机 spike 实测消解（usb_serial 0.5.2 Android 11 PASS / TX 60ms < 80ms budget / 风险已实现）。

## 9. 验收标准

1. `flutter analyze` 0 新增 issue (21 → 21，允许 info-level Android 平台条件分支 no-op warning)
2. `flutter test` 91 PASS 全保留 — 不得回归（modbus_worker / enumerator 改动需保证 scheduler / task / scanner 测试层不变）
3. **真机 PASS**: Android 设备通过 OTG + CH340 + RIDEN 启动 → 主界面显示 V/A/W 实时波形数据
4. **quickSwitch 真机回归**: 切到 M1 → HR8/HR9 显示 M1 preset；切回 M2 → HR8/HR9 显示 M2 preset
5. **USB watcher 真机回归**: 拔 OTG → UI 显示 disconnected；插回 → 1s 内自动重连
6. **记录功能真机回归**: START → SAF 写 tmp → STOP 弹系统文件选择器 → 落盘正确

## 10. 用户硬件要求

- Android 5.0+ (API 21+) 手机 (USB Host feature 必备)
- OTG 线 (Type-C 转 USB-A 母) 或 Type-C 直连 CH340 模块
- 开发期 APK 安装需开启"USB 调试"

## 11. 不在 Phase 4 范围

- iOS 移植（无官方 USB host 框架 + MFi 限制）
- Play Store 上架（需 Google Play 开发者账号 / 内容分级 / 隐私政策）
- Android < 5.0 兼容（USB Host 必须 API 21+）
- 平板专属布局优化（先用手机布局，平板留待后续）
- 前台服务 / 通知栏 / Widget
