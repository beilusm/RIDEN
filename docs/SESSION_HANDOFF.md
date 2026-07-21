# Project Status

RIDEN 数控电源 Flutter 桌面上位机。已完成串口连接面板 + 寄存器模式页面 + RegisterDefinition Schema。当前阶段：**Production Hardening — Phase 3 P0 修复 + P1-3 修复全部 APPLIED。Verdict: Production Ready (P0 范围)**。

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

6. **Worker crash 后 zombie `_worker` 静默阻塞 `connect()`，需手动 disconnect→connect 恢复** — **OPEN (P1-2)**
   - [Project Source] `serial_modbus_service.dart:30-32` `onError` 回调只 debugPrint。
   - 没有 crash 后的自动清零 `_worker`，`if (_worker != null) return;` (service line 28) 拒绝新 connect。
   - Provider 端 line 71 `if (_connected || _connecting) return;` 同样拒绝。
   - 用户必须手动 DISCONNECT (然后 CONNECT) 或 RECONNECT 才能恢复。`reconnect()` 始终可恢复 (trace 验证)。
   - 不致 hang (UI 显示 timeout；disco+co 即恢复)，但 UX 退化。
   - 未修复。Patch 建议: 在 `onError` 回调中触发 `_worker = null` + `_connected = false` + `notifyListeners()` + 状态升级为 `CommStatus.error`。out of scope 当前会话。

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
- [ ] 11. (可选, P1-2) 修复 zombie `_worker` 阻塞自动 reconnect — out of scope 当前会话。建议方案: 在 service `onError` 回调中置 `_worker = null` 并通知 Provider 置 `_connected = false` + `notifyListeners()` + 升级 `CommStatus.error`。

# Constraints

修改禁令与架构约束统一见 `CLAUDE.md` 的 "不要做的事" 章节。本会话额外约束 (已并入 CLAUDE.md):
- 仅修复真正会导致生产不可恢复的问题
- `modbus_worker.dart` 仅允许稳定性修复 (P0/P1)

# Recommended Starting Point (Next Session)

Phase 1 / Phase 2 / Phase 3 / Phase W1 全部 APPLIED。下个会话可能的工作:

## 优先项：Windows Release 实测 (Phase W2)

Phase W1 完成了 Linux 端可做的所有 Windows 发布准备工作：Runner.rc 4 字段、main.cpp 标题、20KB .ico、env_windows.sh、make_windows_zip.sh、build_windows_release.sh，README/CLAUDE 已更新。**Phase W2 仅能在 Windows 主机执行**，验证步骤见 SESSION_HANDOFF "Phase W2 — Windows 实测清单"。

简版：
1. 在 Windows 10/11 主机：Visual Studio 2022 + Flutter 3.44+ + FVM + Python 3 + Git Bash/WSL
2. `fvm flutter pub get`
3. `bash packaging/scripts/build_windows_release.sh`
4. 验证 `release/RIDEN_PowerSupply-1.0.0-windows-x64.zip` 存在且 `sha256sum -c SHA256SUMS-windows.txt` 通过
5. 解压 ZIP 到干净目录，双击 `riden_power_supply.exe` 验证启动
6. 插入 CH340 → 验证 serial 通信、Worker lifecycle
7. 反馈 W2.1-W2.7 各步骤结果至 SESSION_HANDOFF

## 优先项：发布上线（与 Phase W2 可并行）

1. `git init` + `.gitignore` 已就绪（Phase 3 已补完）。
2. 首次 commit + push 到 GitHub `https://github.com/beilusm/RIDEN`（需要先创建该仓库）。
3. GitHub repo 上线后，重新运行 `appstreamcli validate`（去掉 `--no-net`）— AppStream 的 3 个 `url-not-reachable` warning 应消失。
4. 上传到 GitHub Release v1.0.0：
   - Linux: `RIDEN_PowerSupply-1.0.0-x86_64.AppImage` + `SHA256SUMS` + `RELEASE_NOTES-1.0.0.md`
   - Windows: `RIDEN_PowerSupply-1.0.0-windows-x64.zip` + `SHA256SUMS-windows.txt`
5. 在 `linux/metainfo/io.github.beilusm.ridenps.metainfo.xml` 里视情况追加 GitHub Release 的 URL（消除 AppStream warning 根因）。

## 若处理 P1-1 (`_onPollMiss` 死代码)
1. 定位 `_onPollMiss()` (`power_supply_provider.dart:184-191`)。
2. 找到 FAST/SLOW poll miss 的 hook 点 (是 `_onData` 后还是 `_healthTimer` tick 处)。
3. 接入 `_onPollMiss()` 调用，使 `_consecutiveFails++` 触发 `CommStatus.error` 状态机。
4. `fvm flutter analyze`。

## 若处理 P1-2 (zombie `_worker`)
1. 在 `serial_modbus_service.dart:30-32` 的 `onError` 回调中，不只 debugPrint。
2. 加 `if (identical(_worker, _currentWorkerHandle))` 后置 null (借用 B.1 identical 模式)。
3. 触发 `_dataController.add(PowerSupplyData(commStatus: CommStatus.offline))` 通知 UI。
4. Provider 需要在 dataStream listener 中检测 offline 状态并置 `_connected = false` + `notifyListeners()`。
5. `fvm flutter analyze`。运行时验证 crash → 自动 reconnect 路径。

## 后续版本（延期项，见 Phase 3 "Not Implemented"）

- zsync / `--updateinformation` — AppImage 增量自动更新
- GPG 签名 — `appimagetool -s` + 签名密钥
- GitHub Actions CI — `packaging/scripts/build_release.sh` 迁移到 workflow
- 多 distro 自动测试 — Ubuntu 22.04 / 24.04 / Fedora / Debian 测试矩阵

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

### OPEN — P1-2: Zombie `_worker` 阻塞自动 reconnect (`serial_modbus_service.dart:30-32`)
- 影响: worker crash 后 `onError` 回调只 debugPrint，不置 `_worker = null`，不通知 Provider；connect() 在 service (line 28) 和 provider (line 71) 两级守卫均静默拒绝。用户必须手动 DISCONNECT + CONNECT 或 RECONNECT 才能恢复。
- 修复建议: 在 `onError` 回调中清零 `_worker` + 通过 `dataController` 通知 Provider，Provider 置 `_connected = false` + `notifyListeners()` + 升级 `CommStatus.error`，UI 可以提示用户或自动触发 reconnect。

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

