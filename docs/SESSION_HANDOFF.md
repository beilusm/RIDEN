# Project Status

RIDEN 数控电源 Flutter 桌面上位机。当前阶段：**Post-Release 维护期 — v1.0.1 已正式 Release (FROZEN)，Phase A/A.5/B/B.1/B.2 寄存器表对齐 + HR19 quickSwitch 迁移 + active OVP/OCP 同步修复已固化。下一阶段候选：Phase B.5 残留 audit / Phase C UI 展示 / quickSwitch 延迟优化**。

架构、通信参数、设计约束、修改禁令见 `CLAUDE.md`。本文件只记录当前 patch 状态、验证结果、剩余 TODO。

# Files Modified

Stage 5 之前已完成的功能性文件（本次会话未修改）：
- `lib/widgets/serial_panel.dart` — 串口设置卡片
- `lib/widgets/register_page.dart` — 寄存器表格 UI + 编辑对话框
- `lib/models/register_definition.dart` — 寄存器 Schema
- `lib/models/register_conflicts.dart` — 8 条冲突 ledger
- `lib/services/modbus_worker.dart` — `_addr`/`_baudRate` 实例字段 + `list_ports` 命令
- `lib/services/serial_modbus_service.dart` — `connect`/`readRawRegisters` 签名扩展
- `lib/providers/power_supply_provider.dart` — `connect`/`reconnect`/`listPorts` + `writeRawRegister.catchError`

**本次会话已应用 Patch A.1-A.4 + B.1 + P1-3 修复 + Option B refactor**。`fvm flutter analyze` 0 新 issue (43 baseline 全部 pre-existing)。

# Verified Facts

证据来源标注：[SDK]=Dart SDK 官方 API 文档 / [Library Source]=第三方库源码 / [Project Source]=本项目源码 / [POSIX]=Linux man pages

1. **[Project Source]** `lib/services/modbus_worker.dart:525` `Isolate.spawn(_workerEntry, uiPort.sendPort)` 未传 `onExit` / `onError` / `errorsAreFatal` / `debugName` 命名参数。

2. **[Project Source]** `lib/services/serial_modbus_service.dart:111-114` `disconnect()` 中 `await _worker!.disconnect()` 与 `await _worker!.shutdown()` 无 `.timeout()` 包裹。

3. **[Project Source]** `lib/services/serial_modbus_service.dart:28` `connect()` 首行 `if (_worker != null) return;` — 双重 worker 防护的关键守卫。

4. **[Project Source]** `lib/services/serial_modbus_service.dart:114` `_worker = null` 仅在 disconnect 完整路径末尾执行。任一 await hang → `reconnect` 永远失败。

5. **[Project Source]** `lib/providers/power_supply_provider.dart:184-191` `_onPollMiss()` 已定义但全 lib 无调用点（grep 确认）。

6. **[SDK] `Isolate.kill` 文档**：仅承诺"shuts down as soon as possible"。**未承诺** native resource / fd 释放。https://api.dart.dev/stable/3.5.0/dart-isolate/Isolate/kill.html

7. **[SDK] `NativeFinalizer` 文档**：是唯一被官方文档明确承诺"在 isolate group 关闭时 callback 必被调用"的机制。https://api.dart.dev/stable/3.5.0/dart-ffi/NativeFinalizer-class.html

8. **[Library Source]** `libserialport-0.3.0+1/lib/src/port.dart:208` `_SerialPortImpl` 持有 `ffi.Pointer<sp_port> _port`。`:247-250` `dispose()` 调 `sp_free_port`（释放结构体内存，不关闭 fd）。`:262` `close()` 调 `sp_close`（释放 fd）。

9. **[Library Source]** Grep `libserialport-0.3.0+1` for `NativeFinalizer|Finalizable|attachFinalizer|Dart_Finalizer`：**0 matches**。未注册任何 finalizer。

10. **[Library Source]** Grep `libserialport-0.3.0+1` for `TIOCEXCL|TIOCNXCL|ioctl`：**0 matches**。库未启用 Linux TIOCEXCL 独占模式。

11. **[SDK] `Isolate.addOnExitListener` 文档**：onExit 消息 = `null`（默认 response）。"as the last thing before it terminates. It will run no further code after the message has been sent." — **显式保证 onExit 是 isolate 最后一条消息**。https://api.dart.dev/stable/3.5.0/dart-isolate/Isolate/addOnExitListener.html

12. **[SDK] `Isolate.addErrorListener` 文档**：onError 消息 = `List<dynamic>` length=2 = `[String error, String? stackTrace]`。**显式陈述格式**。https://api.dart.dev/stable/3.5.0/dart-isolate/Isolate/addErrorListener.html

13. **[SDK] `Isolate.spawn` 文档**：通过命名参数 `onExit:` / `onError:` 在 spawn 时注册可避免 "listener 注册前 isolate 已退出" 的 race。https://api.dart.dev/stable/3.5.0/dart-isolate/Isolate/spawn.html

14. **[Project Source]** `lib/services/modbus_worker.dart:613-617` `shutdown()` 的 `.then` 内 `_dataController?.close(); _uiPort.close(); _isolate.kill(priority: Isolate.immediate)` 三步无 try-finally 保护。

15. **[Project Source]** `lib/services/modbus_worker.dart:511-529` `spawn()` 中 `uiPort.listen` 在 `Isolate.spawn` 之前注册。Isolate.spawn 抛异常时 `uiPort` 未 close → ReceivePort 泄漏。`handshake.future` 无 timeout → worker 在 handshake 前退出则 `await` 永远挂起。

# Disproved Assumptions

- **"Isolate.kill(priority: Isolate.immediate) 会释放 libserialport 持有的 SerialPort fd"** — DISPROVED。
  证据：[Library Source] libserialport 未注册 NativeFinalizer；[SDK] Isolate.kill 文档未承诺 native resource 释放；[Library Source] sp_free_port 不关闭 fd。
  后果：forceKill 路径下旧 fd 泄漏到进程退出。但 isolate 死亡后无代码运行该 fd，新 worker 不受其影响（待运行时验证）。

- **"`.then` 三步清理无 try-finally 是 P0"** — DISPROVED（降级）。
  Dart 中 kill 已死 isolate / close 已关闭 ReceivePort 通常 noexcept。该问题归为 P2 防御性改进，非生产 hang 风险。

# Unknowns (Runtime Verification Required)

- **ttyUSB 重 open 是否一定成功** — VERIFIED (Step 7 runtime test)。
  运行时测试: 临时测试程序在 `/dev/ttyUSB0` (ch341 module, Linux kernel) 上验证 V1/V2/V3 (O_RDWR 标志组合) 均允许并发 open。V4 (TIOCEXCL 显式启用独占) 才会拒绝。libserialport binary `strings` 0 matches `TIOCEXCL`，因此不会触发独占。结论: 隔离的 fd 不会阻塞新 worker 打开同一设备。
  测试程序在验证完成后已删除。

- **Dart SDK 是否显式陈述 user-sent send() 与 onError 之间的相对顺序** — SDK 文档未陈述。
  [SDK] addOnExitListener 仅显式陈述 "onExit 是最后消息"，未陈述 onError 相对于同期 user send() 的顺序。
  设计已采取幂等保护 (`_dead` 早返)，不依赖此顺序保证。

# Current Patch Plan

基于证据修订的最终方案。所有修改均为 P0 修复。

## Patch A — `lib/services/modbus_worker.dart`

### A.1 新增私有 Exception 类（文件顶部，class _ModbusWorkerCore 之前）
- **purpose**: 用于 worker crash 时 completeError 的类型，供下游 try-catch 识别
- **status**: APPLIED + REVIEWED。A.1 Review 后改为私有 `_WorkerCrashedException` (依据 handoff 标题语义的私有设计 intent)。位置: `modbus_worker.dart:9-20`。

```dart
class _WorkerCrashedException implements Exception {
  final String reason;
  _WorkerCrashedException(this.reason);
  @override String toString() => '_WorkerCrashedException: $reason';
}
```

### A.2 修改 `spawn()` 中 `uiPort.listen`
- **purpose**: 分流 handshake / onExit / onError / 普通消息。
- **status**: APPLIED + REVIEWED。位置: `modbus_worker.dart:534-560`。三个 forward-ref 为 A.4 预留 (A.4 已 resolve)。

### A.3 修改 `Isolate.spawn` 调用
- **purpose**: 注册 onExit/onError；handshake 5s timeout；spawn 失败清理 uiPort。
- **status**: APPLIED + REVIEWED。位置: `modbus_worker.dart:562-582`。

### A.4 新增字段 `_dead` + `_onIsolateExit` + `forceKill`
- **purpose**: 幂等保护；completeError pending；强制 isolate 终止 + 资源回收兜底。
- **status**: APPLIED + REVIEWED。位置: `modbus_worker.dart:523 (_dead)`, `591-601 (_onIsolateExit)`, `603-611 (forceKill)`。

**P1-3 修复 (追加于 A.4 之后)**: 原始 A.4 `forceKill()` 在 `_dead==true` 时短路 → 跳过资源释放。修复: 新增 `bool _cleaned = false` 字段 (`modbus_worker.dart:524`) + 新增 `_cleanup()` 方法 (`modbus_worker.dart:613-619`)。`_dead` 仅管 notification/completer 幂等；`_cleaned` 仅管资源清理幂等。`_onIsolateExit` 末尾调用 `_cleanup()`。

**Option B refactor (追加于 P1-3 之后)**: `shutdown().then(...)` 原 bare `_dataController?.close(); _uiPort.close(); _isolate.kill(...)` 改为单行 `_cleanup();`。`_cleanup()` 成为唯一资源清理权威。原 latent race (`_isolate.kill` 对已死 isolate 的未文档化 no-throw 行为) 结构性消除。

## Patch B — `lib/services/serial_modbus_service.dart`

### B.1 重写 `disconnect()`
- **purpose**: 给 disconnect/shutdown 加 5s timeout；timeout 后 forceKill 兜底；identical check 后置 null
- **status**: APPLIED + REVIEWED。位置: `serial_modbus_service.dart:106-135`。

## Patch C — 跳过

`shutdown().then` 内 try-finally 防护。降级为 P2（非生产 hang 风险）。

# Production Risks

## P0 (必修，否则生产 Hang) — **全部 RESOLVED**

1. **Worker isolate crash 后 UI 无任何感知机制** — **RESOLVED via Patch A.2 + A.3 + A.4**
   - 原: `Isolate.spawn` 未传 `onExit` / `onError`
   - 现: onExit/onError 注册到 uiPort.sendPort；listener 分流到 `_onIsolateExit`；所有 pending Future 通过 `_WorkerCrashedException` completeError。
   - 验证: code-direct 控制流追踪 + Step 8 audit 通过。

2. **disconnect/shutdown 路径无 timeout** — **RESOLVED via Patch B.1**
   - 原: `serial_modbus_service.dart:111-114` await 链无 timeout；`_worker = null` 永不执行。
   - 现: 双 5s timeout 包裹，超时后 `forceKill()` 兜底，`identical` check 后置 null。worst-case 阻塞 10s。

3. **spawn 失败 / handshake 永不返回** — **RESOLVED via Patch A.3**
   - 原: `spawn()` 无 timeout；Isolate.spawn 抛异常 uiPort 未 close。
   - 现: handshake 5s timeout；catch 块清理 isolate + uiPort；rethrow。

## P1 (建议修，不会 Hang) — **部分 RESOLVED**

