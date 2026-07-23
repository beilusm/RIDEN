import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/power_supply_data.dart';
import 'modbus_service.dart';
import 'modbus_worker.dart';

/// [ModbusService] implementation that proxies all Modbus I/O to a
/// worker isolate.  The UI isolate never touches SerialPort directly —
/// all synchronous FFI calls run inside [ModbusWorkerHandle].
class SerialModbusService implements ModbusService {
  ModbusWorkerHandle? _worker;
  StreamSubscription<PowerSupplyData>? _sub;
  PowerSupplyData _current = PowerSupplyData(timestamp: DateTime.now());

  // ── Production stats ───────────────────────────────────────────
  int _statOkFast = 0;
  Timer? _statTimer;
  int _perfNotifyCount = 0;

  @override bool get isConnected => _worker != null;
  @override Stream<PowerSupplyData> get dataStream => _dataController.stream;
  final _dataController = StreamController<PowerSupplyData>.broadcast();

  // ── Lifecycle ──────────────────────────────────────────────────

  @override
  Future<void> connect({String? port, int baudRate = 115200, int address = 1}) async {
    // P1-2: zombie worker check.  If the previous handle is still
    // referenced but the underlying isolate has already died (e.g. a
    // crash fired the onError path below but the eventual _worker =
    // null assignment was deferred for any reason — or, more
    // commonly, a prior connect() failed at the port-open step and
    // left a spawned-but-never-connected handle), tear it down here
    // before spawning a fresh one.  Without this check, connect()
    // would early-return on the line below and leak a dead worker
    // forever — preventing any re-connect attempt from succeeding.
    if (_worker != null && _worker!.isDead) {
      _sub?.cancel();
      _sub = null;
      _statTimer?.cancel();
      _statTimer = null;
      _worker = null;
    }
    // P1-2: duplicate-worker guard.  An alive handle means another
    // caller already successfully connected; refuse to spawn a
    // second live isolate alongside it (which would leave two
    // handles competing for the same serial fd).
    if (_worker != null) return;
    try {
      _worker = await ModbusWorkerHandle.spawn();
      // P1-2: route worker crashes through _handleWorkerError so the
      // dead handle is nullified, _sub is cancelled, and the UI is
      // notified via a CommStatus.error snapshot on _dataController.
      // Before this fix, the callback only debugPrinted — leaving
      // _worker pointing at the dead handle, so isConnected stayed
      // true and connect() kept early-returning until the user
      // explicitly disconnected.
      _worker!.onError = _handleWorkerError;

      // Merge incoming snapshot into _current cache, then emit.
      // FAST poll has setVoltage > 0 → trust all measurement fields.
      // SLOW poll has setVoltage == 0 → merge only slots.
      // INIT read (HR[0..7]) has setVoltage == 0 too; it carries the
      // init-only fields modelId / firmwareVersion / systemTempF that
      // the FAST/SLOW loops never read.  Accept those when the snapshot
      // is not from the FAST loop (so the fast poll defaults of 0 / 60067
      // won't overwrite the values stamped by the init read).
      _sub = _worker!.dataStream.listen((snapshot) {
        final isFast = snapshot.setVoltage > 0;
        _current = _current.copyWith(
          timestamp: snapshot.timestamp,
          // Init-read only fields: merge when the snapshot is not from
          // the FAST path (init read has setVoltage == 0).
          modelId: !isFast ? snapshot.modelId : _current.modelId,
          firmwareVersion: !isFast ? snapshot.firmwareVersion : _current.firmwareVersion,
          systemTempF: !isFast ? snapshot.systemTempF : _current.systemTempF,
          // Fast-poll fields.
          temperature: isFast ? snapshot.temperature : _current.temperature,
          setVoltage: isFast ? snapshot.setVoltage : _current.setVoltage,
          setCurrent: isFast ? snapshot.setCurrent : _current.setCurrent,
          outputVoltage: isFast ? snapshot.outputVoltage : _current.outputVoltage,
          outputCurrent: isFast ? snapshot.outputCurrent : _current.outputCurrent,
          inputVoltage: isFast ? snapshot.inputVoltage : _current.inputVoltage,
          keyLock: isFast ? snapshot.keyLock : _current.keyLock,
          protectionStatus: isFast ? snapshot.protectionStatus : _current.protectionStatus,
          isConstantCurrent: isFast ? snapshot.isConstantCurrent : _current.isConstantCurrent,
          outputEnabled: isFast ? snapshot.outputEnabled : _current.outputEnabled,
          capacityMah: isFast ? snapshot.capacityMah : _current.capacityMah,
          energyMwh: isFast ? snapshot.energyMwh : _current.energyMwh,
          ovp: isFast ? snapshot.ovp : _current.ovp,
          ocp: isFast ? snapshot.ocp : _current.ocp,
          memorySlots: snapshot.memorySlots.isNotEmpty
              ? _mergeSlots(_current.memorySlots, snapshot.memorySlots)
              : _current.memorySlots,
        );
        _dataController.add(_current);
        _statOkFast++;
      });

      await _worker!.connect(port: port, baudRate: baudRate, address: address);
      _startStatTimer();
    } catch (e) {
      // P1-2: connect failed (port open error, handshake timeout,
      // etc.).  Tear down the spawned-but-unusable handle so the
      // next connect() call can spawn a fresh one instead of
      // early-returning on the stale `_worker != null` check.
      try {
        _sub?.cancel();
        _sub = null;
        _statTimer?.cancel();
        _statTimer = null;
        final w = _worker;
        if (w != null) {
          w.forceKill();
          if (identical(_worker, w)) {
            _worker = null;
          }
        }
      } catch (cleanupErr) {
        debugPrint('[SERIAL] connect-fail cleanup error: $cleanupErr');
      }
      rethrow;
    }
  }

