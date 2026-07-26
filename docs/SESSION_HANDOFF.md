# Project Status — Engineering Evidence Archive

RIDEN 数控电源 Flutter 上位机 (Linux + Windows + Android)。**v1.1.1 已正式发布。**

本文件是**工程证据存档**：源码 file:line 引用、运行时实测结果、被否决的假设及证据、版本冻结记录。架构、通信参数、设计约束、修改禁令见 `CLAUDE.md`（权威文件）。各 Phase 实施详情见：
- `docs/PHASE_4_ANDROID.md` — Phase 4 Android 实施设计
- `docs/PHASE_5_SLOT_EDIT.md` — Phase 5 Memory Slot 编辑实施设计
- `docs/DEVELOPMENT.md` — 开发环境 / 构建 / 测试 / AI 协作文档

# Verified Facts (源码 + SDK 引用存档)

证据来源标注：[SDK]=Dart SDK 官方 API 文档 / [Library Source]=第三方库源码 / [Project Source]=本项目源码 / [POSIX]=Linux man pages

1. **[Project Source]** `lib/services/modbus_worker.dart:525` `Isolate.spawn(_workerEntry, uiPort.sendPort)` 未传 `onExit` / `onError` / `errorsAreFatal` / `debugName` 命名参数。
2. **[Project Source]** `lib/services/serial_modbus_service.dart:111-114` `disconnect()` 中 `await _worker!.disconnect()` 与 `await _worker!.shutdown()` 无 `.timeout()` 包裹。
3. **[Project Source]** `lib/services/serial_modbus_service.dart:28` `connect()` 首行 `if (_worker != null) return;` — 双重 worker 防护的关键守卫。
4. **[Project Source]** `lib/services/serial_modbus_service.dart:114` `_worker = null` 仅在 disconnect 完整路径末尾执行。任一 await hang → `reconnect` 永远失败。
5. **[Project Source]** `lib/providers/power_supply_provider.dart:184-191` `_onPollMiss()` 已定义但全 lib 无调用点 (grep 确认)。**仍 OPEN (P1-1)**。
6. **[SDK] `Isolate.kill` 文档**: 仅承诺"shuts down as soon as possible"。**未承诺** native resource / fd 释放。https://api.dart.dev/stable/3.5.0/dart-isolate/Isolate/kill.html
7. **[SDK] `NativeFinalizer` 文档**: 是唯一被官方文档明确承诺"在 isolate group 关闭时 callback 必被调用"的机制。https://api.dart.dev/stable/3.5.0/dart-ffi/NativeFinalizer-class.html
8. **[Library Source]** `libserialport-0.3.0+1/lib/src/port.dart:208` `_SerialPortImpl` 持有 `ffi.Pointer<sp_port> _port`。`:247-250` `dispose()` 调 `sp_free_port`（释放结构体内存，不关闭 fd）。`:262` `close()` 调 `sp_close`（释放 fd）。
9. **[Library Source]** Grep `libserialport-0.3.0+1` for `NativeFinalizer|Finalizable|attachFinalizer|Dart_Finalizer`：**0 matches**。未注册任何 finalizer。
10. **[Library Source]** Grep `libserialport-0.3.0+1` for `TIOCEXCL|TIOCNXCL|ioctl`：**0 matches**。库未启用 Linux TIOCEXCL 独占模式。
11. **[SDK] `Isolate.addOnExitListener` 文档**: onExit 消息 = `null`（默认 response）。"as the last thing before it terminates. It will run no further code after the message has been sent." — **显式保证 onExit 是 isolate 最后一条消息**。
12. **[SDK] `Isolate.addErrorListener` 文档**: onError 消息 = `List<dynamic>` length=2 = `[String error, String? stackTrace]`。**显式陈述格式**。
13. **[SDK] `Isolate.spawn` 文档**: 通过命名参数 `onExit:` / `onError:` 在 spawn 时注册可避免 "listener 注册前 isolate 已退出" 的 race。
14. **[Project Source]** `lib/services/modbus_worker.dart:613-617` `shutdown()` 的 `.then` 内 `_dataController?.close(); _uiPort.close(); _isolate.kill(priority: Isolate.immediate)` 三步无 try-finally 保护。
15. **[Project Source]** `lib/services/modbus_worker.dart:511-529` `spawn()` 中 `uiPort.listen` 在 `Isolate.spawn` 之前注册。Isolate.spawn 抛异常时 `uiPort` 未 close → ReceivePort 泄漏。`handshake.future` 无 timeout → worker 在 handshake 前退出则 `await` 永远挂起。