4. **`forceKill` 短路导致 uiPort / dataController / 2 个 orphan Completer 泄漏** — **RESOLVED via P1-3 修复**
   - 原: A.4 `forceKill` 在 `_dead==true` 时早返，跳过 `_uiPort.close()`/`_dataController?.close()`。
   - 现: 引入 `bool _cleaned` 分离状态幂等与资源清理幂等；`_cleanup()` 为唯一资源清理权威；`_onIsolateExit` 末尾调用 `_cleanup()`；`shutdown().then` 也 reuse `_cleanup()` (Option B refactor)。
   - 验证: 所有 4 条路径 (normal shutdown / crash / crash+disconnect / crash+reconnect) 均无泄漏；`_isolate.kill` 对已死 isolate 的 latent race 结构性消除。

5. **`_onPollMiss` 死代码导致 timeout/error 状态机瘫痪** — **OPEN (P1-1)**
   - [Project Source] `power_supply_provider.dart:184` `_onPollMiss()` 定义但全 lib 无调用点 (grep 确认)。
   - `_consecutiveFails` 永远=0；`CommStatus.error` 永不达到；health timer 仅升级到 `CommStatus.timeout` (3s)。
   - 不致 hang，但 UI 状态机退化：用户看到 timeout 而非 error。
   - 未修复。out of scope 当前会话。

6. **Worker crash 后 zombie `_worker` 静默阻塞 `connect()`，需手动 disconnect→connect 恢复** — **RESOLVED (P1-2) — 本次会话已修复**
   - [Project Source] `serial_modbus_service.dart:30` `onError` 改为 `_handleWorkerError`：identical 清零 `_worker` + 取消 `_sub`/`_statTimer` + `_dataController.add(CommStatus.error 快照)` 通知 Provider。
   - `ModbusWorkerHandle.isDead` 公共 getter + `_cleanup()` 同步置 `_dead=true` 让 service 端能识别 zombie。
   - `connect()` 新增 zombie 检查（清零后spawn）+ try/catch 包裹 spawn+worker.connect 失败路径（清零后 rethrow）。
   - `disconnect()` fast-path：dead worker 跳过 `await w.disconnect().timeout(5s)` + `await w.shutdown().timeout(5s)` 两步可达 10s 的 reply 等待。
   - `listPorts()` 把 zombie 当作 `_worker==null`，走 transient spawn 路径。
   - `PowerSupplyProvider._onData` 检测 `CommStatus.error` 快照翻 `_connected=false` + 升级到 `error` + `notifyListeners()`（仅 `error`，不碰 `offline` —— 后者是 worker 默认 poll 值）。
   - 测试: `test/serial_worker_lifecycle_test.dart` 7 test PASS；`flutter analyze` 28 issues / 0 新增。
   - 真机 crash 路径 (`Isolate.kill` 外部触发 `_onIsolateExit`) 自动通过 onError 触发该机制；mock 没有故仅单测覆盖 state machine 层面。
   - 修复前: 用户必须手动 DISCONNECT (然后 CONNECT) 或 RECONNECT 才能恢复；修复后: onError 自动清零 + Provider 自动升级为 `CommStatus.error`，UI 即时反馈，无需手动恢复。

7. **`toggleRegView` fire-and-forget 时序** — **OPEN (P1)** UI 端状态可能与 worker 实际 timer 状态短时间内不一致。不致 hang。

## P2 (优化项)

8. **`SerialModbusService._dataController` 永不 close** — long-lived broadcast，设计如此。

9. **`PowerSupplyProvider.dispose` 调用 `_service.disconnect()` 未 await** — 应用退出场景无影响。

10. **罕见 timeout 路径下 libserialport fd 泄漏** — Step 7 VERIFIED ttyUSB 允许并发 open，新 worker 不受旧 fd 影响。fd 仅 OS-level 泄漏 (进程退出回收)，非 connectivity blocker。

## Observations (Phase 1 Release 验证发现，不修复，待真实 GUI 用户场景复现确认)

OBS-1. **release binary 启动 ~110s 后 `[SCHED] pause group=poll` 自动触发，complete=0 持续但 isolate=alive**
- 触发条件：长时启动（>100s）的 release binary 在无人 GUI 操作情况下；30s 短测不复现
- 代码追踪 (Evidence-only)：`_pauseTieredPolling()` 仅在 `_disconnect`/`_shutdown`/worker `pausePoll` 路径调用；UI 端只通过 `toggleRegView()` 用户 tap 触发；无定时器自动调用
- 推测：测试环境（`setsid + redirect + 无 GUI 用户操作 + Wayland session`）触发 widget tree dispose → Provider.dispose() → service.disconnect() → worker pause。但 GApplication 未 quit，binary 进程仍 alive
- 判定：**非构建问题**，属于 widget lifecycle / 窗口管理 / idle session 行为推测。**真实用户场景（持续操作 UI）很可能不复现**
- 决策：**不修复**。当前通信架构冻结，不为推测问题调整生命周期逻辑
- 若未来真实场景复现：可在 `my_application.cc::my_application_shutdown` 中调 `g_application_quit` 强制退出；或 main.dart 加 `WindowListener.onWindowClose` → `provider.dispose()` + `exit(0)`

OBS-2. **release binary 不响应 SIGINT，仅响应 SIGTERM**
- 现象：`kill -INT <pid>` 4s 内不退出；`kill -TERM` 3s 内退出（EXITCODE=143）
- 原因：Flutter Linux GTK 模板 `my_application.cc` 未注册 SIGINT handler；GTK `GApplication` 默认响应 SIGTERM 不响应 SIGINT
- 影响：终端 Ctrl-C 启动的 release binary 不会退出（需关 window 或 SIGTERM）。**不影响正常用户使用**
- 决策：**不修复**。与 OBS-1 合并处理时一并加

# Remaining TODO

P0 修复 + P1-3 修复 + Option B refactor 全部 APPLIED。

- [x] 1. 应用 Patch A.1 (`_WorkerCrashedException` 类定义，最终为私有)
- [x] 2. 应用 Patch A.2 (spawn() listen 分流)
- [x] 3. 应用 Patch A.3 (Isolate.spawn 加 onExit/onError + handshake timeout + spawn 失败清理)
- [x] 4. 应用 Patch A.4 (`_dead` 字段 + `_onIsolateExit` + `forceKill`)
- [x] 5. 应用 Patch B.1 (disconnect 重写含 timeout + forceKill + identical check)
- [x] 6. `fvm flutter analyze` 验证 0 新 issue (43 baseline 全部 pre-existing)
- [x] 7. 运行时验证 ttyUSB 重 open (Step 7 VERIFIED: 允许并发 open，libserialport 不启用 TIOCEXCL)
- [x] 8. 重新评估 Production Ready 判定 (Step 8 verdict: Production Ready for P0 scope)
- [x] 9. 应用 P1-3 修复 (`_cleanup()` 分离状态/资源幂等 + Option B refactor shutdown().then)
- [ ] 10. (可选, P1-1) 修复 `_onPollMiss` 调用 — out of scope 当前会话
- [x] 11. (P1-2) 修复 zombie `_worker` 阻塞自动 reconnect — **已修复 (本次会话)**：service `onError` 改为 `_handleWorkerError`（identical 清零 `_worker` + cancel sub/statTimer + 发 `CommStatus.error` 快照）+ `ModbusWorkerHandle.isDead` getter + `connect()` zombie 检查 + connect-failed cleanup + `disconnect()` isDead fast-path + Provider `_onData` `CommStatus.error` 传播。详见 line 350+ "RESOLVED — P1-2" 章节。
- [x] 12. (Phase B.2) 修复 active OVP/OCP 被 FAST poll M0 storage 覆盖 — **已修复 (本次会话)**：service `_sub.listen` 不让 `snapshot.ovp/ocp` 覆盖 `_current` + `_parseAllRegs` 删除 `r(82)/r(83)` 赋值 + provider `_onData` merged 守卫 + SLOW poll SLOT-sync 把 active slot storage 升到 `_data.ovp/ocp`。register_conflicts & register_definition doc 对齐。详见 line 400+ "RESOLVED — Phase B.2" 章节。

# Constraints

修改禁令与架构约束统一见 `CLAUDE.md` 的 "不要做的事" 章节。本会话额外约束 (已并入 CLAUDE.md):
- 仅修复真正会导致生产不可恢复的问题
- `modbus_worker.dart` 仅允许稳定性修复 (P0/P1)

# Recommended Starting Point (Next Session)

## 当前架构状态（截至 Phase B.2 + register_definition 数据 + docs）

| 项 | 值 |
|---|---|
| 仓库 | `https://github.com/beilusm/RIDEN`（公开，已上线） |
| HEAD (pushed) | `fd428f6 Fix active OVP/OCP synchronization after quickSwitch` |
| HEAD (local, 待 commit) | Phase B.2 register_definition conflict=false + inputVoltageAlt 路径删除 + docs sync |
| Tags | `v1.0.0` (Windows-only 历史) / `v1.0.1` (Latest, FROZEN, 4 assets) |
| 版本来源 5 处 | S1 pubspec `1.0.1+1` ✓ / S2 env.sh `1.0.1` ✓ / S3 env_windows.sh `1.0.1` ✓ / S4 Runner.rc `"1.0.0"` 接受不校验 / S5 metainfo CI 注入 ✓ |
| 通信架构 | ModbusScheduler + polling 间隔 (FAST 150ms / SLOW 1000ms / `_accumulateRead` 250ms) 全部冻结 |
| 寄存器表 | `RegisterDefinition` HR0..HR19 已对齐 datasheet，地址格式 `0xXXXX`；HR14/HR82/HR83 `conflict: false`（Phase B.2 清除） |
| 切换入口 | HR19 quickSwitch 已硬件验证为 Memory Slot 唯一真实切换入口；UI 全部走 `quickSwitch()`，旧 `loadSlot` / `loadMemorySlot` 标 `@Deprecated` 保留；active OVP/OCP = `HR[80 + activeSlot*4 + 2/3]`（Phase B.2 datasheet 确认） |
| `flutter analyze` | 21 issues，0 新增（28 baseline 减去 Phase B.2 修掉的 7 个 register_definition const 警告） |
| `flutter test` | 24/24 PASS |


## Phase B.1 — quickSwitch 稳定性优化（**已 commit `e955627` + 真机回归 PASS**）

代码完成（已固化）：

- **Task 1** — `PowerSupplyProvider.quickSwitch` 中 OVP/OCP 源从 `raw[82]/raw[83]`（M0 存储）改为 `raw[80+slot*4+2/3]`（当前 active slot 存储）。`copyWith` 路径已经过用户澄清：每个 Mx 有自己的 OVP/OCP，存储在 `HR[80+slot*4+2/3]`, HR82/HR83 仅指 M0 自己的存储。
- **Task 2** — `[QSW] before/after` 调试日志打印 HR19/HR8/HR9 + 当前 slot 的 OVP/OCP；新增 `_reg(regs, addr)` 边界安全 helper。
- **Task 3** — `readAllMemorySlots()` 加入抽象接口 + Serial + Mock：
  - Serial: 一次 `readRegisters(80, 40)` = 1 RTU 往返代替原 10 次 `readMemorySlot(i)` 累计 ~2.5s
  - `refreshAllSlots()` 改为单次 bulk read 并打印 `[PROVIDER] refreshAllSlots bulk-read N/10 slots in Xms`
  - `_startBgSlotRefresh()` 改为直接调 `refreshAllSlots()`；删除孤立字段 `_bgSlotIndex`
  - Mock `readRawRegisters` 不再单独填充 regs[82/83]（slot loop 已包含 M0 storage 覆盖）