  /// P1-2: invoked synchronously from [ModbusWorkerHandle.onError]
  /// when the worker isolate crashes (uncaught exception in worker
  /// entry, port FFI blowup, or interrupt during an await).
  ///
  /// Lifecycle action checklist (executed in order):
  ///   1. Capture and nullify `_worker` so isConnected flips to
  ///      false immediately (the existing `bool get isConnected =>
  ///      _worker != null;` getter then does the right thing).
  ///   2. Cancel `_sub` (was listening to the dead handle's closed
  ///      data stream — the cancel is a no-op on a closed stream but
  ///      frees the listener slot for the next connect()).
  ///   3. Cancel `_statTimer` — the 2s health log keeps writing
  ///      `isolate=dead` lines otherwise, which is misleading once
  ///      we've already torn down.
  ///   4. Emit a single [CommStatus.error] snapshot on
  ///      `_dataController`.  Provider's [_onData] detects the
  ///      authoritative commStatus and flips `_connected = false` +
  ///      upgrades to [CommStatus.error] + notifies listeners.
  ///
  /// Idiom note: we capture `w = _worker` before nulling it so the
  /// `identical(_worker, w)` check below — borrowed from the
  /// B.1 disconnect() pattern — would short-circuit if the field
  /// had already been reassigned by a concurrent cleanup path.
  void _handleWorkerError(String err) {
    debugPrint('[WORKER] error: $err');
    final w = _worker;
    if (w == null) return; // already cleaned up by another path
    if (!identical(_worker, w)) return; // re-raced, leave alone
    _worker = null;
    _sub?.cancel();
    _sub = null;
    _statTimer?.cancel();
    _statTimer = null;
    _current = _current.copyWith(
      timestamp: DateTime.now(),
      commStatus: CommStatus.error,
    );
    _dataController.add(_current);
  }

  @override
  Future<List<String>> listPorts() async {
    // P1-2: treat a zombie (_worker != null but isDead) the same as
    // _worker == null — fall through to the transient spawn path so
    // the dead handle's `listPorts()` call (which would hang forever
    // waiting for a reply that will never arrive) is bypassed.
    final aliveWorker = (_worker != null && !_worker!.isDead) ? _worker : null;
    if (aliveWorker == null) {
      // Worker not spawned yet (or zombie) — spawn a transient
      // handle just to enumerate.
      try {
        final w = await ModbusWorkerHandle.spawn();
        final ports = await w.listPorts();
        await w.shutdown();
        return ports;
      } catch (e) {
        debugPrint('[SERIAL] listPorts failed: $e');
        return <String>[];
      }
    }
    return aliveWorker.listPorts();
  }