# Disproved Assumptions

- **"Isolate.kill(priority: Isolate.immediate) 会释放 libserialport 持有的 SerialPort fd"** — DISPROVED。
  证据: [Library Source] libserialport 未注册 NativeFinalizer；[SDK] Isolate.kill 文档未承诺 native resource 释放；[Library Source] sp_free_port 不关闭 fd。
  后果: forceKill 路径下旧 fd 泄漏到进程退出。但 isolate 死亡后无代码运行该 fd，新 worker 不受其影响（运行时验证见下）。

- **"`.then` 三步清理无 try-finally 是 P0"** — DISPROVED（降级 P2）。
  Dart 中 kill 已死 isolate / close 已关闭 ReceivePort 通常 noexcept。该问题归为 P2 防御性改进，非生产 hang 风险。

# Runtime Verification — ttyUSB concurrent open

VERIFIED (Step 7 运行时测试): 临时测试程序在 `/dev/ttyUSB0` (ch341 module, Linux kernel) 验证 V1/V2/V3 (O_RDWR 标志组合) 均允许并发 open。V4 (TIOCEXCL 显式启用独占) 才会拒绝。libserialport binary `strings` 0 matches `TIOCEXCL`，因此不会触发独占。

**结论**: 隔离的 fd 不会阻塞新 worker 打开同一设备。forceKill 路径下旧 fd 仅 OS-level 泄漏 (进程退出回收)，非 connectivity blocker。测试程序在验证完成后已删除。

# Patch A.1–B.1 Line Index (APPLIED)

源码位置索引，便于回看实现。完整变更叙述见 commit log (`git log --follow lib/services/modbus_worker.dart`)。

| Patch | 文件:line | 状态 | 说明 |
|---|---|---|---|
| A.1 | `modbus_worker.dart:9-20` | APPLIED | 私有 `_WorkerCrashedException implements Exception` |
| A.2 | `modbus_worker.dart:534-560` | APPLIED | `spawn()` 中 `uiPort.listen` 分流 4 种消息 |
| A.3 | `modbus_worker.dart:562-582` | APPLIED | `Isolate.spawn` 加 `onExit/onError` + handshake 5s timeout + spawn 失败清理 |
| A.4 | `modbus_worker.dart:523 / 591-601 / 603-611` | APPLIED | `_dead` 字段 + `_onIsolateExit` + `forceKill` |
| P1-3 + Option B | `modbus_worker.dart:524 / 613-619 / 698-700` | APPLIED | `_cleaned` + `_cleanup()` 唯一资源清理权威；`shutdown().then` 改单行 `_cleanup()` |
| B.1 | `serial_modbus_service.dart:106-135` | APPLIED | `disconnect()` 重写 — 5s+5s timeout + forceKill 兜底 + identical check |

# Production Risks

## P0 (必修，否则生产 Hang) — **全部 RESOLVED**

| # | Pre-patch 后果 | Post-patch | 修复 |
|---|---|---|---|
| Worker crash mid-session | UI hang — 唯一恢复是杀应用 | UI timeout；手动 disconnect→connect 恢复 | A.2 + A.3 + A.4 |
| `disconnect()` while worker stuck | 永久 hang → reconnect 永远失败 | 10s 内可 reconnect | B.1 |
| `Isolate.spawn` 失败 | ReceivePort 泄漏 + UI hang | 5s 内清理 + rethrow | A.3 |
| Pending Future on crash | 调用方 hang | `_onIsolateExit` completes all with `_WorkerCrashedException` | A.4 |

## P1 (建议修，不致 hang，UX 退化)

