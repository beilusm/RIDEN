import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import '../models/power_supply_data.dart';
import 'modbus_scheduler.dart';
import 'modbus_task.dart';

/// Thrown by [ModbusWorkerHandle] when the worker isolate exits
/// unexpectedly (crash, uncaught error, or handshake failure) while
/// one or more requests are still pending.
///
/// Callers awaiting a pending request receive this via the Future's
/// error channel. Inside this library it is used to distinguish a
/// dead-worker condition from an ordinary Modbus timeout; outside the
/// library it propagates as a generic [Exception].
class _WorkerCrashedException implements Exception {
  final String reason;
  _WorkerCrashedException(this.reason);
  @override
  String toString() => '_WorkerCrashedException: $reason';
}

/// ── Worker entry point (runs in Modbus isolate) ──────────────

void _workerEntry(SendPort uiSendPort) {
  final receiver = ReceivePort();
  uiSendPort.send(receiver.sendPort); // handshake: send our port back

  final worker = _ModbusWorkerCore(uiSendPort);
  receiver.listen((msg) {
    worker._onMessage(msg as Map<String, dynamic>);
  });
}

/// ── Core worker logic ───────────────────────────────────────

class _ModbusWorkerCore {
  final SendPort _uiPort;
  final ModbusScheduler _scheduler = ModbusScheduler();

  SerialPort? _port;
  Timer? _fastTimer;
  Timer? _slowTimer;
  int _slowSlotIdx = 0;

  int _addr = 0x01;
  int _baudRate = 115200;

  static const int _kFastIntervalMs = 150;
  static const int _kFastReadStart = 5;
  static const int _kFastReadCount = 79;

  _ModbusWorkerCore(this._uiPort);

  // ── Message dispatch ──────────────────────────────────────────

  void _onMessage(Map<String, dynamic> msg) {
    final cmd = msg['cmd'] as String;
    final id = msg['id'] as int;

    switch (cmd) {
      case 'connect':
        _connect(id, msg['port'] as String?,
            msg['baudRate'] as int?, msg['addr'] as int?);
        break;
      case 'list_ports':
        _reply(id, 'result', SerialPort.availablePorts);
        break;
      case 'disconnect':
        _disconnect(id);
        break;
      case 'read':
        _enqueueRead(id, msg);
        break;
      case 'write':
        _enqueueWrite(id, msg);
        break;
      case 'pausePoll':
        _pauseTieredPolling();
        _reply(id, 'result', null);
        break;
      case 'resumePoll':
        _resumeTieredPolling();
        _reply(id, 'result', null);
        break;
      case 'shutdown':
        _shutdown(id);
        break;
      default:
        _replyError(id, 'Unknown command: $cmd');
    }
  }

  void _reply(int id, String type, dynamic data, {String? error}) {
    _uiPort.send({
      'id': id,
      'type': type,
      'data': data,
      'error': error,
    });
  }

  void _replyError(int id, String error) {
    _reply(id, 'error', null, error: error);
  }

  void _reportError(String error) {
    _uiPort.send({'id': -3, 'type': 'worker_error', 'error': error});
  }

  void _replyData(PowerSupplyData data) {
    // Serialize PowerSupplyData to a map for isolate transport
    _uiPort.send({
      'id': -1,
      'type': 'data',
      'data': _serializeData(data),
    });
  }

  Map<String, dynamic> _serializeData(PowerSupplyData d) => {
        'timestamp': d.timestamp.millisecondsSinceEpoch,
        'modelId': d.modelId,
        'inputVoltage': d.inputVoltage,
        // NOTE: 'auxVoltage' / 'statusFlags' kept in the wire map for
        // backwards compatibility with cached snapshots — they are no
        // longer populated and stay at their defaults (0 / 0).
        'auxVoltage': d.auxVoltage,
        'temperature': d.temperature,
        'systemTempF': d.systemTempF,
        'setVoltage': d.setVoltage,
        'setCurrent': d.setCurrent,
        'outputVoltage': d.outputVoltage,
        'outputCurrent': d.outputCurrent,
        'inputVoltageAlt': d.inputVoltageAlt,
        'statusFlags': d.statusFlags,
        'keyLock': d.keyLock,
        'protectionStatus': d.protectionStatus,
        'isConstantCurrent': d.isConstantCurrent,
        'outputEnabled': d.outputEnabled,
        'capacityMah': d.capacityMah,
        'energyMwh': d.energyMwh,
        'firmwareVersion': d.firmwareVersion,
        'ovp': d.ovp,
        'ocp': d.ocp,
        'commStatus': d.commStatus.index,
        'screenBrightness': d.screenBrightness,
        'slots': d.memorySlots
            .map((s) => {
                  'index': s.index,
                  'vSet': s.vSet,
                  'iSet': s.iSet,
                  'ovp': s.ovp,
                  'ocp': s.ocp,
                })
            .toList(),
      };

