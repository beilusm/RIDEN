import 'dart:async';
import 'dart:typed_data';

import '../models/power_supply_data.dart';
import 'modbus_scheduler.dart';
import 'modbus_service.dart';
import 'modbus_task.dart';
import 'serial_backend.dart';
import 'serial_port_enumerator.dart';
import 'serial_port_scanner.dart';

/// Phase 4 Android fix — [ModbusService] implementation that runs
/// entirely in the UI isolate (no worker isolate spawn).
///
/// Background: Flutter 3.44's `BackgroundIsolateBinaryMessenger`
/// fails to route platform-channel replies back to a worker isolate
/// for `usb_serial`'s MethodChannel + EventChannel. The native check
/// `platform_message_response_dart_port.cc(53) Check failed:
/// did_send` fires and the process exits. usb_serial's `inputStream`
/// (EventChannel.receiveBroadcastStream) additionally requires
/// `setMessageHandler` which the worker-isolate messenger refuses.
///
/// This service sidesteps the worker isolate entirely: usb_serial's
/// platform-channel API is *async* (not synchronous FFI), so awaiting
/// it on the UI isolate does NOT block the UI — there is nothing to
/// `poll` synchronously, every TX/RX is a Future. The CLAUDE.md
/// invariant "UI isolate 永远不直接访问 SerialPort" targets synchronous
/// FFI (libserialport), not async platform channels.
///
/// All scheduling (priority / dedup / aging / group pause) is reused
/// via [ModbusScheduler], and the frame builder / CRC / _accumulateRead
/// math is copied 1:1 from `modbus_worker.dart::_ModbusWorkerCore` so
/// the wire protocol stays identical.
class DirectAndroidModbusService implements ModbusService {
  SerialBackend? _backend;
  final ModbusScheduler _scheduler = ModbusScheduler();

  StreamController<PowerSupplyData>? _dataController;
  PowerSupplyData _current = PowerSupplyData(timestamp: DateTime.now());

  Timer? _fastTimer;
  Timer? _slowTimer;
  int _slowSlotIdx = 0;

  int _addr = 0x01;
  int _baudRate = 115200;
  String? _currentPort;

  static const int _kFastIntervalMs = 150;
  static const int _kFastReadStart = 5;
  static const int _kFastReadCount = 79;

  DirectAndroidModbusService();

  @override
  bool get isConnected => _backend != null && _backend!.isOpen;

  @override
  Stream<PowerSupplyData> get dataStream {
    _dataController ??= StreamController<PowerSupplyData>.broadcast();
    return _dataController!.stream;
  }

  @override
  String? get currentPort => _currentPort;

  // ── Lifecycle ──────────────────────────────────────────────────