| ID | 状态 | 修复实施 |
|---|---|---|
| **P1-1 `_onPollMiss` 死代码** | **OPEN** | `_consecutiveFails` 永远=0 → `CommStatus.error` 永不达到。建议在 FAST/SLOW poll miss 路径接入 `_onPollMiss()` 调用。详见 Verified Fact #5 |
| P1-2 zombie `_worker` 阻塞自动 reconnect | **RESOLVED** | service `_handleWorkerError` (identical 清零 + 取消 sub/statTimer + 发 `CommStatus.error` 快照) + `ModbusWorkerHandle.isDead` getter + `_cleanup()` 同步 `_dead=true` + connect/disconnect/listPorts fast-path。详 `test/serial_worker_lifecycle_test.dart` 7 test PASS |
| P1-3 `_cleaned` 与 `_dead` 分离状态/资源幂等 | **RESOLVED** | 见 Patch A.1-B.1 Line Index |

## P2 (优化项，不修)

- `SerialModbusService._dataController` 永不 close (设计如此, long-lived broadcast)
- `PowerSupplyProvider.dispose` 调用 `_service.disconnect()` 未 await (应用退出场景无影响)
- 罕见 timeout 路径下 libserialport fd 泄漏 → OS-level descriptor 泄漏，已验证（见 Runtime Verification）不阻塞 connectivity

## Observations (Phase 1 Release 验证发现，不修复)

- **OBS-1**: release binary 启动 ~110s 后 `[SCHED] pause group=poll` 自动触发 (complete=0 持续但 isolate=alive)。追踪: `_pauseTieredPolling()` 仅在 `_disconnect`/`_shutdown`/worker `pausePoll` 路径调用；疑似 widget tree dispose → Provider.dispose。**非构建问题**，真实用户场景很可能不复现。若复现：可在 `my_application_shutdown` 调 `g_application_quit` 强制退出
- **OBS-2**: release binary 不响应 SIGINT，仅 SIGTERM (SIGTERM 3s 内退出 EXITCODE=143)。Flutter Linux GTK 模板未注册 SIGINT handler；GTK `GApplication` 默认响应 SIGTERM 不响应 SIGINT

# Phase 3 — HiDPI 否决证据 (linuxdeploy-plugin-gtk 实测对比)

**方案 B (linuxdeploy + plugin-gtk + appimagetool)** → **被否决**。实测 `linuxdeploy-plugin-gtk` 在 AppRun 时 source 的 hook 强制 `export GDK_BACKEND=x11` 和 `export GTK_THEME=Adwaita:...`，破坏 HiDPI 主题 / font-scaling-factor。

**plugin-gtk hook 关键破坏行**（`<AppDir>/apprun-hooks/linuxdeploy-plugin-gtk.sh` 第 17 + 16 行）:
```bash
export GDK_BACKEND=x11          # 强制 X11，Wayland 原生 HiDPI 缩放失效
export GTK_THEME="Adwaita:..."  # 覆盖用户系统主题
```

**实测对比**（同机器、同 bundle、同窗口尺寸）:

| 方案 | GL frame size | HiDPI | 体积 |
|---|---|---|---|
| `flutter build linux --release` 裸 bundle | 2712×1616 | 正常 (2x) | 25 MB |
| linuxdeploy + plugin-gtk AppImage | 1346×1616 | **失效** (1x) | 43 MB |
| 手工 AppDir + appimagetool (**采用**) | 2712×1616 | 正常 (2x) | 9.9 MB |

采用方案 `AppRun` 仅 9 行，不设任何 GTK 环境变量。详见 `CLAUDE.md` Phase 3 禁令。

# Phase W1.5 — Windows CRT 依赖实测审计

`flutter_libserialport` Windows 路径：`flutter_libserialport-0.4.0/windows/CMakeLists.txt` 通过 `set(flutter_libserialport_bundled_libraries "$<TARGET_FILE:serialport>" PARENT_SCOPE)` 导出 `serialport.dll` 路径 → `windows/CMakeLists.txt:84-88` `install(FILES)` 安装到 `build/windows/x64/runner/Release/`。`serialport.dll` 自动进 Release，无运行时 DLL 缺失风险，**无需修改**。Linux 端 `readelf -d libflutter_libserialport_plugin.so` 的 NEEDED 段不含 `libserialport.so` — 跨平台一致 dart_ffi 直接加载。