  // ── Port detection ──────────────────────────────────────────

  static String _detectPort() {
    for (final p in SerialPort.availablePorts) {
      final lower = p.toLowerCase();
      // Linux: /dev/ttyUSB* or /dev/ttyACM*
      // macOS: /dev/cu.usbserial* or /dev/cu.usbmodem*
      // Windows: COM*
      if (lower.contains('ttyusb') ||
          lower.contains('ttyacm') ||
          lower.contains('usbserial') ||
          lower.contains('usbmodem') ||
          lower.contains('cuserial') ||
          lower.startsWith('com')) {
        return p;
      }
    }
    final ports = SerialPort.availablePorts;
    if (ports.isNotEmpty) return ports.first;
    throw Exception('No serial port found. Connect RIDEN via CH340 USB.');
  }

  // ── Connect / Disconnect ──────────────────────────────────────

  void _connect(int id, String? portName, int? baudRate, int? addr) {
    try {
      _addr = (addr == null || addr <= 0 || addr > 247) ? 0x01 : addr;
      _baudRate = (baudRate == null || baudRate <= 0) ? 115200 : baudRate;
      portName ??= _detectPort();
      _port = SerialPort(portName);
      if (!_port!.openReadWrite()) {
        final err = SerialPort.lastError;
        _port!.dispose();
        _port = null;
        _replyError(id, 'Failed to open $portName: ${err?.message ?? "unknown"}');
        return;
      }
      final cfg = _port!.config;
      cfg.baudRate = _baudRate;
      cfg.bits = 8;
      cfg.parity = SerialPortParity.none;
      cfg.stopBits = 1;
      cfg.setFlowControl(SerialPortFlowControl.none);
      _port!.config = cfg;

      _reply(id, 'result', true);
      _resumeTieredPolling();

      // Init read (HR[0..7]) — model ID, serial number (Hi/Lo),
      // firmware version, system temperature C sign/value,
      // system temperature F value.
      _enqueueReadBackground(0, 8, (regs) {
        if (regs != null && regs.length >= 8) {
          final d = PowerSupplyData(
            timestamp: DateTime.now(),
            modelId: regs[0],
            // HR[3] = firmware version (uint16 RO, no scaling).
            firmwareVersion: regs[3],
            // HR[5] = system temperature °C (datasheet sign in HR[4]).
            temperature: regs[5].toDouble(),
            // HR[7] = system temperature °F (int16 signed).
            // toSigned(16) handles negative temperatures; the wire
            // value is a 16-bit unsigned that we reinterpret as two's
            // complement.
            systemTempF: regs[7].toSigned(16).toDouble(),
          );
          _replyData(d);
        }
      });
    } catch (e) {
      _replyError(id, 'connect error: $e');
    }
  }

  void _disconnect(int id) {
    _pauseTieredPolling();
    _scheduler.shutdown().then((_) {
      _port?.close();
      _port?.dispose();
      _port = null;
      _reply(id, 'result', true);
    });
  }

  void _shutdown(int id) {
    _pauseTieredPolling();
    _scheduler.shutdown().then((_) {
      _port?.close();
      _port?.dispose();
      _port = null;
      _reply(id, 'result', true);
    });
  }