验证状态（**已通过**）：

- `fvm flutter test test/phaseb1_stability_test.dart` — 5/5 PASS（含 `quickSwitch refreshes ovp/ocp` 断言 `ovp=13.0` `ocp=4.0` 来自 M1 存储 HR86/87）
- `fvm flutter test test/phaseb1_hw_regression.dart`（smoke 部分）— PASS（plumbing OK, HR19 ack ×4, M0 STABLE）
- **真机回归 (PHASEB1_HW=1)** — Verdict: **PASS**
  - HR19 ack (×4): PASS
  - HR8/HR9 forward load (M0→M1, M0→M2): PASS
  - HR8/HR9 reverse (M1→M0, M2→M0): RECORDED (firmware design — HR19=0 = no-op reload)
  - Per-slot OVP/OCP DISTINGUISHED: PASS (M1OVP=6V vs HR82=17V, M2OVP=62V vs HR82=17V)
  - HR82/HR83: INVARIANT (M0 stored)
- `fvm flutter analyze` — 28 issues / **0 新增**（修复时基线）；Phase B.2 后 baseline 降至 21

**后续 followup**: 真机发现 Phase B.1 Task 1 只修了 quickSwitch 路径，FAST poll 仍把 HR82/83 注入 snapshot 并通过 service _sub.listen 覆盖 _current.ovp/ocp — 这个 bug 由 Phase B.2 修复（详见 line 400+ RESOLVED — Phase B.2 章节）。

### 已知设备行为 — Phase B.1 真机首次发现（用户决策：已实施 UI 隐藏）

**HR19=0 不会 reload M0 preset**：

- Phase A.5 已验证 forward load：`HR19=0→1` 触发设备加载 M1 已存 Vset/Iset 到 HR8/HR9（HR8 4.20V→5.00V, HR9 6.100A→5.000A）
- Phase B.1 真机双向回归首次发现 reverse 路径：`HR19=1→0` 不触发设备 reload M0 preset 到 HR8/HR9。HR8/HR9 保持切换前（M1 那一刻）的当前值，并不回到 M0 已存的 Vset/Iset。
- 这不是代码 bug，是设备固件设计：HR19 作为 "active slot 选择器" 时，写 0 后通常被设备理解为 "停留 / 无新选择"，不强制复置活跃寄存器。
- HR82/HR83 同样不随 quickSwitch 变化 — 永远 = M0 自己的存储值（与 datasheet 地址重叠设计一致）。

**UI 当前语义**：

- 用户从 M0 进入 M1..M9 再回到 M0 时，工作寄存器（HR8/HR9）仍显示上一个 slot 的 Vset/Iset。这是设备固件行为，UI 并不主动改写。
- OVP/OCP 由 provider 从 active slot 存储地址读出（Phase B.1 Task 1 修正后），M0 active 时 ovp = HR82/83 = M0 自己的 OVP，表现上无错位。
- 仅 Vset/Iset 有此 "reverse no-reload" 偏差。在用户使用流程中：从 M0 出发切到 Mx → 再切回 M0 = M0 的上次工作值（与 M0 已存 preset 可能不一致）。

**当前决策（用户，已实施）**：M0 = 上电默认数据组，不可通过修改 0x13 寄存器生效。
1. UI 不允许用户主动切回 M0：preset 选择 dialog（`BottomStatus._showPresetDialog` / `SetpointPanel._showPresets`）只显示 M1..M9，不显示 M0 选项。
2. 设备上电时 activeSlot=0（M0）仍是 provider 的初始 state；UI Preset 按钮仍能显示 `M0` 当前 preset 值。
3. 用户主动切到 M1..M9 后不再能从 UI 切回 M0；若用户物理重上电，设备恢复 HR19=0 + M0 preset，UI 在下次 connect 时通过 `readAllMemorySlots()` / `_activeSlot` 同步会感知到 active=0。

**后续候选（未启动）**：
- 若将来 UI 添加 "回到 M0 preset" 显式按钮，可考虑走 legacy `loadMemorySlot(0)` 路径或新增一个 `quickSwitch(0)` + softload(0) 复合路径。
- 现在不实现，**禁止 UI 主动调 `loadMemorySlot(0)`**（违反 @Deprecated 语义）。

## 下一阶段候选入口（按优先级，未启动）

### 1. Phase B.5 — 旧路径残留 audit

目标：确认 `loadSlot` / `loadMemorySlot` 无任何内部调用面后真删除实现。

入口：
```bash
rg "loadSlot\(|loadMemorySlot\(" lib/
fvm dart analyze lib | rg -i deprecated
```
若全清空，再删除 abstract + Serial + Mock + provider 中四处实现；保留 `@Deprecated` 标注本身作为 commit 历史索引。

### 2. Phase C — UI 新字段展示

目标：把 Phase A/A.5/B 新加的 `PowerSupplyData` 字段在 UI 上呈现：

- `firmwareVersion` (HR3) 显示（Dashboard / About 页 / RegisterPage V 列）
- `keyLock` (HR15) 状态徽章（Dashboard 顶部）
- `protectionStatus` (HR16) OVP/OCP/OTP 告警徽章（红色高亮）
- RegisterPage 用户编辑写入路径完善（新字段对应 R/W 入口）

入口：`lib/widgets/dashboard_panel.dart` 或新增 widget；RegisterPage V 列展示 + 编辑对话框。

注意 CLAUDE.md 禁令：不发起新业务功能；本轮用户明确「不启动 Phase C」。

### 3. quickSwitch 延迟优化

目标：当前 `PowerSupplyProvider.quickSwitch` 固定 `await 600ms` 后 readRawRegisters；改为短轮询 (200ms × 最多 5 次) 检测 HR8 是否变为 slot preset target，未变化才退化为固定等待。

入口：`lib/providers/power_supply_provider.dart` 中 `quickSwitch()` 方法。

## 仍 OPEN 的 P1（不致 hang，UX 退化）

### P1-1 `_onPollMiss` 死代码 (`power_supply_provider.dart:184-191`)
- `_consecutiveFails` 永远=0 → `CommStatus.error` 永不达到，UI 仅升级到 `timeout`。
- 修复：在 FAST/SLOW poll miss 路径接入 `_onPollMiss()` 调用 → `_consecutiveFails++` → 触发 error 状态机。
- 验证：`fvm flutter analyze` + runtime log 检测 `CommStatus.error` 是否出现。

### P1-2 zombie `_worker` 阻塞自动 reconnect (`serial_modbus_service.dart:30-32`) — RESOLVED
- worker crash 后 `onError` 回调只 debugPrint 不置 `_worker = null`，connect() 两级守卫拒绝。
- 修复（已实施）：见上方 "RESOLVED — P1-2" 章节（line 350+）。
- 验证：`fvm flutter analyze` 28/0 + `fvm flutter test` 25/25 PASS + `test/serial_worker_lifecycle_test.dart` 7 test 单独也 PASS。

## 延期长后续版本（v1.1+，见 Phase 3 "Not Implemented"）

- zsync / `--updateinformation` — AppImage 增量自动更新
- GPG 签名 — `appimagetool -s` + 签名密钥
- GitHub Actions CI — `packaging/scripts/build_release.sh` 迁移到 workflow（已超期：Phase L1.1/L1.2 已实施）
- 多 distro 自动测试 — Ubuntu 22.04 / 24.04 / Fedora / Debian 测试矩阵
- Runner.rc VERSION_AS_STRING 自动同步 (S4)
- dev CI APP_VERSION 校验 (Phase L1.3)

# Session Summary (本次会话最终交付)

## Final Changes Made

### `lib/services/modbus_worker.dart`

1. **Patch A.1** (line 9-20): 新增私有 `_WorkerCrashedException implements Exception` 类。下游通过 generic `catch (e)` 接收；本库内用于区分 dead-worker 与普通 Modbus timeout。

2. **Patch A.2** (line 534-560): 重写 `spawn()` 的 `uiPort.listen` 回调。handshake 前分流 4 种消息 (SendPort / null / 2-element List / other) → 后三者走 `handshake.completeError`；handshake 后通过 `handle._dead` 早返保护处理 late 消息，`null`/2-element List 分流到 `_onIsolateExit`，其他到 `_onMessage`。