  List<MemorySlot> _mergeSlots(
      List<MemorySlot> existing, List<MemorySlot> incoming) {
    final result = List<MemorySlot>.from(existing);
    for (final s in incoming) {
      final i = result.indexWhere((m) => m.index == s.index);
      if (i >= 0) result[i] = s; else result.add(s);
    }
    result.sort((a, b) => a.index.compareTo(b.index));
    return result;
  }

  void _startStatTimer() {
    _statTimer?.cancel();
    _statTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final alive = _worker != null;
      debugPrint('[SCHED_STAT] complete=${_statOkFast} '
          'data_rate=${(_statOkFast / 2.0).toStringAsFixed(1)}/s '
          'isolate=${alive ? "alive" : "dead"}');
      _statOkFast = 0;
    });
  }

  @override
  Future<void> disconnect() async {
    _statTimer?.cancel();
    _statTimer = null;
    _sub?.cancel();
    _sub = null;
    final w = _worker;
    if (w != null) {
      // P1-2: if the worker isolate has already crashed, skip the
      // `await w.disconnect().timeout(5s)` and `await w.shutdown()
      // .timeout(5s)` round-trips — both wait for a reply message
      // that will never arrive (the worker is dead, _pending is
      // already swept by `_onIsolateExit`).  Skipping them shaves
      // up to 10s off disconnect() when the device was unplugged
      // abruptly or the worker otherwise crashed mid-poll.
      final dead = w.isDead;
      if (!dead) {
        try {
          await w.disconnect().timeout(const Duration(seconds: 5));
        } catch (e) {
          debugPrint('[SERIAL] disconnect timeout/err: $e');
        }
        try {
          await w.shutdown().timeout(const Duration(seconds: 5));
        } catch (e) {
          debugPrint('[SERIAL] shutdown timeout/err: $e');
        }
      }
      // 兜底强制 kill isolate.
      // 已知限制 (DISPROVED via Library Source): libserialport 不注册
      // NativeFinalizer, 因此 SerialPort fd 不会被 Isolate.kill 释放。
      // fd 泄漏到进程退出, 但 isolate 死亡后无代码运行该 fd, 新 worker
      // 不受其影响 (待运行时验证 ttyUSB 重 open 是否一定成功)。
      w.forceKill();
      if (identical(_worker, w)) {
        _worker = null;
      }
    }
    _current = PowerSupplyData(timestamp: DateTime.now(), commStatus: CommStatus.offline);
    _dataController.add(_current);
  }

  // ── Pause / Resume ─────────────────────────────────────────────

  @override
  void pauseTieredPolling() {
    _worker?.pausePoll();
  }

  @override
  void resumeTieredPolling() {
    _worker?.resumePoll();
  }

  // ── Write ──────────────────────────────────────────────────────

  @override
  Future<void> writeRegister(int address, int value) {
    final w = _worker;
    if (w == null) return Future.error('Not connected');
    return w.writeRegister(address, value);
  }

  // ── Reads ──────────────────────────────────────────────────────

  @override
  Future<PowerSupplyData?> readAllRegisters() async {
    final regs = await _worker?.readRegisters(0, 121, prio: 5, group: 'user');
    if (regs == null) return null;
    return _parseAllRegs(regs);
  }

  @override
  Future<List<int>?> readRawRegisters({String? dedup, int? expireMs}) {
    return _worker?.readRegisters(0, 121,
            prio: 5, group: 'user', dedup: dedup, expire: expireMs) ??
        Future.value(null);
  }

  @override
  Future<List<int>?> readMemorySlot(int index) {
    return _worker?.readRegisters(80 + index * 4, 4,
            prio: 5, group: 'user') ??
        Future.value(null);
  }

  /// Phase B.1 — bulk-read all 10 memory slots in one Modbus RTU
  /// round-trip (HR[80..119], 40 consecutive registers).  Replaces
  /// the provider's prior 10× `readMemorySlot(i)` cycle in
  /// [readAllRegisters] / [readRawRegisters]-driven slot refresh —
  /// 10 RTU requests reduced to 1.
  @override
  Future<List<MemorySlot>> readAllMemorySlots() async {
    final regs = await _worker?.readRegisters(80, 40,
            prio: 5, group: 'user') ??
        <int>[];
    final slots = <MemorySlot>[];
    for (int s = 0; s < 10; s++) {
      final base = s * 4;
      if (base + 3 < regs.length) {
        slots.add(MemorySlot(
          index: s,
          vSet: regs[base] / 100.0,
          iSet: regs[base + 1] / 1000.0,
          ovp: regs[base + 2] / 100.0,
          ocp: regs[base + 3] / 1000.0,
        ));
      }
    }
    return slots;
  }

  // ── Convenience ────────────────────────────────────────────────

  @override
  Future<void> setVoltage(double v) =>
      writeRegister(8, (v * 100).round());
  @override
  Future<void> setCurrent(double a) =>
      writeRegister(9, (a * 1000).round());
  @override
  Future<void> setOutput(bool e) => writeRegister(18, e ? 1 : 0);

  /// Phase A: hardware quick-switch to slot M0..M9 via HR[19].
  /// No interaction with the legacy [loadMemorySlot] path — kept
  /// separate so both can be A/B-validated against the device.
  @override
  Future<void> quickSwitch(int slotIndex) =>
      writeRegister(19, slotIndex.clamp(0, 9));

  @override
  Future<void> setOVP(double v) =>
      writeRegister(82, (v * 100).round());
  @override
  Future<void> setOCP(double a) =>
      writeRegister(83, (a * 1000).round());

  @override
  @Deprecated('Use quickSwitch(slotIndex) instead — Phase B verified '
      'HR[19] as the device-side quick-switch entry point')
  Future<void> loadMemorySlot(int index) async {
    final vals = await readMemorySlot(index);
    if (vals == null || vals.length < 4) return;
    await setVoltage(vals[0] / 100.0);
    await setCurrent(vals[1] / 1000.0);
    await setOVP(vals[2] / 100.0);
    await setOCP(vals[3] / 1000.0);
  }

  @override
  Future<void> saveMemorySlot(
      int index, double vSet, double iSet, double ovp, double ocp) async {
    final base = 80 + index * 4;
    await writeRegister(base, (vSet * 100).round());
    await writeRegister(base + 1, (iSet * 1000).round());
    await writeRegister(base + 2, (ovp * 100).round());
    await writeRegister(base + 3, (ocp * 1000).round());
  }

  @override
  void incNotify() => _perfNotifyCount++;

  // ── Helpers ────────────────────────────────────────────────────

  PowerSupplyData _parseAllRegs(List<int> regs) {
    int r(int i) => i < regs.length ? regs[i] : 0;
    final slots = <MemorySlot>[];
    for (int s = 0; s < 10; s++) {
      final base = 80 + s * 4;
      if (base + 3 < regs.length) {
        slots.add(MemorySlot(
            index: s,
            vSet: regs[base] / 100.0,
            iSet: regs[base + 1] / 1000.0,
            ovp: regs[base + 2] / 100.0,
            ocp: regs[base + 3] / 1000.0));
      }
    }
    return PowerSupplyData(
        timestamp: DateTime.now(),
        modelId: r(0),
        inputVoltage: r(14) / 100.0,
        // HR[3] = firmware version (uint16 RO, no scaling).
        firmwareVersion: r(3),
        temperature: r(5).toDouble(),
        // HR[7] = system temperature °F (int16 signed).  Reinterpret
        // the unsigned 16-bit wire value as two's complement so
        // negative temperatures are handled correctly.
        systemTempF: r(7).toSigned(16).toDouble(),
        setVoltage: r(8) / 100.0,
        setCurrent: r(9) / 1000.0,
        outputVoltage: r(10) / 100.0,
        outputCurrent: r(11) / 1000.0,
        inputVoltageAlt: r(14) / 10.0,
        // HR[15] = Key Lock enum {0=未锁定, 1=键盘锁定}.
        keyLock: r(15),
        // HR[16] = Protection Status enum {0=正常, 1=OVP, 2=OCP, 3=OTP}.
        protectionStatus: r(16),
        isConstantCurrent: r(17) == 1,
        outputEnabled: r(18) == 1,
        capacityMah: r(39),
        energyMwh: r(41),
        ovp: r(82) / 100.0,
        ocp: r(83) / 1000.0,
        memorySlots: slots,
        screenBrightness: r(72));
  }
}