  // ── Poll control ──────────────────────────────────────────────

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
        Duration(milliseconds: _kFastIntervalMs), (_) => _fastPoll());
    _slowTimer =
        Timer.periodic(const Duration(milliseconds: 1000), (_) => _slowPoll());
    _fastPoll();
    _slowPoll();
  }

  // ── FAST poll ─────────────────────────────────────────────────

  void _fastPoll() {
    if (_port == null || !_port!.isOpen) return;
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
        // r(10) = HR[15] — Key Lock (enum R/W).  0=unlocked, 1=locked.
        keyLock: inRange(10) ? r(10) : 0,
        // r(11) = HR[16] — Protection Status (enum RO).
        // 0=normal, 1=OVP, 2=OCP, 3=OTP.
        protectionStatus: inRange(11) ? r(11) : 0,
        isConstantCurrent: inRange(12) ? r(12) == 1 : false,
        outputEnabled: inRange(13) ? r(13) == 1 : false,
        capacityMah: inRange(34) ? r(34) : 0,
        energyMwh: inRange(36) ? r(36) : 0,
        ovp: inRange(77) ? r(77) / 100.0 : 0,
        ocp: inRange(78) ? r(78) / 1000.0 : 0,
      );
      _replyData(d);
    });
  }

  // ── SLOW poll ─────────────────────────────────────────────────

  void _slowPoll() {
    if (_port == null || !_port!.isOpen) return;
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
        _replyData(d);
      });
    }
    _slowSlotIdx = (_slowSlotIdx + 2) % 10;
  }

  // ── Read / Write ──────────────────────────────────────────────

  void _enqueueRead(int id, Map<String, dynamic> msg) {
    final start = msg['start'] as int;
    final count = msg['count'] as int;
    final prio = msg['prio'] as int? ?? 5;
    final group = msg['group'] as String? ?? 'user';
    final dedup = msg['dedup'] as String?;
    final expire = msg['expire'] as int?;
    final pri = TaskPriority.values.firstWhere(
      (p) => p.base == prio,
      orElse: () => TaskPriority.userRead,
    );

    _enqueueReadDirect(start, count, pri, 'user_read',
        group: group,
        dedupKey: dedup,
        expireAfterMs: expire, onResult: (regs) {
      _reply(id, 'result', regs);
    });
  }

  void _enqueueWrite(int id, Map<String, dynamic> msg) {
    final addr = msg['addr'] as int;
    final value = msg['value'] as int;
    _scheduler
        .enqueue(ModbusTask<void>(
      id: 'wr_${addr}_${DateTime.now().millisecondsSinceEpoch}',
      priority: TaskPriority.write,
      group: 'user',
      execute: () async {
        final frame = _buildWriteFrame(addr, value);
        for (int attempt = 1; attempt <= 2; attempt++) {
          _requirePort.write(frame);
          final resp = _accumulateRead(8, 250);
          if (resp.length >= 8 && resp[1] == 0x06) {
            return;
          }
          if (attempt < 2) await Future.delayed(const Duration(milliseconds: 30));
        }
        throw Exception('Write HR[$addr] failed');
      },
    ))
        .then((_) => _reply(id, 'result', true))
        .catchError((e) => _replyError(id, '$e'));
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
        _requirePort.write(frame);
        final resp = _accumulateRead(expectedLen, 250);

        // Drain on timeout
        if (resp.length < expectedLen) {
          _drainPort(80);
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

  // ── I/O helpers ───────────────────────────────────────────────

  SerialPort get _requirePort {
    if (_port == null || !_port!.isOpen) {
      throw StateError('Serial port not available');
    }
    return _port!;
  }

  Uint8List _accumulateRead(int expectedLen, int overallDeadlineMs) {
    final sw = Stopwatch()..start();
    Uint8List buf = Uint8List(0);
    int attempt = 0;
    while (sw.elapsedMilliseconds < overallDeadlineMs) {
      final need = expectedLen - buf.length;
      if (need <= 0) break;
      attempt++;
      final remaining = overallDeadlineMs - sw.elapsedMilliseconds;
      final timeout = attempt == 1 ? 80 : (remaining < 30 ? remaining : 30);
      final chunk = _requirePort.read(need, timeout: timeout);
      if (chunk.isNotEmpty) {
        final merged = Uint8List(buf.length + chunk.length);
        merged.setAll(0, buf);
        merged.setAll(buf.length, chunk);
        buf = merged;
      }
    }
    return buf;
  }

  int _drainPort(int deadlineMs) {
    final sw = Stopwatch()..start();
    int total = 0;
    while (sw.elapsedMilliseconds < deadlineMs) {
      final chunk = _requirePort.read(256, timeout: 20);
      if (chunk.isEmpty) break;
      total += chunk.length;
    }
    return total;
  }

  // ── Frame builders ────────────────────────────────────────────

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
}

/// ── Public API ──────────────────────────────────────────────

/// Spawns the Modbus worker isolate and returns a [ModbusWorkerHandle]
/// for communicating with it.
class ModbusWorkerHandle {
  final Isolate _isolate;
  final SendPort _workerPort;
  final ReceivePort _uiPort;
  int _nextId = 0;
  final Map<int, Completer<dynamic>> _pending = {};
  StreamController<PowerSupplyData>? _dataController;
  void Function(String)? onError;
  bool _dead = false;
  bool _cleaned = false;

  ModbusWorkerHandle._(this._isolate, this._workerPort, this._uiPort);

  static Future<ModbusWorkerHandle> spawn() async {
    final uiPort = ReceivePort();
    final handshake = Completer<SendPort>();
    late ModbusWorkerHandle handle;

    // Single listener: first message is handshake, rest are dispatched
    // to _onMessage, or to _onIsolateExit on isolate exit/error.
    // Late messages arriving after isolate death are dropped via _dead.
    uiPort.listen((msg) {
      if (!handshake.isCompleted) {
        if (msg is SendPort) {
          handshake.complete(msg);
        } else if (msg == null) {
          handshake.completeError(
              _WorkerCrashedException('isolate exited before handshake'));
        } else if (msg is List && msg.length == 2) {
          handshake.completeError(
              _WorkerCrashedException('isolate init error: ${msg[0]}'));
        } else {
          handshake.completeError(
              _WorkerCrashedException('unexpected handshake message: $msg'));
        }
        return;
      }
      if (handle._dead) return; // idempotent: isolate已死亡, 忽略延迟消息
      if (msg == null) {
        handle._onIsolateExit(false, 'isolate exited');
        return;
      }
      if (msg is List && msg.length == 2) {
        handle._onIsolateExit(true, 'isolate error: ${msg[0]}');
        return;
      }
      handle._onMessage(msg as Map<String, dynamic>);
    });

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _workerEntry,
        uiPort.sendPort,
        onExit: uiPort.sendPort,
        onError: uiPort.sendPort,
      );
      final workerPort = await handshake.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            throw TimeoutException('worker handshake timeout'),
      );
      handle = ModbusWorkerHandle._(isolate, workerPort, uiPort);
      return handle;
    } catch (e) {
      try { isolate?.kill(priority: Isolate.immediate); } catch (_) {}
      try { uiPort.close(); } catch (_) {}
      rethrow;
    }
  }

  Stream<PowerSupplyData> get dataStream {
    _dataController ??= StreamController<PowerSupplyData>.broadcast();
    return _dataController!.stream;
  }

  void _onIsolateExit(bool isError, String reason) {
    if (_dead) return;
    _dead = true;
    final pending = Map<int, Completer<dynamic>>.from(_pending);
    _pending.clear();
    for (final c in pending.values) {
      if (!c.isCompleted) c.completeError(_WorkerCrashedException(reason));
    }
    onError?.call(reason);
    _cleanup();
  }

  void forceKill() {
    _dead = true;
    final pending = Map<int, Completer<dynamic>>.from(_pending);
    _pending.clear();
    for (final c in pending.values) {
      if (!c.isCompleted) c.completeError(_WorkerCrashedException('forced kill'));
    }
    _cleanup();
  }

  void _cleanup() {
    if (_cleaned) return;
    _cleaned = true;
    try { _dataController?.close(); } catch (_) {}
    try { _uiPort.close(); } catch (_) {}
    try { _isolate.kill(priority: Isolate.immediate); } catch (_) {}
  }

  void _onMessage(dynamic msg) {
    final m = msg as Map<String, dynamic>;
    final id = m['id'] as int;
    final type = m['type'] as String;

    if (id == -1 && type == 'data') {
      // Stream data from FAST/SLOW poll
      final d = _deserializeData(m['data'] as Map<String, dynamic>);
      _dataController?.add(d);
      return;
    }

    if (id == -3 && type == 'worker_error') {
      // Async error from worker (port crash, etc.)
      onError?.call(m['error'] as String? ?? 'unknown worker error');
      return;
    }

    final completer = _pending.remove(id);
    if (completer == null) return;

    if (type == 'error') {
      completer.completeError(Exception(m['error'] ?? 'unknown'));
    } else {
      completer.complete(m['data']);
    }
  }

  Future<T> _send<T>(String cmd, Map<String, dynamic> params) {
    final id = _nextId++;
    final completer = Completer<T>();
    _pending[id] = completer;
    _workerPort.send({
      'id': id,
      'cmd': cmd,
      ...params,
    });
    return completer.future;
  }

  Future<void> connect({String? port, int baudRate = 115200, int address = 1}) =>
      _send('connect', {
        'port': port,
        'baudRate': baudRate,
        'addr': address,
      });

  Future<void> disconnect() => _send('disconnect', {});

  Future<List<String>> listPorts() async {
    final r = await _send<dynamic>('list_ports', {});
    if (r is List) {
      return r.cast<String>();
    }
    return <String>[];
  }

  Future<List<int>?> readRegisters(
          int start, int count,
          {int prio = 5, String group = 'user',
           String? dedup, int? expire}) =>
      _send<List<int>?>('read', {
        'start': start,
        'count': count,
        'prio': prio,
        'group': group,
        'dedup': dedup,
        'expire': expire,
      });

  Future<void> writeRegister(int addr, int value) =>
      _send('write', {'addr': addr, 'value': value});

  Future<void> pausePoll() => _send('pausePoll', {});

  Future<void> resumePoll() => _send('resumePoll', {});

  Future<void> shutdown() => _send('shutdown', {}).then((_) {
    _cleanup();
  });

  // ── Data deserialization ──────────────────────────────────────

  PowerSupplyData _deserializeData(Map<String, dynamic> m) {
    final slots = (m['slots'] as List<dynamic>?)?.map((s) {
          final sm = s as Map<String, dynamic>;
          return MemorySlot(
            index: sm['index'] as int,
            vSet: (sm['vSet'] as num).toDouble(),
            iSet: (sm['iSet'] as num).toDouble(),
            ovp: (sm['ovp'] as num).toDouble(),
            ocp: (sm['ocp'] as num).toDouble(),
          );
        }).toList() ??
        [];
    return PowerSupplyData(
      timestamp:
          DateTime.fromMillisecondsSinceEpoch(m['timestamp'] as int),
      modelId: m['modelId'] as int? ?? 0,
      inputVoltage: (m['inputVoltage'] as num?)?.toDouble() ?? 0,
      // Backwards-compat: tolerate old snapshots that still carry
      // 'internalState' instead of 'systemTempF'.
      systemTempF: (m['systemTempF'] as num?)?.toDouble() ??
          (m['internalState'] as num?)?.toDouble() ??
          0,
      auxVoltage: (m['auxVoltage'] as num?)?.toDouble() ?? 0,
      temperature: (m['temperature'] as num?)?.toDouble() ?? 0,
      setVoltage: (m['setVoltage'] as num?)?.toDouble() ?? 0,
      setCurrent: (m['setCurrent'] as num?)?.toDouble() ?? 0,
      outputVoltage: (m['outputVoltage'] as num?)?.toDouble() ?? 0,
      outputCurrent: (m['outputCurrent'] as num?)?.toDouble() ?? 0,
      inputVoltageAlt:
          (m['inputVoltageAlt'] as num?)?.toDouble() ?? 0,
      statusFlags: m['statusFlags'] as int? ?? 0,
      keyLock: m['keyLock'] as int? ?? 0,
      protectionStatus: m['protectionStatus'] as int? ?? 0,
      isConstantCurrent: m['isConstantCurrent'] as bool? ?? false,
      outputEnabled: m['outputEnabled'] as bool? ?? false,
      capacityMah: m['capacityMah'] as int? ?? 0,
      energyMwh: m['energyMwh'] as int? ?? 0,
      firmwareVersion: m['firmwareVersion'] as int? ?? 0,
      ovp: (m['ovp'] as num?)?.toDouble() ?? 0,
      ocp: (m['ocp'] as num?)?.toDouble() ?? 0,
      commStatus: CommStatus.values[m['commStatus'] as int? ?? 0],
      screenBrightness: m['screenBrightness'] as int? ?? 3,
      memorySlots: slots,
    );
  }
}