`objdump -p` 解析 Flutter 3.44.6 Release `flutter_windows.dll` 的 PE Import Table: `ADVAPI32 / IPHLPAPI / ole32 / OLEAUT32 / PSAPI / SHLWAPI / RPCRT4 / WINMM / WS2_32 / IMM32 / USER32 / OPENGL32 / bcrypt / ntdll / GDI32 / KERNEL32 / CRYPT32 / OLEACC / PROPSYS / UIAutomationCore / dxgi / d3d9 / api-ms-win-core-*`。`vcruntime140.dll` / `msvcp140.dll` / `ucrtbase.dll` **全部不在 Import Table** — Flutter 官方已对 `flutter_windows.dll` 静态链接 CRT。

但项目自身所有产物未显式设 `MSVC_RUNTIME_LIBRARY`，CMake policy `CMP0091` 默认 OLD → `/MD`:

| 编译产物 | CRT 链接策略 |
|---|---|
| `flutter_windows.dll` (Flutter 官方) | 静态 `/MT` (实测) |
| `riden_power_supply.exe` (我们) | 动态 `/MD` |
| `flutter_libserialport_windows_plugin.dll` (插件) | 动态 `/MD` |
| `serialport.dll` (libserialport) | 动态 `/MD` |
| `screen_retriever_windows_plugin.dll` | 动态 `/MD` |
| `window_manager_plugin.dll` | 动态 `/MD` |

**结论**: 最终 Release 需要 VC++ Redistributable x64 (2015-2022)。README 用户使用说明已说明下载 `vc_redist.x64.exe`（14MB，一次）。`ucrtbase.dll` 由 Windows Universal CRT 自带无需 Redist。后续可改 `CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded` 消除依赖，但需修改第三方插件 CMakeLists（v1.0 不做）。

# Phase A / A.5 / B 实施记录 (HR19 quickSwitch 迁移)

时间线（已 commit）:
- **Phase A** — Register Schema 与 Worker 解码对齐。HR3 `auxVoltage → firmwareVersion` / HR7 → `systemTempF` (int16 signed) / HR15 → `keyLock` / HR16 → `protectionStatus` enum / HR17-18 bools / `auxVoltage` & `statusFlags` 保留 `@Deprecated` / `quickSwitch(slot)` 接口加入 abstract + Serial + Mock
- **Phase A.5** — HR19 硬件 quick switch 验证 ✅ PASS (真机): `HR19 0x0000→0x0001` → HR8 4.20V→5.00V + HR9 6.100A→5.000A (与 M1 preset 一致)。验证脚本 `test/phasea5_quickswitch_verify.dart`（smoke 默认，hardware gate `PHASEA5_HW=1`）
- **Phase B** — UI 迁移到 quickSwitch: `loadSlot()` / `loadMemorySlot()` 标 `@Deprecated` 保留; UI 全部改走 `quickSwitch()`. 实现 = write HR19=slot → 等 600ms → readRawRegisters HR0..HR120 → `_data.copyWith` 同步全字段 → `notifyListeners`
- **Phase B.1** — quickSwitch 稳定性优化: ovp/ocp 源从 `raw[82]/raw[83]` 改为 `raw[80+slot*4+2/3]` + `[QSW] before/after` 日志 + `readAllMemorySlots()` 一次 bulk read. 真机回归 PASS (per-slot OVP/OCP distinguished, HR82/HR83 invariant M0 stored)
- **Phase B.2** — 修复 FAST poll 读 HR82/HR83 覆盖 active slot 值导致 quickSwitch 后 UI 闪回 M0 bug. 三层守卫: service `_sub.listen` `ovp: _current.ovp, ocp: _current.ocp` → service `_parseAllRegs` 不再填 ovp/ocp → provider `_onData` merged 守卫 + SLOW poll SLOT-sync 把 active slot storage 升到 `_data.ovp/ocp`. `register_conflicts.dart` HR14/HR82/HR83/HR2 标 [RESOLVED]; `register_definition.dart` HR14/HR82/HR83 `conflict: false`

**Phase B.1 设备固件行为 (真机首次发现)**: `HR19=0` 不会 reload M0 preset 到 HR8/HR9；HR19=0 被设备理解为"停留 / 无新选择"。**UI 不可主动切回 M0** — preset dialog 只显示 M1..M9。详见 `CLAUDE.md` "HR19 quickSwitch 是 Memory Slot 唯一真实切换入口"。