3. **Patch A.3** (line 562-582): `Isolate.spawn` 添加 `onExit: uiPort.sendPort, onError: uiPort.sendPort` 命名参数 (避免 listener-race，Verified Fact #13)。`handshake.future` 加 5s timeout。`try/catch` 包裹: 失败时 `isolate?.kill` + `uiPort.close` 后 `rethrow`。

4. **Patch A.4** (line 523 `_dead` field; line 591-601 `_onIsolateExit`; line 603-611 `forceKill`): 
   - `bool _dead = false` 管 notification/completer 幂等。
   - `_onIsolateExit` 完成所有 pending 为 `_WorkerCrashedException(reason)`，回调 `onError?.call(reason)`，调 `_cleanup()`。
   - `forceKill` 设置 `_dead=true`，完成后置 pending 为 `'forced kill'`，调 `_cleanup()`。

5. **P1-3 Fix** (line 524 `_cleaned` field; line 613-619 `_cleanup()`): 
   - `bool _cleaned = false` 管资源清理幂等。
   - `_cleanup()` 顺序: `_dataController?.close()` → `_uiPort.close()` → `_isolate.kill(immediate)`，每个 try/catch。
   - `_onIsolateExit` 末尾调 `_cleanup()` — crash 即清理，不依赖后续 disconnect 触发。

6. **Option B Refactor** (line 698-700): `shutdown().then(...)` 改为单行 `_cleanup();`。`_cleanup()` 成为唯一资源清理权威；消除原 latent race (`_isolate.kill` 对已死 isolate 未文档化 no-throw 行为)。

### `lib/services/serial_modbus_service.dart`

7. **Patch B.1** (line 106-135): `disconnect()` 重写。捕获 `_worker` 到 local `w` (避免 await 后 null-promotion 丢失)。`await w.disconnect().timeout(5s)` + `await w.shutdown().timeout(5s)` 各自 try/catch。始终调 `w.forceKill()`。`if (identical(_worker, w)) _worker = null;` 防 concurrent connect race。worst-case 阻塞 10s → 自动 unlock reconnect。

## Remaining Known Issues

### OPEN — P1-1: `_onPollMiss` 死代码 (`power_supply_provider.dart:184`)
- 影响: `CommStatus.error` 永不达到，UI 健康检查仅升级到 `timeout`。UX 退化但不致 hang。
- 修复建议: 在 FAST/SLOW poll miss 路径接入 `_onPollMiss()` 调用。

### RESOLVED — P1-2: Zombie `_worker` 阻塞自动 reconnect (`serial_modbus_service.dart:30-32`)
- 影响: worker crash 后 `onError` 回调只 debugPrint，不置 `_worker = null`，不通知 Provider；connect() 在 service (line 28) 和 provider (line 71) 两级守卫均静默拒绝。用户必须手动 DISCONNECT + CONNECT 或 RECONNECT 才能恢复。
- **修复实施 (本次会话)**:
  1. `ModbusWorkerHandle` 新增 `bool get isDead => _dead;` 公共 getter (`modbus_worker.dart`)；`_cleanup()` 同步置 `_dead = true`（之前 `_cleanup` 仅置 `_cleaned`，`isDead` 在 `shutdown()` 路径不返回 true）。
  2. `SerialModbusService` 新增 `_handleWorkerError(String)` 方法（替代原 `onError` 中只 debugPrint 的匿名 lambda）：identical-ptr 校验清空 `_worker` + 取消 `_sub` / `_statTimer` + 通过 `_dataController` 发送 `CommStatus.error` 快照。
  3. `SerialModbusService.connect()` 增加 zombie 检查：if `_worker != null && _worker!.isDead` — 清理 + 取消 statTimer / sub 后再 spawn；同时把 spawn + 子端口连接包裹进 try/catch，连接失败时 `forceKill + null (_worker)` 并 rethrow（之前 port-open 失败会留下一个 spawn 但未连接的 zombie handle 阻塞后续 reconnect）。
  4. `SerialModbusService.disconnect()` 增加 `isDead` fast-path：dead worker 不再 `await w.disconnect().timeout(5s)` + `await w.shutdown().timeout(5s)`（两步合计可达 10s，dead worker 不会 reply），直接 `forceKill` + null。
  5. `SerialModbusService.listPorts()` 同步把 zombie 视为 `_worker == null` — 走 transient spawn 路径，避免对 dead handle 调 `listPorts()` hang。
  6. `PowerSupplyProvider._onData` 增加 worker-crash 传播分支：snapshot.commStatus 为 `CommStatus.error` 时（仅由 service 的 `_handleWorkerError` 发出，**不是** `offline` — 后者是 worker 默认 poll 快照值，会被错误识别为 crash），翻转 `_connected = false` + 清理 `_bgSlotTimer` / `connectedPort` + 升级 `_data.commStatus = error` + `notifyListeners()`；不重置 `_lastPollOk` / `_consecutiveFails`；不 append chartData（crash 不是测量），`wasConnected=false` 时短路（idempotent 多次 crash）。
- **测试**: `test/serial_worker_lifecycle_test.dart` 7 个 test 覆盖 ModbusWorkerHandle.isDead 三态（spawn / forceKill / shutdown）+ Provider crash 传播 + 幂等 + 正常快照不被误判。
- **验证**: `flutter analyze` 28 issues / 0 新增；`flutter test` 25/25 PASS（含 18 旧 + 7 新）。
- **CLAUDE.md 一致性**: 严格遵守禁令 — `ModbusScheduler` / FAST 150ms / SLOW 1000ms / `_accumulateRead` 250ms / register schema / quickSwitch 全部未改动；仅 `modbus_worker.dart` 添加 `isDead` getter 与 `_cleanup()` 一行 `_dead = true` 同步（P1 稳定性修复允许）。
- **后续**: `onError` 路径仅在真机 / 真实进程 trigger isolate crash 时才触发；mock 没有 isolate 故单测仅覆盖 state machine 层面（`simulateCrash()` helper 直接注入 `CommStatus.error` 快照）。真机 crash 回归可在断电 / 拔 USB 场景手动验证 UI 是否升级到 `CommStatus.error` 且 Reconnect 按钮亮起。

### RESOLVED — Phase B.2: Active OVP/OCP 被 FAST poll M0 storage 覆盖 (`serial_modbus_service.dart` / `power_supply_provider.dart`) — RESOLVED
- **症状**: `quickSwitch(1)` 切到 M1 后，UI 的 OVP/OCP 闪现 M1 正确值 ≤150ms 就回退到 M0 stored，并保持不变。
- **根因**: Modbus worker FAST poll 硬读 HR5..83 → `snap.ovp/ocp` = HR82/HR83（M0 storage，与 active slot 无关）。service `_sub.listen` 中 `isFast ? snap.ovp : _cur.ovp` 让 FAST 每周期把 M0 storage 覆盖进 `_current.ovp/ocp`，provider `_onData` 透传 → `_data` 回退。quickSwitch fullPoll 写入的正确 active slot 值活不过一个 FAST 周期。
- **datasheet clarification (Phase B.2)**: HR82/HR83 永远是 M0 Memory Slot OVP/OCP storage；active OVP/OCP 由 HR19 当前 slot 决定，地址 = `HR[80 + activeSlot*4 + 2/3]`（M0=82/83, M1=86/87, M2=90/91, …）。设备无独立"顶层 OVP/OCP"寄存器。
- **修复 (三层守卫 + 一次同步)**:
  1. `SerialModbusService._sub.listen` (serial_modbus_service.dart:90-91)：`ovp/ocp` 不再让 `snapshot.ovp/ocp` 覆盖 `_current`，改为 `ovp: _current.ovp, ocp: _current.ocp`。worker FAST snap 的 HR82/83 字段从此被丢弃。
  2. `SerialModbusService._parseAllRegs` (serial_modbus_service.dart:422-430)：删除 `ovp: r(82)/100.0, ocp: r(83)/1000.0` 赋值。service 不知 active slot，无权发 active 保护值；readAllRegisters 返回时 ovp/ocp 走 PowerSupplyData default。
  3. `PowerSupplyProvider._onData` merged.copyWith (power_supply_provider.dart:200-209)：`ovp: _data.ovp, ocp: _data.ocp` — 双保险，防 service 默认值被透传污染 _data。
  4. `PowerSupplyProvider._onData` SLOT-sync (power_supply_provider.dart:226-242)：snapshot.memorySlots 非空时，找到 `s.index == _activeSlot` 把 `s.ovp/ocp` 升到 `_data`，SLOW poll 每 ~5s 一个完整 slot 循环刷新一次。
- **Phase B.2 docs + register_definition 数据 (本次会话末追加)**:
  - commit `b1f3ad3` (已 push): register_conflicts.dart 4 条 conflict resolution — address 14 / 82 / 83 / 2 标 [RESOLVED] + resolution 字段写 datasheet clarification 详情；issue/codePaths 历史保留。
  - commit `fd428f6` (已 push): 上述三层守卫 + SLOT-sync 代码修复。
  - 本地未 commit: register_definition.dart HR14/HR82/HR83 `conflict: false`（RegisterPage 感叹号 0x0E/0x52/0x53 消失）+ HR82/HR83 `name: 'M0 OVP'/'M0 OCP'` 与 M1..M9 _slotDef 命名一致 + HR14 description 改"输入电压（读取值 ÷ 100 = 实际电压 V）"；`serial_modbus_service.dart` `_parseAllRegs` 删除 `inputVoltageAlt: r(14) / 10.0`；`mock_modbus_service.dart` 删除 `inputVoltageAlt: _vIn`；7 个 register_definition prefer_const_constructors warnings 顺手修掉（const 加到 5 个 RegisterDefinition 调用）。
- **测试**: `fvm flutter test` 24/24 PASS（含原 18 + 7 P1-2 worker lifecycle + Phase B/B.1 快照覆盖，mock 中 inputVoltageAlt = 0 不影响任何断言）。未新增 Phase B.2 单测（mock 无 active slot 概念，运行时多层守卫只能在真机或更复杂的 fake service 中验证）；真机回归建议手动验证 quickSwitch(0/1/2) 各 5s 后 UI 仍稳定。
- **验证**: `fvm flutter analyze` 21 issues / 0 新增（28 baseline 减去 7 个 register_definition prefer_const_constructors 修掉）。
- **CLAUDE.md 一致性**: 严格遵守禁令 — `ModbusScheduler` / FAST 150ms / SLOW 1000ms / `_accumulateRead` 250ms / quickSwitch 逻辑 / setOCP/setOVP 写入路径全部未改动；`register_conflicts.dart` 仅改文档字段（resolution + title），未删 issue/codePaths；`register_definition.dart` 仅改 `name` / `description` / `conflict` bool / const 关键字，未改 `address` / `access` / `scale` / `dashboardField` 等结构字段。
- **未做 (后续候选)**:
  - write 路径 reroute: `setOVP(v)` 仍 `writeRegister(82, ...)` — active≠0 时改不到 active slot OCP。需要 datasheet 写入语义硬件验证（Phase B.3 候选）。
  - PowerSupplyData.inputVoltageAlt 字段标 `@Deprecated` 并删除：当前保留为 default 0，无任何代码路径赋值，但字段本身仍在 copyWith / dartdoc 中。
  - quickSwitch(0) 不 reload M0 preset — 设备固件设计使然，UI 语义待决策（见 Phase B.1 已知设备行为章节）。


### Pre-existing — P2
- `SerialModbusService._dataController` 永不 close (设计如此, long-lived broadcast)。
- `PowerSupplyProvider.dispose` 调用 `_service.disconnect()` 未 await (应用退出无影响)。
- 罕见 timeout 路径下 libserialport fd 泄漏 → OS-level descriptor 泄漏 (1 fd/cycle, 进程退出回收)，已 VERIFIED 不阻塞 connectivity (Step 7)。

## Production Readiness Assessment

**Verdict: Production Ready — for P0 scope (forced hang elimination).**

### 三项原 P0 全部 RESOLVED，证据级别:
| P0 | 修复 Patch | 证据 |
|---|---|---|
| 1. Worker crash 无感知 | A.2 + A.3 + A.4 | [Project Source] 控制流追踪 + [SDK] onExit/onError 文档保证 + Step 8 audit |
| 2. disconnect/shutdown 无 timeout | B.1 | [Project Source] 实现读 + 5s+5s timeout 兜底 + forceKill 兜底 |
| 3. spawn/handshake hang/leak | A.3 | [Project Source] try/catch + 5s timeout + uiPort.close + rethrow |

### P1-3 (本次会话新发现并修复) RESOLVED
- 引入 `_cleanup()` 单点资源清理 + `_cleaned` 与 `_dead` 分离状态/资源幂等。
- 4 条路径 (normal shutdown / crash / crash+disconnect / crash+reconnect) 均无泄漏。
- Step 7 VERIFIED ttyUSB 允许并发 open，libserialport fd 泄漏不阻塞新 worker。

### 唯一 open 的 UNKNOWN ② 已 VERIFIED
- `ttyUSB` 在旧 fd 未 close 时第二次 `open()` 成功 (Linux char device 默认非独占，libserialport 不调用 TIOCEXCL)。
- 测试: 临时测试程序 (V1/V2/V3 均成功；V4 TIOCEXCL 启用后才拒绝)。

### Failure Scenario Audit (Step 8)
| Scenario | Pre-patch | Post-patch |
|---|---|---|
| Worker crashes mid-session | UI hang — 唯一恢复是杀应用 | UI 显示 timeout；手动 disconnect→connect 恢复 |
| `disconnect()` while worker stuck | 永久 hang → reconnect 永远失败 | 5s+5s timeout → forceKill → 10s 内可 reconnect |
| `Isolate.spawn` 失败 | ReceivePort 泄漏 + UI hang | 5s 内清理 + rethrow |
| Pending Future completion on crash | 永远 pending → 调用方 hang | `_onIsolateExit` completes all with `_WorkerCrashedException` |
| 100× connect/disconnect stress | 正常路径 OK | 同 — `forceKill` 在 clean path 早返 (no-op) |
| 100× crash + reconnect stress | 第 1 次就 hang | 每 cycle ~10s 完成；P1-3 修复后不再累积 leak |

### Confidence levels (Step 8 + Self-Audit):
- P0 修复机制: [2] CODE-DIRECT (代码控制流可追踪) + [1] SDK-DIRECT (onExit/onError, errorsAreFatal 默认值, ReceivePort.close 行为)。
- P1-3 资源泄漏机制: [2] CODE-DIRECT (close 调用确认跳过)。
- ttyUSB concurrent open: [4] RUNTIME-VERIFIED。
- Memory 永久滞留 (P1-3 修复前的潜在隐患): [3] INFERENCE (Dart VM port registry 强引用 GC root — 公开 API 仅文档化 "keep isolate alive" 行为，未文档化强引用机制)。修复后通过显式 close 不再依赖此 inferred 链 — `_cleanup()` 释放后 ReceivePort 关闭，listener 收到 done event 解注册，handle 通过 closure 的 reachability 链断裂，handle 变 GC-eligible。

### 不建议立即发版的理由
仍存在两项 P1 (P1-1, P1-2) 影响 UX (状态机退化 + 手动恢复要求)。这些不阻塞生产环境部署，但在生产中频繁 crash 时会暴露为 UI 体验差。建议下个迭代处理。当前代码对 P0 hang 域**生产可用**。

### Analyze 状态
`fvm flutter analyze` 43 baseline issues (全部 pre-existing)。**0 新 issue 由本次 Patch A-B + P1-3 + Option B 引入**。

---

最后修改时间: 本会话结束。下次会话从 `# Recommended Starting Point (Next Session)` 章节继续。

---

# Phase 2 — Linux Desktop Integration (APPLIED)

## Files Added

- `linux/icons/hicolor/{16x16,32x32,48x48,64x64,96x96,128x128,256x256,512x512}/apps/io.github.beilusm.ridenps.png`
- `linux/icons/hicolor/index.theme`
- `linux/applications/io.github.beilusm.ridenps.desktop` (12 字段，StartupWMClass 指向 App ID)
- `linux/metainfo/io.github.beilusm.ridenps.metainfo.xml` (~93 行，21 OARS 1.1 attrs 全 none，1 release 1.0.0)
- `linux/udev/99-riden-ch34x.rules` (CH340 1a86:7523 + CH341 1a86:7522，MODE 0666，ModemManager ignore)

## Files Modified

- `linux/CMakeLists.txt:10` — `APPLICATION_ID` 改为 `io.github.beilusm.ridenps`，新增 4 install rules (icons / .desktop / metainfo / udev) + gtk-update-icon-cache
- `linux/runner/my_application.cc:28` — 加 `gtk_window_set_default_icon_name(APPLICATION_ID)`
- `README.md` — 新增 4 章节（Linux 串口权限 / Release 构建 / 系统安装 / 项目结构）
- `.gitignore` — 完整化（补充 build/ / .dart_tool/ / .idea/ / .fvm/ / ephemeral / Phase 3 产物）
- `CLAUDE.md` — 架构铁律与修改禁令收敛（单一权威文件）
- 本文件 — 新增 OBS-1 / OBS-2 Observations 章节

## Verification

- `desktop-file-validate`: 0 error / 0 hint
- `appstreamcli validate --no-net`: 0 error / 0 warning (3 url-not-reachable 因 GitHub 未上线，用 `--no-net` 绕过)
- `udevadm verify`: 通过
- clean build + `fvm flutter analyze`: 43 baseline，0 新 issue
- bundle 启动 30s 短测稳定，SIGTERM 3s 内退出 (EXITCODE=143)

## Known Issues (Phase 2)

- AppStream 3 个 `url-not-reachable` warning — GitHub repo `https://github.com/beilusm/RIDEN` 尚未上线，暂用 `--no-net` 绕过；repo 上线后需重新校验。

---

# Phase 3 — Release Engineering (APPLIED)

收敛建议：仅 `packaging/`，4 个脚本，不加 zsync / GPG / CI / 多 distro 测试。

## Files Added

- `packaging/config/env.sh` — 单一配置源（App ID / 版本 / URL / 路径解析）
- `packaging/scripts/fetch_tools.sh` — 下载 `runtime-x86_64`（923KB）+ preflight `appimagetool`
- `packaging/scripts/make_appimage.sh` — 5 阶段手工 AppDir + appimagetool
- `packaging/scripts/compute_checksums.sh` — 生成 SHA256SUMS + Release Notes（从 metainfo 抽）
- `packaging/scripts/build_release.sh` — 总入口（fetch → flutter build → make → checksums）

## Files Modified

- `.gitignore` — 补充 `/packaging/tools/` / `/release/` / `*.AppImage` / `*.AppImage.zsync`，并完善 Flutter / Dart / IDE 产物排除
- `README.md` — 新增"发布工程（AppImage 打包）"章节（前置依赖 / 一条命令发布 / 流水线 / 设计要点 / 调试模式）
- `CLAUDE.md` — 新增 Phase 3 发布工程铁律（不引入 linuxdeploy/plugin-gtk / 不在 AppRun 设环境变量 / 不改 env.sh App ID-Version / 不入库构建产物 / v1.0 不引入 zsync·GPG·CI）；更新"当前 Patch 状态"反映 Phase 2 + Phase 3 全部 APPLIED

## Architecture Decision

**方案 B (linuxdeploy + plugin-gtk + appimagetool)** → **被否决**。实测 `linuxdeploy-plugin-gtk` 在 AppRun 时 source 的 hook 强制 `export GDK_BACKEND=x11` 和 `export GTK_THEME=Adwaita:...`，破坏用户系统的 HiDPI 主题 / font-scaling-factor（GL frame size 从 2712x1616 退到 1346x1616，2x 缩放失效）。

### 否决证据

**plugin-gtk hook 路径**：`<AppDir>/apprun-hooks/linuxdeploy-plugin-gtk.sh`（由 linuxdeploy stage 4 自动生成，AppRun 顶部 `source` 该文件）

**关键破坏行**（hook 第 17 行 + 第 16 行）：
```bash
export GDK_BACKEND=x11          # 强制 X11，Wayland 原生 HiDPI 缩放失效，退到 XWayland
export GTK_THEME="Adwaita:..."  # 覆盖用户系统主题，font-scaling-factor 失效
```

**实测对比**（同机器、同 bundle、同窗口尺寸）：
| 方案 | GL frame size | HiDPI 状态 | 体积 |
|---|---|---|---|
| `flutter build linux --release` 裸 bundle | 2712×1616 | 正常 (2x) | 25 MB 目录 |
| linuxdeploy + plugin-gtk AppImage | 1346×1616 | **失效** (1x) | 43 MB |
| 手工 AppDir + appimagetool (采用) | 2712×1616 | 正常 (2x) | 9.9 MB |

**用户双击 AppImage 验证**：UI 比例恢复正常。

**采用方案：手工 AppDir + 系统 appimagetool**
- `AppRun` 脚本仅 9 行，**不设任何 GDK_BACKEND / GTK_THEME / GTK_PATH 环境变量**
- 等价于 `flutter build linux --release` 裸 bundle 的运行环境
- 依赖系统 GTK3（所有 Linux 桌面发行版自带），代价是从 43MB 降到 9.9MB（不再 bundle GTK3 runtime，且 squashfs zstd 压缩）
- HiDPI 验证通过（用户双击 AppImage 确认比例正常）

## Pipeline

```
build_release.sh
  ├─ fetch_tools.sh        → 下载 runtime-x86_64 到 packaging/tools/
  ├─ fvm flutter build linux --release
  │                          → build/linux/x64/release/bundle/{riden_power_supply,lib,data}
  ├─ make_appimage.sh
  │   ├─ Stage 1 清空 AppDir
  │   ├─ Stage 2 cp Flutter bundle → AppDir/
  │   ├─ Stage 3 cp .desktop / icons / metainfo → AppDir/usr/share/
  │   ├─ Stage 4 写 AppRun + 根目录 symlink (.DirIcon / .desktop / .png)
  │   └─ Stage 5 appimagetool --runtime-file → 9.9MB .AppImage
  └─ compute_checksums.sh
      ├─ SHA256SUMS                              (106 bytes)
      └─ RELEASE_NOTES-1.0.0.md                 (1.3KB，从 metainfo 抽取)
```

## Final Deliverables (in `release/`, gitignored)

- `RIDEN_PowerSupply-1.0.0-x86_64.AppImage`  (9.9 MB)
- `SHA256SUMS`                                (106 bytes)
- `RELEASE_NOTES-1.0.0.md`                    (1.3 KB)

## Verification

- `build_release.sh` 端到端跑通（fetch → build → make → checksums）
- `sha256sum -c SHA256SUMS` 校验成功
- AppImage 启动测试：`[SCHED_STAT] isolate=alive` 正常；GL frame size 2712x1616 (HiDPI 正常)
- `fvm flutter analyze`: 43 baseline，0 新 issue
- AppRun hook 无破坏性环境变量（diff 验证）

## Not Implemented (延期到后续版本)

- **zsync / `--updateinformation`** — 第一版无自动更新
- **GPG 签名** — 第一版无签名
- **GitHub Actions CI** — 本地一条命令即可发布
- **多 distro 自动测试** — 仅本机 Arch 验证
- **linuxdeploy / linuxdeploy-plugin-gtk** — 因 HiDPI 兼容性问题否决

## Known Issues (Phase 3)

- `release/AppDir/` 是中间产物，会在每次 build 时被清空重建
- AppImage 依赖系统 GTK3 — 用户发行版必须有（所有桌面发行版自带，但最小 server 镜像可能缺；README 已说明）
- AppStream metainfo 3 个 `url-not-reachable` warning 仍未解决（继承 Phase 2 状态）

---

# Phase W1 — Windows Resource + ZIP Pipeline (APPLIED)

收敛建议：仅 `windows/runner/` 资源补全 + `packaging/` 新增 Windows 脚本，不引入安装器（Inno Setup / NSIS / MSIX）/ 代码签名 / GitHub Actions CI。最终交付物为单个可分发 ZIP。

## Files Added (Linux 端可独立完成)

- `packaging/config/env_windows.sh` — Windows 单一配置源（APP_ID / Version / Bundle 路径 / ZIP 命名）
- `packaging/scripts/make_windows_zip.sh` — Python zipfile 打包 + 生成 MANIFEST + SHA256SUMS
- `packaging/scripts/build_windows_release.sh` — 总入口（flutter build → make_zip，2 步流水线）

## Files Modified

- `windows/runner/Runner.rc` — 4 个字符串字段：CompanyName `com.example`→`beilusm` / FileDescription `riden_power_supply`→`RIDEN Power Supply` / LegalCopyright 同步 / ProductName 同步
- `windows/runner/main.cpp:30` — 窗口初始标题 `riden_power_supply`→`RIDEN Power Supply`（main.dart 仍会用 `windowManager.setTitle` 覆盖为 `RIDEN Digital Power Supply`）
- `windows/runner/resources/app_icon.ico` — 从 Flutter 默认 33KB 替换为 20KB 6 尺寸（16/32/48/64/128/256）全 PNG-compressed ICO；从 Linux Phase 2 8 尺寸 PNG 原生合成（手工 ICO 构造器，保留各尺寸设计细节）
- `.gitignore` — 追加 `RIDEN_PowerSupply-*-windows-*.zip` + `SHA256SUMS-windows.txt` 兜底
- `README.md` — 新增"Windows Release 构建（ZIP 打包）"章节（前置依赖 / 一条命令 / 流水线 / 用户使用说明：CH340 驱动 / SmartScreen 警告 / VC++ Runtime 提示）
- `CLAUDE.md` — 新增 Phase W1 Windows 发布铁律 7 条 + 更新当前 Patch 状态含 Phase W1

## 不修改 (冻结)

- `windows/runner/runner.exe.manifest` — PerMonitorV2 DPI + Win10/11 supportedOS 已正确
- `windows/runner/CMakeLists.txt` / `windows/CMakeLists.txt` — Flutter 默认模板自包含 bundle 结构已可用
- `lib/**/*.dart` — 所有业务逻辑、通信层、Provider、Widget 均未触碰
- `windows/runner/Runner.rc` 的 `FileVersion` / `ProductVersion` / `OriginalFilename` — Flutter 工具链自动注入

## Architecture Decision

**安装器方案 (Inno Setup / NSIS / MSIX / 代码签名)** → **v1.0 不实施**。用户明确指令："不要设计安装程序，也不要实现 Inno Setup"。本阶段唯一目标：产出一个稳定、可直接分发的 Windows Release ZIP。

### 否决理由

| 方案 | 否决理由 |
|---|---|
| Inno Setup 6 | v1.0 不引入安装器；用户可直接解压 ZIP 双击 .exe 运行 |
| NSIS | 同上 |
| MSIX | 用户明示不发布 Microsoft Store |
| 代码签名 | EV/OV 证书成本 $200-400/年；v1.0 在 README 说明 SmartScreen 警告为正常现象 |
| 7z 安装包自解压 | ZIP 已足够；7z 自解压 exe 同样触发 SmartScreen，无优势 |

**采用方案：`flutter build windows --release` 裸 bundle + Python zipfile 打包成 ZIP**

- 用户解压 ZIP 即得到 `RIDEN_PowerSupply/` 文件夹，双击 `riden_power_supply.exe` 即运行
- ZIP 内同时写入 `RIDEN_PowerSupply/MANIFEST.txt`（文件清单 + 每个 SHA256）便于用户校验完整性
- 等价于 `flutter build windows --release` 产出的 `Release/` 目录，仅顶层目录名改为 `RIDEN_PowerSupply`
- 不依赖 7-Zip / Inno Setup / NSIS / Windows SDK bin — **唯一依赖 Python 3**（Flutter Windows 工具链必装项）

## Pipeline

```
build_windows_release.sh
  ├─ fvm flutter build windows --release
  │                          → build/windows/x64/runner/Release/{riden_power_supply.exe, flutter_windows.dll, data/, *.dll}
  └─ make_windows_zip.sh
      ├─ preflight            → 校验 5 必备文件 (exe/dll/icudtl.dat/app.so/AssetManifest.json)
      ├─ Python zipfile       → 遍历 bundle + 计算 SHA256 + 生成 MANIFEST.txt
      ├─ write zip            → RIDEN_PowerSupply/MANIFEST.txt + RIDEN_PowerSupply/<bundle contents>
      └─ sha256sum            → 生成 release/SHA256SUMS-windows.txt
```

## Final Deliverables (in `release/`, gitignored)

- `RIDEN_PowerSupply-1.0.0-windows-x64.zip`  (预计 ~15 MB，等 Phase W2 实测)
  - 解压后内含：`RIDEN_PowerSupply/riden_power_supply.exe` + `flutter_windows.dll` + 3 个插件 DLL + `data/icudtl.dat` + `data/app.so` + `data/flutter_assets/` + `MANIFEST.txt`
- `SHA256SUMS-windows.txt`  (~74 bytes)

## Verification (Linux 端可独立完成的部分)

- `fvm flutter analyze`: 43 baseline，0 新 issue（无 Dart 改动，预期不影响）
- `bash -n` 三个脚本语法全部 OK
- mock bundle 端到端跑通：
  - preflight 正确拒绝缺失 bundle
  - preflight 通过 5 必备文件齐全
  - 9 entries 写入 ZIP（8 个 bundle 文件 + MANIFEST.txt）
  - 顶层目录名正确：`RIDEN_PowerSupply/`
  - SHA256SUMS-windows.txt 生成成功
  - `sha256sum -c SHA256SUMS-windows.txt` 验证成功
  - ZIP 内部路径全部用 forward slash（跨平台安全）
  - MANIFEST.txt 内含 8 行文件清单 + SHA256
- Runner.rc 4 个字段从 `com.example` / `riden_power_supply` 改为 `beilusm` / `RIDEN Power Supply`
- app_icon.ico: 6 尺寸 PNG-compressed, 20,504 B（vs Flutter 默认 33 KB / ImageMagick BMP 368 KB）
- main.cpp 窗口标题改为 `RIDEN Power Supply`
- 无 `Platform.isWindows` / `kDebugMode` / `kReleaseMode` / `assert` 副作用 — Dart 业务代码 Release 安全

## Phase W2 — Windows 实测清单 (待用户在 Windows 主机执行)

### 步骤 W2.1：构建 + 打包

1. 在 Windows 10/11 主机：Visual Studio 2022 + Flutter 3.44+ + FVM + Python 3 + Git Bash/WSL
2. `fvm flutter pub get`
3. `bash packaging/scripts/build_windows_release.sh`
4. 验证产物：
   - `release/RIDEN_PowerSupply-1.0.0-windows-x64.zip` 存在且 ~15 MB
   - `release/SHA256SUMS-windows.txt` 存在
   - `cd release && sha256sum -c SHA256SUMS-windows.txt` → "成功"

### 步骤 W2.2：Release bundle 完整性（解压即可独立运行）

5. 在干净目录（不进 Flutter SDK 仓库）：解压 ZIP
6. 验证目录结构：
   ```
   RIDEN_PowerSupply/
     MANIFEST.txt
     riden_power_supply.exe           ~5 MB
     flutter_windows.dll              ~8 MB
     flutter_libserialport_windows.dll
     screen_retriever_windows_plugin.dll
     window_manager_plugin.dll
     data/icudtl.dat                  ~10 MB
     data/app.so                      ~5 MB
     data/flutter_assets/             ~1 MB
   ```
7. `man RIDEN_PowerSupply/MANIFEST.txt` 检查文件清单和 SHA256 一致

### 步骤 W2.3：未签名 SmartScreen 警告验证

8. 双击 `riden_power_supply.exe`
9. 首次启动预期看到 Windows SmartScreen "Windows 已保护你的电脑"
10. 点击 "更多信息 → 仍要运行" 应可启动（README 已说明）

### 步骤 W2.4：应用启动与 UI 验证

11. 窗口标题显示 `RIDEN Digital Power Supply`（来自 main.dart:15，覆盖 main.cpp 初始标题）
12. 任务栏图标显示为 RIDEN logo（非 Flutter logo）
13. Dashboard 显示正常（无设备时 UI 不应崩溃，serial panel 显示空端口列表）
14. 关闭窗口应正常退出（无僵尸进程残留 — Task Manager 检查）

### 步骤 W2.5：串口通信验证

15. 插入 CH340 USB-Serial 适配器 → Windows Update 自动安装驱动 → 出现 `COMx` 端口
16. 在应用 serial panel 中应看到 `COMx` 选项
17. 连接 RIDEN 设备 → Dashboard 应显示实时 V/A/W
18. Worker isolate 生命周期：连接 → 启动 FAST/SLOW poll → 数据流 `[SCHED_STAT] complete=... isolate=alive`
19. 断开 → isolate 干净停止
20. 多次 connect / disconnect 循环无 hang / 无 zombie 进程

### 步骤 W2.6：exe 属性信息验证

21. 右键 `riden_power_supply.exe` → 属性 → 详细信息
22. 验证字段：
   - CompanyName: `beilusm` ✓
   - FileDescription: `RIDEN Power Supply` ✓
   - FileVersion: `1.0.0.1` (Flutter 自动注入) ✓
   - ProductName: `RIDEN Power Supply` ✓
   - ProductVersion: `1.0.0.1` ✓
   - LegalCopyright: `Copyright (C) 2026 beilusm. All rights reserved.` ✓
   - OriginalFilename: `riden_power_supply.exe` ✓

### 步骤 W2.7：干净环境测试（推荐）

23. 在未安装 Visual Studio / Flutter SDK / Python 的 Windows 10/11 虚拟机中解压 ZIP
24. 双击 exe 应能启动（验证不依赖开发环境 DLL）

### W2 失败回退

任意步骤失败，请反馈：
- 失败步骤号 + 完整错误信息
- 主机 Windows 版本（10/11，build 号）
- Visual Studio 版本 + 工作负载列表
- 插入 CH340 设备前的 Device Manager 串口列表
- 失败时的 Task Manager 进程列表截图

## Not Implemented (Windows 延期到后续版本)

- **Inno Setup / NSIS / MSIX** — v1.0 不引入安装器，用户直接解压 ZIP 双击 exe
- **代码签名** — v1.0 不签名，SmartScreen 警告由 README 说明
- **EV/OV 证书** — 视 v1.1+ 市场反馈决定
- **GitHub Actions Windows CI** — Linux 无法运行 `flutter build windows`，需 Windows runner
- **跨平台 CI 矩阵** — 不在 v1.0 范围
- **MSIX 旁加载包** — 不发布 Microsoft Store 即不需要
- **ARM64 Windows 构建** — 当前仅 x64

## Known Issues (Phase W1)

- **未签名 exe 触发 SmartScreen 警告** — 已在 README 用户使用说明中提示，v1.1+ 签名后消除
- **GitHub repo 未上线** — 与 Phase 3 共享状态，待 push 到 `https://github.com/beilusm/RIDEN` 后才能上传 v1.0.0 Release
- **干冷 Windows 环境未实测** — Phase W1 仅 Linux 端 mock bundle 端到端测试，真实构建验证等 Phase W2
- **CH340 自动驱动安装需联网** — 首次插入需 Windows Update；离线环境需手动从厂商安装 `CH341SER.EXE`
- **COM10+ 可能需要管理员权限** — 当前 manifest 默认 `asInvoker`；极少数硬件分配 COM 端口号 ≥ 10 时 Win32 `CreateFile` 需要 admin（COM1-COM9 不需要）；可在设备管理器改 COM 号解决
- **VC++ Redistributable x64 依赖** — `flutter build windows --release` 默认 `/MD` (CMP0091 OLD)，项目编译的 `riden_power_supply.exe` + 3 个插件 DLL 依赖 `vcruntime140.dll` + `msvcp140.dll`。Flutter 官方 `flutter_windows.dll` 本身已静态链接 CRT（实测 Release artifacts Import Table 0 命中 VC Runtime）。README 用户使用说明已明确告知干冷系统需装 `vc_redist.x64.exe`（14MB，一次）。`ucrtbase.dll` 由 Universal CRT 自带无需 Redist。

# Phase W1.5 — Windows 跨平台兼容性补充审计 (APPLIED)

## flutter_libserialport Windows Release 依赖

**架构验证**：
- `flutter_libserialport_plugin.cpp` 36 行全文 0 个 `libserialport` API 调用，0 个 `LoadLibrary` / `dlopen`，0 个 `serialport.h` include — 仅 Flutter plugin shell
- Dart 端 `libserialport-0.3.0+1/lib/src/dylib.dart`：`DynamicLibrary.open(resolveDylibPath('serialport', ...))` — 运行时显式加载
- dylib-0.3.3 `resolveDylibPath`：Windows 上返回 `serialport.dll`（无 `lib` 前缀）
- Windows 文件搜索顺序（SafeDllSearchMode 开启）：exe 同目录 → System32 → Windows → 当前目录 → PATH
- 解压 ZIP 双击 .exe → `DynamicLibrary.open('serialport.dll')` 命中 exe 同目录的 `serialport.dll` ✓

**自动分发链路**：
```
flutter_libserialport-0.4.0/windows/CMakeLists.txt:
  set(flutter_libserialport_bundled_libraries "$<TARGET_FILE:serialport>" PARENT_SCOPE)
                                              ↓ 导出 serialport.dll 路径到上层
windows/CMakeLists.txt:84-88:
  if(PLUGIN_BUNDLED_LIBRARIES)
    install(FILES "${PLUGIN_BUNDLED_LIBRARIES}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}")
                                              ↓ 安装到 build/windows/x64/runner/Release/
```

**对照 Linux 实测**：
- `readelf -d libflutter_libserialport_plugin.so` 的 NEEDED 段不含 `libserialport.so`
- 跨平台一致：dart_ffi 直接加载，无隐式链接，无 NEEDED 依赖

**结论**：`serialport.dll` 自动进入 Release，无运行时 DLL 缺失风险，**无需修改**。

## Windows Runtime 依赖 (VC++ Redistributable)

**实测证据**：`objdump -p` 解析 Flutter 3.44.6 Release 版 `flutter_windows.dll` 的 PE Import Table：

```
ADVAPI32.dll  IPHLPAPI.DLL  ole32.dll       OLEAUT32.dll
PSAPI.DLL     SHLWAPI.dll   RPCRT4.dll      WINMM.dll
WS2_32.dll    IMM32.dll     USER32.dll      OPENGL32.dll
bcrypt.dll    ntdll.dll     GDI32.dll       KERNEL32.dll
CRYPT32.dll   OLEACC.dll    PROPSYS.dll     UIAutomationCore.DLL
dxgi.dll      d3d9.dll      api-ms-win-core-path-l1-1-0.dll
api-ms-win-core-synch-l1-2-0.dll
```

`vcruntime140.dll` / `msvcp140.dll` / `ucrtbase.dll` **全部不在 Import Table** — Flutter 官方已对 `flutter_windows.dll` 静态链接 CRT，对 VC++ Redist 无依赖。

**但项目自身代码 + 3 个插件 DLL 仍动态链接 CRT**：

| 编译产物 | CRT 链接策略 |
|---|---|
| `flutter_windows.dll` (Flutter 官方) | 静态 `/MT` (实测) |
| `riden_power_supply.exe` (我们) | 动态 `/MD` (CMP0091 OLD 默认) |
| `flutter_libserialport_windows_plugin.dll` (插件) | 动态 `/MD` |
| `serialport.dll` (libserialport) | 动态 `/MD` |
| `screen_retriever_windows_plugin.dll` | 动态 `/MD` |
| `window_manager_plugin.dll` | 动态 `/MD` |

项目所有 CMakeLists 均未显式设 `MSVC_RUNTIME_LIBRARY`，CMake policy `CMP0091` 默认 OLD → MSVC 默认 `/MD`。无 `vcruntime140.dll` / `msvcp140.dll` 时启动报错。

**结论**：最终 Release 需要 VC++ Redistributable x64 (2015-2022)。README Phase W1 用户使用说明已更新，明确告知下载 `vc_redist.x64.exe`。`ucrtbase.dll` 由 Windows Universal CRT 自带无需 Redist。

**已 APPLIED**：README 第 130-131 行（Phase W1 用户使用说明）VC++ Runtime 描述已修正为实测正确的表述。

## 不在 v1.0 范围的延伸 (后续版本可选)

**静态链接 /MT 选项** — 改 `windows/runner/CMakeLists.txt` + 所有插件 CMakeLists 设 `CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded` 可消除 VC++ Redist 依赖，但需修改第三方插件 CMakeLists（重写 `apply_standard_settings` 或在每个插件 target 上 `set_property`），属于发布工程深层调整，v1.0 不做。当前方案 = 让用户一次性装 14MB 的 `vc_redist.x64.exe` — 已是 Windows 桌面应用主流做法（Visual Studio Code、Python、Node.js 等均同样要求）。

# Phase L1.2 — 版本来源 CI 校验 + metainfo 注入 (APPLIED)

## 背景

Phase L1.1 Linux release workflow 上线后发现：项目有 5 处硬编码版本来源，tag push 时若忘记同步其中任一处，Release 产物版本号会错配。Phase L1.2 只做版本来源一致性校验，不引入复杂自动同步系统。

## 5 处硬编码版本来源

| # | 文件 | CI 校验 | CI 注入 | 同步责任 |
|---|------|---------|---------|---------|
| S1 | `pubspec.yaml` `version:` | ✓ 两 workflow 都校验 (strip `+build`) | — | 开发者 |
| S2 | `packaging/config/env.sh` `APP_VERSION="1.0.0"` | ✓ `release-linux.yml` Step 4 (strip `-prerelease`) | — | 开发者 |
| S3 | `packaging/config/env_windows.sh` `APP_VERSION="1.0.0"` | ✓ `release-windows.yml` Step 4 (strip `-prerelease`) | — | 开发者 |
| S4 | `windows/runner/Runner.rc` `VERSION_AS_STRING "1.0.0"` | ✗ | ✗ | Flutter 工具链已从 pubspec 注入 FileVersion/ProductVersion 数值字段 |
| S5 | `linux/metainfo/io.github.beilusm.ridenps.metainfo.xml` `<release version="1.0.0" date="2026-07-19">` | ✗ | ✓ `release-linux.yml` `sed` 注入 tag 版本 + 当天日期到 runner workspace | CI |

**pubspec.yaml 是版本主来源**。发版流程：改 S1 + S2 + S3 三处 → 打 tag → CI 校验三处一致 + Linux 注入 S5 → 双平台 assets 上传同一 Release。

## 文件修改

### `.github/workflows/release-linux.yml` (+2 steps → 17 steps total)

1. **Step 4: Verify env.sh APP_VERSION matches tag semver** — `grep '^export APP_VERSION='` 抽值，与 `tag_semver`（`%%-*` longest match strip prerelease）严格相等校验。不一致 fail 并提示同步命令。
2. **Step 13 (Fetch AppImage type2-runtime 之后、Build AppImage 之前): Inject tag version + today's date into metainfo.xml** — `sed -i -E 's|<release version="[^"]*" date="[^"]*">|...|'` 注入 `${APP_VERSION}` + `$(date +%Y-%m-%d)` 到 runner workspace 工作副本。注入后 `grep -q "version=\"${APP_VERSION}\""` 校验成功。**不 commit 不改 repo 文件** — 只改 workspace 副本，`make_appimage.sh` Stage 3 `cp` 该副本到 AppDir/usr/share/metainfo/。

### `.github/workflows/release-windows.yml` (+1 step → 12 steps total)

1. **Step 4: Verify env_windows.sh APP_VERSION matches tag semver** — `Get-Content | Where-Object { $_ -match '^export APP_VERSION="([^"]+)"' }` 抽值，与 `tag_semver`（`-split '-'` 取首段）严格相等校验。

## 发版流程（v1.0.1+）

1. 改 `pubspec.yaml` `version:` (S1)
2. 改 `packaging/config/env.sh` `APP_VERSION="..."` (S2)
3. 改 `packaging/config/env_windows.sh` `APP_VERSION="..."` (S3)
4. **不改** `linux/metainfo/...metainfo.xml` `<release>` — CI 自动注入 S5
5. **不改** `windows/runner/Runner.rc` `VERSION_AS_STRING` — 接受 S4 不校验（Flutter 工具链已注入数值字段）
6. 打 tag `v1.0.1` → 两 workflow 同步触发 → CI 校验 S1+S2 (Linux) / S1+S3 (Windows) → Linux 注入 S5 → 双平台 assets 上传同一 Release

## CI 校验语义

- `tag_semver = tag_version` 去掉 `-prerelease` 后缀（`%%-*` longest match，例如 `1.0.0-l12-test` → `1.0.0`）
- `pubspec_semver = pubspec_version` 去掉 `+build` 后缀
- `env APP_VERSION` 无 prerelease 后缀（与 pubspec `+` 前部分同步为纯 semver）
- 三者必须严格字符串相等，否则 CI fail 通知同步

## 不做（明确排除）

- **不创建 `sync_versions.sh` 自动同步脚本** — 五来源手工同步足够，避免脚本运行时机 / 共谋 / 修改 repo 内容等复杂度
- **不自动修改 `Runner.rc`** — 二进制资源文件 sed 改易破坏 MSVC .rc 编译；Flutter 工具链已注入主要版本字段
- **不改 `env.sh` / `env_windows.sh` / `metainfo.xml` 仓库文件本身** — CI 只校验 (S2/S3) 或只改 workspace 副本 (S5)，不 commit 不 push
- **不扩展 dev CI**（`windows-build.yml` / `linux-build.yml`）— 版本校验只在 tag 触发的 release workflow 生效，dev CI 不变
- **不改本地打包脚本**（`packaging/scripts/*.sh` / `make_appimage.sh`）— metainfo 注入由 CI workflow 内联 step 完成，不注入本地构建链路
- **不在 metainfo.xml 上做 CI 一致性校验** — S5 由 CI 注入，不需校验（避免循环：注入的不是仓库值）

## 本地验证（注入 sed pattern）

```
APP_VERSION="1.0.0-l12-test"
sed -i -E 's|<release version="[^"]*" date="[^"]*">|<release version="1.0.0-l12-test" date="2026-07-22">|' metainfo.xml
# 结果: <release version="1.0.0-l12-test" date="2026-07-22">  ✓
```

## 验证计划

- 打 tag `v1.0.0-l12-test`（tag_semver == 1.0.0，与 pubspec/env*.sh 一致，校验 PASS）
- 双 workflow 成功
- 下载 AppImage → `unsquashfs` → 检查 `usr/share/metainfo/*.xml` `<release version="1.0.0-l12-test" date="2026-07-22">`
- 删除测试 Release + tag
- squash commit → finalize

## Known Issues (Phase L1.2)

- **S4 Runner.rc VERSION_AS_STRING 不 CI 校验** — 二进制 `.rc` 资源不易 sed 改；Flutter 工具链已从 pubspec 自动注入 `FileVersion` / `ProductVersion` 数值字段；`VERSION_AS_STRING` 仅是 VS_VERSION_INFO 资源块的一个字符串条目。v1.1+ 评估 sync 方案。当前接受不校验。
- **dev CI (`windows-build.yml` / `linux-build.yml`) APP_VERSION hardcoded '1.0.0'** — Phase L1.2 不动 dev CI，版本校验只在 tag 触发的 release workflow 生效。Phase L1.3 评估 dev CI 是否也需要校验。

## v1.0.1 Release 交付记录 (FROZEN)

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

### Release assets（4 个完整）

| 文件名 | 大小 | 平台 workflow |
|---|---|---|
| `RIDEN_PowerSupply-1.0.1-linux-x86_64.AppImage` | 10,299,896 B (9.82 MB) | release-linux.yml |
| `SHA256SUMS-linux.txt` | 112 B | release-linux.yml |
| `RIDEN_PowerSupply-1.0.1-windows-x64.zip` | 12,743,023 B (12.15 MB) | release-windows.yml |
| `SHA256SUMS-windows.txt` | 1,753 B | release-windows.yml |

### CI 校验产物（Phase L1.2 三新 step 实跑日志确认）

- Linux Step 4 `Verify env.sh APP_VERSION`: `env.sh APP_VERSION: 1.0.1` → `OK: tag semver matches env.sh APP_VERSION (1.0.1)`
- Linux Step 13 `Inject metainfo.xml`: `before: <release version="1.0.0" date="2026-07-19">` → `after: <release version="1.0.1" date="2026-07-22">`
- Windows Step 4 `Verify env_windows.sh APP_VERSION`: `env_windows APP_VERSION: 1.0.1` → `OK: tag semver matches env_windows.sh APP_VERSION (1.0.1)`

### 下游验证（本地下载 AppImage 实测）

- `sha256sum -c SHA256SUMS-linux.txt` → 成功
- AppImage type2 magic offset 8: `41 49 02` (`AI\x02`) ✓
- `file`: ELF 64-bit LSB PIE executable, x86-64 ✓
- `--appimage-extract` → `squashfs-root/usr/share/metainfo/io.github.beilusm.ridenps.metainfo.xml:79`: `<release version="1.0.1" date="2026-07-22">` ✓

### 当前版本传播策略（v1.0.1 已实施）

1. 改 `pubspec.yaml` `version: 1.0.1+1` (S1) — 主来源
2. 改 `packaging/config/env.sh` `APP_VERSION="1.0.1"` (S2)
3. 改 `packaging/config/env_windows.sh` `APP_VERSION="1.0.1"` (S3)
4. 不改 `linux/metainfo/...metainfo.xml` `<release>` (S5) — CI 注入
5. 不改 `windows/runner/Runner.rc` `VERSION_AS_STRING "1.0.0"` (S4) — 接受不校验
6. 打 tag `v1.0.1` → 双 workflow 同步 → CI 校验 S1+S2 (Linux) / S1+S3 (Windows) → Linux 注入 S5 → 4 assets 上传到同一 Release

### 已知未处理项（冻结前最终盘点）

| 项 | 来源 | 状态 | 处理建议 |
|---|---|---|---|
| Runner.rc `VERSION_AS_STRING "1.0.0"` | S4 | OPEN — 接受不校验 | v1.1+ 评估自动 sync 脚本；当前 Flutter 工具链已注入 FileVersion/ProductVersion 数值字段 |
| `windows-build.yml:28` dev CI `APP_VERSION: '1.0.0'` | dev CI | OPEN — 不动 dev CI | Phase L1.3 评估（仅影响 push 触发的 30 天过期 artifact，不进 Release） |
| README 4 处 `1.0.0` 文档示例 | doc | OPEN — 非 release 阻塞 | 后续 doc 版本示例 cleanup |
| `packaging/scripts/build_release.sh` 3 处注释引用 `1.0.0` | 注释 | OPEN — 不动本地脚本 | Phase L1.2 明确排除；将来可改注释为 `${APP_VERSION}` |
| P1-1 `_onPollMiss` 死代码 | `power_supply_provider.dart:184` | OPEN | 业务代码修复（与 release 无关） |
| P1-2 zombie `_worker` 阻塞 reconnect | `serial_modbus_service.dart:30-32` | **RESOLVED (本次会话)** | 已修复：`_handleWorkerError` + identical 清零 + `isDead` getter + connect/disconnect fast-path + Provider `_onData` `CommStatus.error` 传播 |
| Phase B.2 active OVP/OCP 被 FAST poll M0 storage 覆盖 | `serial_modbus_service.dart:90-91` / `power_supply_provider.dart:208` | **RESOLVED (本次会话)** | 已修复：service `_sub.listen` 守卫 + `_parseAllRegs` 不填 ovp/ocp + provider merged 守卫 + SLOW poll SLOT-sync；register_conflicts & register_definition doc 对齐，conflict=false (HR14/HR82/HR83) |
| AppStream `url-not-reachable` warning | metainfo validate | OPEN — `--no-net` 模式 | repo 已上线 + URL 已更新；有 net 环境重跑 `appstreamcli validate` 验证可消除 |

### 发布冻结声明

**v1.0.1 Release 已冻结**：不重新 build、不重新发布、不重新打 tag。Release 内容、assets、tag 不可变。如需修正任何问题，按 SemVer 走 v1.0.2 或 v1.1.0 流程。

仓库最终状态：

```
Commits (top 3):
  075dd5d Bump version to 1.0.1                    ← 当前 HEAD
  e7c4f35 Add version-source CI checks + metainfo injection (Phase L1.2)
  8470118 Add Linux GitHub Release automation

Tags:       v1.0.0, v1.0.1
Releases:   v1.0.1 (Latest, 4 assets) / v1.0.0 (Windows-only, 历史)
工作树:     clean
```

---

## Phase A / A.5 / B — Register Schema 对齐 + HR19 quickSwitch 迁移

### 完成时间线

- **Phase A — Register Schema 与 Worker 解码一致性修复**：完成
  - HR3：`auxVoltage` → `firmwareVersion` (uint16 RO，无 scale)
  - HR7：`internalState` → `systemTempF` (int16 `.toSigned(16)` 处理负温度)
  - HR15：`statusFlags` (`@Deprecated`) → `keyLock` (enum R/W {0,1})
  - HR16：未实现 → `protectionStatus` (enum RO {0=正常,1=OVP,2=OCP,3=OTP})
  - HR17/HR18：保留 bool 表示（与 enum 语义兼容，不改）
  - `auxVoltage` / `statusFlags` 字段保留 `@Deprecated` 不删，保证向后兼容
  - `quickSwitch(slot)` 接口 + SerialImpl + Mock 实现加入
  - 旧 `loadMemorySlot` 实现完整保留

- **Phase A.5 — HR19 硬件数据组切换验证**：✓ PASS（真实设备实测）
  - 验证脚本：`test/phasea5_quickswitch_verify.dart`
  - smoke 测试默认运行（验证流水线本身）；hardware 测试 gate by `PHASEA5_HW=1` 环境变量
  - 硬件实测结果（用户运行确认）：
    - HR19 0x0000 → 0x0001（写入成功，回读一致）
    - HR8 Vset：4.20V → 5.00V（与 M1 preset 一致）
    - HR9 Iset：6.100A → 5.000A（与 M1 preset 一致）
  - 结论：HR19 (0x0013) 是设备硬件 Memory Slot quick switch 入口，写 HR19=Mx 后设备固件自动加载对应 Mx 保存参数到当前工作寄存器。

- **Phase B — UI 迁移到 quickSwitch**：完成
  - `loadSlot()` provider 方法加 `@Deprecated`，UI 不再调用
  - `loadMemorySlot()` service 方法加 `@Deprecated`（abstract + Serial + Mock）
  - `bottom_status.dart` / `setpoint_panel.dart` 全部 UI 调用点改为 `quickSwitch()`
  - `PowerSupplyProvider.quickSwitch(slot)` 实现：
    1. 写 HR19 = slot.clamp(0,9)
    2. 等 600 ms（设备 firmware 加载预设）
    3. `readRawRegisters` 读 HR0..HR120
    4. `_data.copyWith` 同步 setVoltage/setCurrent/keyLock/protectionStatus/isConstantCurrent/outputEnabled + 新字段（modelId/firmwareVersion/systemTempF）
    5. `notifyListeners`
  - `loadSlot()` / `loadMemorySlot()` 实现完整保留，仅 UI 不再调用，便于回退测试

### 关键架构变化

**旧逻辑（已废弃，代码保留）**：
```
loadMemorySlot()
= 读 M0~M9 保存区（HR[80+idx*4]）
+ 软件写 HR8（Vset）/ HR9（Iset）/ HR82（OVP）/ HR83（OCP）
```
4 次单独 Modbus 写入；UI 状态来自软件缓存，不是设备实测值。

**新逻辑（UI 当前使用）**：
```
quickSwitch()
= write HR19=slot
→ 等待 600ms 设备硬件加载 slot preset
→ read HR0~HR120（来自 worker isolate 真实 RTU 读）
→ UI 使用设备真实状态
```
1 次 Modbus 写 + 1 次 Modbus 读；UI 状态来自设备实测，消除软件缓存与设备不一致风险。

### 当前测试状态

- `flutter analyze`：**28 issues**，与 Phase L1.2 baseline 一致，**0 新增**
- `flutter test`：**12/12 PASS**
  - widget_test × 1
  - register_page_load_test × 1（RegisterPage 加载冒烟）
  - phasea_schema_test × 4（新 schema 字段 + quickSwitch + clamp）
  - phasea5_quickswitch_verify × 1（smoke 默认运行，hardware 测试 skip）
  - phaseb_quickswitch_test × 6（provider flow：activeSlot/refresh/clamp/keyLock/loadSlot 兼容/新字段）
- Phase A.5 hardware：**PASS**（HR19 0→1, HR8 4.20→5.00V, HR9 6.100→5.000A）

### 后续可选事项（未启动 Phase C）

- **B.5 旧路径残留 audit**：清理 `loadSlot` / `loadMemorySlot` 的兼容性引用（当前标 `@Deprecated` 但未删；可在确认无任何路径调用后真删除）
- **Phase C UI 展示**：
  - `firmwareVersion` 显示（Dashboard / About 页 / RegisterPage V 列）
  - `keyLock` 状态徽章（Dashboard 顶部）
  - `protectionStatus` OVP/OCP/OTP 徽章（Dashboard 顶部 + 红色告警）
  - RegisterPage 用户编辑写入路径完善（新增字段对应已写支持）
- **quickSwitch 延迟优化**：当前固定 `await 600 ms` 后再 read；可以改为短轮询（200ms × 最多 5 次）检测 HR8 是否变化为 slot preset target，未变化才退化为固定等待。降低 typical case 切换延迟。

### 修改文件清单（本次 Phase A + A.5 + B）

源代码：
- `lib/models/power_supply_data.dart` — 新字段 firmwareVersion/keyLock/protectionStatus，重命名 internalState→systemTempF，auxVoltage/statusFlags 标 @Deprecated
- `lib/models/register_definition.dart` — Phase L1.2 寄存器表（HR0..HR19 全部 datasheet 确认）
- `lib/services/modbus_service.dart` — abstract 接口新增 quickSwitch + loadMemorySlot 标 @Deprecated
- `lib/services/serial_modbus_service.dart` — quickSwitch 实现（writeRegister(19, slot)），loadMemorySlot 标 @Deprecated，_parseAllRegs 全链路新字段解码
- `lib/services/mock_modbus_service.dart` — quickSwitch 实现 + readRawRegisters 提升 fidelity + 各 setter 同步新字段
- `lib/services/modbus_worker.dart` — init read / fastPoll 解码改为新字段，跨 isolate serial/deserialize 同步
- `lib/providers/power_supply_provider.dart` — 新增 quickSwitch(slot) + loadSlot 标 @Deprecated
- `lib/widgets/bottom_status.dart` — UI 调用 loadSlot → quickSwitch（2 处）
- `lib/widgets/setpoint_panel.dart` — UI 调用 loadSlot → quickSwitch（1 处）
- `lib/widgets/register_page.dart` — 地址格式 HRxxx → 0xXXXX

测试：
- `test/register_page_load_test.dart` — RegisterPage 加载冒烟
- `test/phasea_schema_test.dart` — Phase A 字段验证（4 个 test）
- `test/phasea5_quickswitch_verify.dart` — Phase A.5 验证脚本（smoke + hardware gated）
- `test/phaseb_quickswitch_test.dart` — Phase B provider flow 验证（6 个 test）

未修改：
- `lib/models/register_conflicts.dart`（Phase A 显式排除）
- ModbusScheduler / modbus_task.dart / polling 架构
- `FAST 150ms` / `SLOW 1000ms` / `_accumulateRead 250ms` 三个数值
- RegisterPage 布局 / 风格 / 交互逻辑
- Dashboard / 业务功能 UI 大改（Phase C 范围）