  @override
  Future<void> connect({
    String? port,
    int baudRate = 115200,
    int address = 1,
  }) async {
    if (isConnected) return;
    try {
      _addr = (address <= 0 || address > 247) ? 0x01 : address;
      _baudRate = (baudRate <= 0) ? 115200 : baudRate;

      // Resolve port via Phase D scanner (UI isolate; usb_serial async
      // — no worker spawned).
      String? effectivePort = port;
      if (effectivePort == null) {
        final result = await const SerialPortScanner(
                enumerateUsbPortsViaIsolate)
            .scanCh340();
        if (!result.found) {
          throw SerialPortScanException(result.reason, scanned: result.scanned);
        }
        effectivePort = result.portName;
      }
      _currentPort = effectivePort;

      _backend = createBackend();
      await _backend!.open(portName: effectivePort, baudRate: _baudRate);

      _resumeTieredPolling();

      // Init read (HR[0..7]) — model ID, firmware version, sys temp.
      _enqueueReadBackground(0, 8, (regs) {
        if (regs != null && regs.length >= 8) {
          final d = PowerSupplyData(
            timestamp: DateTime.now(),
            modelId: regs[0],
            firmwareVersion: regs[3],
            temperature: regs[5].toDouble(),
            systemTempF: regs[7].toSigned(16).toDouble(),
          );
          _emit(d);
        }
      });
    } catch (e) {
      try {
        await _backend?.close();
        _backend?.dispose();
        _backend = null;
        _currentPort = null;
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _pauseTieredPolling();
    await _scheduler.shutdown();
    await _backend?.close();
    _backend?.dispose();
    _backend = null;
    _currentPort = null;
    _current =
        PowerSupplyData(timestamp: DateTime.now(), commStatus: CommStatus.offline);
    _dataController?.add(_current);
  }

  @override
  Future<List<String>> listPorts() async {
    if (_backend != null) return _backend!.enumeratePortNames();
    // transient backend for enumeration
    final tmp = createBackend();
    try {
      return await tmp.enumeratePortNames();
    } finally {
      tmp.dispose();
    }
  }

  @override
  Future<SerialPortScanResult> scanCh340() =>
      const SerialPortScanner(enumerateUsbPortsViaIsolate).scanCh340();

  // ── Poll control ───────────────────────────────────────────────

  void _pauseTieredPolling() {
    _fastTimer?.cancel();
    _fastTimer = null;
    _slowTimer?.cancel();
    _slowTimer = null;
    _scheduler.pauseGroup('poll');
  }

  void _resumeTieredPolling() {
    _scheduler.resumeGroup('poll');
    if (_fastTimer != null) return;
    _fastTimer = Timer.periodic(
        const Duration(milliseconds: _kFastIntervalMs), (_) => _fastPoll());
    _slowTimer =
        Timer.periodic(const Duration(milliseconds: 1000), (_) => _slowPoll());
    _fastPoll();
    _slowPoll();
  }

  @override
  void pauseTieredPolling() => _pauseTieredPolling();

  @override
  void resumeTieredPolling() => _resumeTieredPolling();

  // ── FAST poll (HR[5..83]) ─────────────────────────────────────

  void _fastPoll() {
    if (_backend == null || !_backend!.isOpen) return;
    _enqueueReadDirect(_kFastReadStart, _kFastReadCount,
        TaskPriority.fastPoll, 'fast',
        group: 'poll',
        dedupKey: 'fast',
        expireAfterMs: 300, onResult: (regs) {
      if (regs == null || regs.length < _kFastReadCount) return;
      int r(int i) => i < regs.length ? regs[i] : 0;
      bool inRange(int i) => i < regs.length;
      final d = PowerSupplyData(
        timestamp: DateTime.now(),
        temperature: r(0).toDouble(),
        setVoltage: inRange(3) ? r(3) / 100.0 : 0,
        setCurrent: inRange(4) ? r(4) / 1000.0 : 0,
        outputVoltage: inRange(5) ? r(5) / 100.0 : 0,
        outputCurrent: inRange(6) ? r(6) / 1000.0 : 0,
        inputVoltage: inRange(9) ? r(9) / 100.0 : 0,
        keyLock: inRange(10) ? r(10) : 0,
        protectionStatus: inRange(11) ? r(11) : 0,
        isConstantCurrent: inRange(12) ? r(12) == 1 : false,
        outputEnabled: inRange(13) ? r(13) == 1 : false,
        capacityMah: inRange(34) ? r(34) : 0,
        energyMwh: inRange(36) ? r(36) : 0,
        ovp: inRange(77) ? r(77) / 100.0 : 0,
        ocp: inRange(78) ? r(78) / 1000.0 : 0,
      );
      _emit(d);
    });
  }

  // ── SLOW poll (memory slots) ─────────────────────────────────

  void _slowPoll() {
    if (_backend == null || !_backend!.isOpen) return;
    for (int s = _slowSlotIdx; s < _slowSlotIdx + 2 && s < 10; s++) {
      final idx = s;
      _enqueueReadDirect(80 + idx * 4, 4, TaskPriority.slowPoll, 'slot_M$idx',
          group: 'poll',
          dedupKey: 'slot_M$idx',
          expireAfterMs: null, onResult: (regs) {
        if (regs == null || regs.length < 4) return;
        final d = PowerSupplyData(
          timestamp: DateTime.now(),
          memorySlots: [
            MemorySlot(
              index: idx,
              vSet: regs[0] / 100.0,
              iSet: regs[1] / 1000.0,
              ovp: regs[2] / 100.0,
              ocp: regs[3] / 1000.0,
            )
          ],
        );
        _emit(d);
      });
    }
    _slowSlotIdx = (_slowSlotIdx + 2) % 10;
  }

  // ── Read / Write scheduling ──────────────────────────────────

  Future<List<int>?> readRegisters(
    int start,
    int count, {
    int prio = 5,
    String group = 'user',
    String? dedup,
    int? expire,
  }) {
    final pri = TaskPriority.values.firstWhere(
      (p) => p.base == prio,
      orElse: () => TaskPriority.userRead,
    );
    final completer = Completer<List<int>?>();
    _enqueueReadDirect(start, count, pri, 'user_read',
        group: group,
        dedupKey: dedup,
        expireAfterMs: expire, onResult: (regs) {
      completer.complete(regs);
    });
    return completer.future;
  }

  @override
  Future<void> writeRegister(int addr, int value) {
    return _scheduler
        .enqueue(ModbusTask<void>(
      id: 'wr_${addr}_${DateTime.now().millisecondsSinceEpoch}',
      priority: TaskPriority.write,
      group: 'user',
      execute: () async {
        final frame = _buildWriteFrame(addr, value);
        for (int attempt = 1; attempt <= 2; attempt++) {
          await _requireBackend.write(frame);
          final resp = await _accumulateRead(8, 250);
          if (resp.length >= 8 && resp[1] == 0x06) {
            return;
          }
          if (attempt < 2) {
            await Future.delayed(const Duration(milliseconds: 30));
          }
        }
        throw Exception('Write HR[$addr] failed');
      },
    ));
  }

  void _enqueueReadBackground(
      int start, int count, void Function(List<int>?) onResult) {
    _enqueueReadDirect(start, count, TaskPriority.background, 'bg',
        group: 'bg', onResult: onResult);
  }

  void _enqueueReadDirect(
    int start,
    int count,
    TaskPriority pri,
    String label, {
    required void Function(List<int>?) onResult,
    String group = 'default',
    String? dedupKey,
    int? expireAfterMs,
  }) {
    final expectedLen = 5 + count * 2;
    _scheduler
        .enqueue(ModbusTask<List<int>?>(
      id: 'rd_${start}_$count',
      priority: pri,
      group: group,
      dedupKey: dedupKey,
      expireAfter: expireAfterMs != null
          ? Duration(milliseconds: expireAfterMs)
          : null,
      execute: () async {
        final frame = _buildReadFrame(start, count);
        await _requireBackend.write(frame);
        final resp = await _accumulateRead(expectedLen, 250);

        // Drain on timeout
        if (resp.length < expectedLen) {
          await _drainPort(80);
          return null;
        }

        if (resp.length < 5 || resp[0] != _addr || resp[1] != 0x03) {
          return null;
        }
        final byteCount = resp[2];
        if (resp.length < 3 + byteCount + 2) return null;
        final crcCalc =
            _crc16(Uint8List.sublistView(resp, 0, resp.length - 2));
        final crcRecv =
            (resp[resp.length - 1] << 8) | resp[resp.length - 2];
        if (crcCalc != crcRecv) return null;
        final regs = <int>[];
        for (int i = 0; i < byteCount ~/ 2; i++) {
          regs.add((resp[3 + i * 2] << 8) | resp[4 + i * 2]);
        }
        return regs;
      },
    ))
        .then(onResult)
        .catchError((_) => onResult(null));
  }

  // ── I/O helpers ─────────────────────────────────────────────

  SerialBackend get _requireBackend {
    final b = _backend;
    if (b == null || !b.isOpen) {
      throw StateError('Serial backend not available');
    }
    return b;
  }

  Future<Uint8List> _accumulateRead(
      int expectedLen, int overallDeadlineMs) async {
    final sw = Stopwatch()..start();
    Uint8List buf = Uint8List(0);
    int attempt = 0;
    while (sw.elapsedMilliseconds < overallDeadlineMs) {
      final need = expectedLen - buf.length;
      if (need <= 0) break;
      attempt++;
      final remaining = overallDeadlineMs - sw.elapsedMilliseconds;
      final timeout = attempt == 1 ? 80 : (remaining < 30 ? remaining : 30);
      final chunk = await _requireBackend
          .readChunk(need, Duration(milliseconds: timeout));
      if (chunk.isNotEmpty) {
        final merged = Uint8List(buf.length + chunk.length);
        merged.setAll(0, buf);
        merged.setAll(buf.length, chunk);
        buf = merged;
      }
    }
    return buf;
  }

  Future<int> _drainPort(int deadlineMs) async {
    final sw = Stopwatch()..start();
    int total = 0;
    while (sw.elapsedMilliseconds < deadlineMs) {
      final backend = _backend;
      if (backend == null || !backend.isOpen) break;
      final chunk =
          await backend.readChunk(256, const Duration(milliseconds: 20));
      if (chunk.isEmpty) break;
      total += chunk.length;
    }
    return total;
  }

  // ── Frame builders ─────────────────────────────────────────

  Uint8List _buildReadFrame(int startReg, int count) {
    return _wrapFrame(0x03, [
      (startReg >> 8) & 0xFF,
      startReg & 0xFF,
      (count >> 8) & 0xFF,
      count & 0xFF
    ]);
  }

  Uint8List _buildWriteFrame(int regAddr, int value) {
    return _wrapFrame(0x06, [
      (regAddr >> 8) & 0xFF,
      regAddr & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF
    ]);
  }

  Uint8List _wrapFrame(int func, List<int> payload) {
    final buf = BytesBuilder();
    buf.addByte(_addr);
    buf.addByte(func);
    for (final b in payload) {
      buf.addByte(b);
    }
    final frame = buf.toBytes();
    final crc = _crc16(frame);
    return Uint8List.fromList([...frame, crc & 0xFF, (crc >> 8) & 0xFF]);
  }

  static int _crc16(Uint8List data) {
    int crc = 0xFFFF;
    for (int i = 0; i < data.length; i++) {
      crc ^= data[i];
      for (int j = 0; j < 8; j++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return crc;
  }

  // ── Data emit + merge ───────────────────────────────────────

  void _emit(PowerSupplyData snapshot) {
    final isFast = snapshot.setVoltage > 0;
    final next = _current.copyWith(
      timestamp: snapshot.timestamp,
      modelId: !isFast ? snapshot.modelId : _current.modelId,
      firmwareVersion:
          !isFast ? snapshot.firmwareVersion : _current.firmwareVersion,
      systemTempF: !isFast ? snapshot.systemTempF : _current.systemTempF,
      temperature: isFast ? snapshot.temperature : _current.temperature,
      setVoltage: isFast ? snapshot.setVoltage : _current.setVoltage,
      setCurrent: isFast ? snapshot.setCurrent : _current.setCurrent,
      outputVoltage: isFast ? snapshot.outputVoltage : _current.outputVoltage,
      outputCurrent: isFast ? snapshot.outputCurrent : _current.outputCurrent,
      inputVoltage: isFast ? snapshot.inputVoltage : _current.inputVoltage,
      keyLock: isFast ? snapshot.keyLock : _current.keyLock,
      protectionStatus:
          isFast ? snapshot.protectionStatus : _current.protectionStatus,
      isConstantCurrent: isFast
          ? snapshot.isConstantCurrent
          : _current.isConstantCurrent,
      outputEnabled: isFast ? snapshot.outputEnabled : _current.outputEnabled,
      capacityMah: isFast ? snapshot.capacityMah : _current.capacityMah,
      energyMwh: isFast ? snapshot.energyMwh : _current.energyMwh,
      // Phase B.2 — retain _current.ovp/ocp; provider owns active-slot sync.
      ovp: _current.ovp,
      ocp: _current.ocp,
      memorySlots: snapshot.memorySlots.isNotEmpty
          ? _mergeSlots(_current.memorySlots, snapshot.memorySlots)
          : _current.memorySlots,
    );
    _current = next;
    _dataController ??= StreamController<PowerSupplyData>.broadcast();
    _dataController!.add(next);
  }

  List<MemorySlot> _mergeSlots(
      List<MemorySlot> existing, List<MemorySlot> incoming) {
    final result = List<MemorySlot>.from(existing);
    for (final s in incoming) {
      final i = result.indexWhere((m) => m.index == s.index);
      if (i >= 0) {
        result[i] = s;
      } else {
        result.add(s);
      }
    }
    result.sort((a, b) => a.index.compareTo(b.index));
    return result;
  }

  // ── Register convenience methods (mirror SerialModbusService) ───

  @override
  Future<PowerSupplyData?> readAllRegisters() async {
    final regs = await readRegisters(0, 121, prio: 5, group: 'user');
    if (regs == null) return null;
    return _parseAllRegs(regs);
  }

  @override
  Future<List<int>?> readRawRegisters({String? dedup, int? expireMs}) {
    return readRegisters(0, 121,
        prio: 5, group: 'user', dedup: dedup, expire: expireMs);
  }

  @override
  Future<List<int>?> readMemorySlot(int index) {
    return readRegisters(80 + index * 4, 4, prio: 5, group: 'user');
  }

  @override
  Future<List<MemorySlot>> readAllMemorySlots() async {
    final regs = await readRegisters(80, 40, prio: 5, group: 'user') ??
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

  @override
  Future<void> setVoltage(double v) =>
      writeRegister(8, (v * 100).round());
  @override
  Future<void> setCurrent(double a) =>
      writeRegister(9, (a * 1000).round());
  @override
  Future<void> setOutput(bool e) => writeRegister(18, e ? 1 : 0);

  @override
  Future<void> quickSwitch(int slotIndex) =>
      writeRegister(19, slotIndex.clamp(0, 9));

  @override
  Future<void> setOVP(double v) => writeRegister(82, (v * 100).round());
  @override
  Future<void> setOCP(double a) => writeRegister(83, (a * 1000).round());

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
  void incNotify() {}

  // ── Helpers ────────────────────────────────────────────────

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
        firmwareVersion: r(3),
        temperature: r(5).toDouble(),
        systemTempF: r(7).toSigned(16).toDouble(),
        setVoltage: r(8) / 100.0,
        setCurrent: r(9) / 1000.0,
        outputVoltage: r(10) / 100.0,
        outputCurrent: r(11) / 1000.0,
        keyLock: r(15),
        protectionStatus: r(16),
        isConstantCurrent: r(17) == 1,
        outputEnabled: r(18) == 1,
        capacityMah: r(39),
        energyMwh: r(41),
        memorySlots: slots,
        screenBrightness: r(72));
  }
}