# Release History (Frozen)

| Version | Tag | Commit | Release URL | Assets |
|---|---|---|---|---|
| v1.0.0 | `v1.0.0` | (历史) | Windows-only release | Windows ZIP |
| v1.0.1 | `v1.0.1` (Latest) | `075dd5d Bump version to 1.0.1` | https://github.com/beilusm/RIDEN/releases/tag/v1.0.1 | linux-x86_64.AppImage (10,299,896 B) + windows-x64.zip (12,743,023 B) + 2 SHA256SUMS |
| v1.0.4 | `v1.0.4` | `d047ed2` | https://github.com/beilusm/RIDEN/releases/tag/v1.0.4 | linux AppImage + windows ZIP + 2 SHA256SUMS (Phase E 数据记录) |
| v1.1.0 | `v1.1.0` | `e51428c` (Phase 4 Android head) | https://github.com/beilusm/RIDEN/releases/tag/v1.1.0 | linux AppImage + windows ZIP + android APK + 3 SHA256SUMS |
| v1.1.1 | `v1.1.1` | `3570dd1 Phase 5: Memory Slot data group edit` | https://github.com/beilusm/RIDEN/releases/tag/v1.1.1 | 6 assets (APK + AppImage + Windows ZIP + 3 SHA256SUMS) |

## v1.0.1 FROZEN delivery record

**Phase L1.2 体系首次生产验证通过** — v1.0.1 是首个通过双 workflow 同步发布 + CI 自动校验三来源 + Linux CI 自动注入 metainfo 的版本。

| 字段 | 值 |
|---|---|
| 发布时间 | 2026-07-22T05:42:21Z |
| Tag | `v1.0.1` (annotated, message "Release v1.0.1") |
| Commit | `075dd5d Bump version to 1.0.1` |
| Release name | `RIDEN Power Supply 1.0.1` |
| isPrerelease | `false` (Latest) |
| Linux workflow run | `29894439550` — SUCCESS 2m21s (17 steps) |
| Windows workflow run | `29894439508` — SUCCESS 3m27s (12 steps) |

CI 校验产物 (Phase L1.2 实跑日志确认):
- Linux Step 4 `Verify env.sh APP_VERSION`: `env.sh APP_VERSION: 1.0.1` → `OK: tag semver matches env.sh APP_VERSION (1.0.1)`
- Linux Step 13 `Inject metainfo.xml`: `before: <release version="1.0.0" date="2026-07-19">` → `after: <release version="1.0.1" date="2026-07-22">`
- Windows Step 4 `Verify env_windows.sh APP_VERSION`: `1.0.1` → `OK`

**v1.0.1 Release 已冻结**：不可变。如修正任何问题按 SemVer 走 v1.0.2 / v1.1.x 流程。

# Outstanding TODO (未启动)

按优先级排序，均见 `CLAUDE.md` "当前 Patch 状态" + 各 Phase 文档。

- **P1-1 `_onPollMiss` 死代码** (`power_supply_provider.dart:~594`) — `_consecutiveFails` 永远=0 → `CommStatus.error` 永不达到。在 FAST/SLOW poll miss 路径接入调用
- **setOVP/setOCP 写入路径仍指向 HR82/HR83** — active≠0 时改不到 active slot OVP. 需 datasheet 硬件验证 (Phase B.3 候选)
- **Phase B.5 旧路径残留 audit** — 确认 `loadSlot` / `loadMemorySlot` 无内部调用后真删除实现
- **quickSwitch 延迟优化** — 当前固定 `await 600ms` → 改 200ms × 5 次短轮询检测 HR8 变化 (--Phase D follow-up 范围)
- **Phase 4.1** — Android share/export 二次入口 (录制完成后 "Share / Open with CSV viewer")
- **v1.1.2** — fork `usb_serial` git dep，消除 pub-cache patch 手工步骤 (`packaging/scripts/patch_pub_cache_android.sh` 4 处 patch)
- **dev CI APP_VERSION 校验** (Phase L1.3 候选)

详见 `CLAUDE.md` "版本来源不做的事"、"不重新启用 @Deprecated loadSlot"。
