import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/power_supply_data.dart';
import '../services/modbus_service.dart';

class PowerSupplyProvider extends ChangeNotifier {
  final ModbusService _service;
  StreamSubscription<PowerSupplyData>? _sub;

  static const int maxChartPoints = 300;

  PowerSupplyProvider(this._service);

  // ── Current snapshot (the RegisterCache) ───────────────────────
  PowerSupplyData _data = PowerSupplyData(timestamp: DateTime.now());
  PowerSupplyData get data => _data;

  // ── Rolling chart history ──────────────────────────────────────
  final List<PowerSupplyData> _chartData = [];
  List<PowerSupplyData> get chartData => List.unmodifiable(_chartData);

  // ── Connection state ───────────────────────────────────────────
  bool _connected = false;
  bool get connected => _connected;

  String? _connectedPort;
  String? get connectedPort => _connectedPort;
  int _baudRate = 115200;
  int get baudRate => _baudRate;
  int _address = 1;
  int get address => _address;
  bool _connecting = false;
  bool get connecting => _connecting;

  Future<List<String>> listPorts() => _service.listPorts();


  // ── Register view mode ────────────────────────────────────────
  bool _showRegisters = false;
  bool get showRegisters => _showRegisters;
  void toggleRegView() {
    _showRegisters = !_showRegisters;
    if (_showRegisters) {
      _service.pauseTieredPolling();
    } else {
      _service.resumeTieredPolling();
    }
    notifyListeners();
  }

  // ── Communication health ──────────────────────────────────────
  DateTime _lastPollOk = DateTime.now();
  Timer? _healthTimer;
  int _consecutiveFails = 0;
  static const int _timeoutThreshold = 3; // consecutive failures → timeout
  static const int _errorThreshold = 6; // consecutive failures → error

  // ── Memory slots ───────────────────────────────────────────────
  int _activeSlot = 0;
  int get activeSlot => _activeSlot;
  final Map<int, List<double>> _slots = {};
  List<double>? slotValues(int index) => _slots[index];

  Timer? _bgSlotTimer;
  bool _slotsLoaded = false;

  // ── Lifecycle ──────────────────────────────────────────────────

  Future<void> connect({String? port, int baudRate = 115200, int address = 1}) async {
    if (_connected || _connecting) return;
    _connecting = true;
    notifyListeners();
    try {
      _baudRate = baudRate;
      _address = address;
      await _service.connect(port: port, baudRate: baudRate, address: address);
      _connectedPort = port;
      _connected = true;
      _lastPollOk = DateTime.now();
      _consecutiveFails = 0;
      _sub = _service.dataStream.listen(_onData);
      _data = _data.copyWith(commStatus: CommStatus.online);
      _startBgSlotRefresh();
      _startHealthCheck();
    } catch (e) {
      debugPrint('[PROVIDER] connect failed: $e');
      rethrow;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _healthTimer?.cancel();
    _bgSlotTimer?.cancel();
    _bgSlotTimer = null;
    _sub?.cancel();
    _sub = null;
    await _service.disconnect();
    _connected = false;
    _connectedPort = null;
    _chartData.clear();
    _data = _data.copyWith(commStatus: CommStatus.offline);
    notifyListeners();
  }

  /// Disconnect, then reconnect with new parameters (or the cached ones).
  Future<void> reconnect({String? port, int? baudRate, int? address}) async {
    if (_connected || _connecting) {
      await disconnect();
    }
    await connect(
      port: port ?? _connectedPort,
      baudRate: baudRate ?? _baudRate,
      address: address ?? _address,
    );
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _bgSlotTimer?.cancel();
    _sub?.cancel();
    _service.disconnect();
    super.dispose();
  }

  // ── Health check timer ─────────────────────────────────────────

  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_connected) return;
      final since = DateTime.now().difference(_lastPollOk);
      if (since.inMilliseconds > 3000) {
        _updateCommStatus(CommStatus.timeout);
      }
    });
  }

  void _updateCommStatus(CommStatus status) {
    if (_data.commStatus != status) {
      _data = _data.copyWith(commStatus: status);
      notifyListeners();
    }
  }

  // ── Internal data handler ──────────────────────────────────────

  void _onData(PowerSupplyData snapshot) {
    _lastPollOk = DateTime.now();
    _consecutiveFails = 0;

    // Keep comm status from the service snapshot, or compute our own
    final merged = snapshot.copyWith(
      commStatus: _data.commStatus == CommStatus.offline
          ? CommStatus.online
          : _data.commStatus,
    );

    _data = merged;
    _chartData.add(merged);
    while (_chartData.length > maxChartPoints) {
      _chartData.removeAt(0);
    }

    if (snapshot.memorySlots.isNotEmpty) {
      for (final s in snapshot.memorySlots) {
        _slots[s.index] = [s.vSet, s.iSet, s.ovp, s.ocp];
      }
      _slotsLoaded = true;
      _bgSlotTimer?.cancel();
      _bgSlotTimer = null;
    }

    _updateCommStatus(CommStatus.online);
    _service.incNotify();
    notifyListeners();
  }

  // Fallback: called when a poll produces no data
  void _onPollMiss() {
    _consecutiveFails++;
    if (_consecutiveFails >= _errorThreshold) {
      _updateCommStatus(CommStatus.error);
    } else if (_consecutiveFails >= _timeoutThreshold) {
      _updateCommStatus(CommStatus.timeout);
    }
  }

  void _startBgSlotRefresh() {
    if (_slotsLoaded) return;
    // Phase B.1 — single bulk read (HR[80..119] = 40 registers in one
    // RTU round-trip).  Previously this used a 500ms Timer × 10 firing
    // 10 individual `readMemorySlot(i)` requests — worst-case ~2.5s
    // total.  Now one call completes in ~250ms.  Failure path falls
    // back to the worker's own SLOW poll, which already fills in
    // `memorySlots` via the dataStream listener in [_onData].
    refreshAllSlots();
  }

  Future<void> _loadOneSlot(int index) async {
    try {
      final raw = await _service.readMemorySlot(index);
      if (raw != null && raw.length >= 4) {
        _slots[index] = [raw[0] / 100.0, raw[1] / 1000.0, raw[2] / 100.0, raw[3] / 1000.0];
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[PROVIDER] _loadOneSlot($index) failed: $e');
    }
  }

  /// Bulk-refresh all 10 memory slots.  Phase B.1 — previously issued
  /// 10 sequential `readMemorySlot(i)` calls (one 4-register Modbus
  /// RTU each, ~250ms per request → up to ~2.5s total when the device
  /// was slow).  Now uses [ModbusService.readAllMemorySlots] — a
  /// single 40-register bulk read of HR[80..119], one RTU round-trip
  /// (~250ms typical, ~500ms worst-case on slow devices).
  Future<void> refreshAllSlots() async {
    try {
      final t = Stopwatch()..start();
      final slots = await _service.readAllMemorySlots();
      t.stop();
      debugPrint('[PROVIDER] refreshAllSlots bulk-read '
          '${slots.length}/10 slots in ${t.elapsedMilliseconds}ms');
      for (final s in slots) {
        _slots[s.index] = [s.vSet, s.iSet, s.ovp, s.ocp];
      }
      _slotsLoaded = true;
      _bgSlotTimer?.cancel();
      _bgSlotTimer = null;
      notifyListeners();
    } catch (e) {
      debugPrint('[PROVIDER] refreshAllSlots failed: $e');
    }
  }

  // ── Optimistic write helpers ───────────────────────────────────

  /// Apply an optimistic update, execute the write, rollback on failure.
  Future<void> _optimisticWrite(
    PowerSupplyData optimistic,
    Future<void> Function() write,
  ) async {
    final prev = _data;
    _data = optimistic;
    notifyListeners();

    try {
      await write();
      // Success — next poll confirms
    } catch (e) {
      debugPrint('[PROVIDER] write failed, rollback: $e');
      _data = prev;
      notifyListeners();
    }
  }

  // ── User actions ───────────────────────────────────────────────

  Future<void> setVoltage(double v) async {
    await _optimisticWrite(
      _data.copyWith(setVoltage: v),
      () => _service.setVoltage(v),
    );
  }

  Future<void> setCurrent(double a) async {
    await _optimisticWrite(
      _data.copyWith(setCurrent: a),
      () => _service.setCurrent(a),
    );
  }

  Future<void> setOutput(bool enable) async {
    await _optimisticWrite(
      _data.copyWith(outputEnabled: enable),
      () => _service.setOutput(enable),
    );
  }

  Future<void> setOVP(double v) async {
    await _optimisticWrite(
      _data.copyWith(ovp: v),
      () => _service.setOVP(v),
    );
  }

  Future<void> setOCP(double a) async {
    await _optimisticWrite(
      _data.copyWith(ocp: a),
      () => _service.setOCP(a),
    );
  }

  /// Phase B: hardware quick-switch to memory slot M0..M9.
  ///
  /// Writes HR[19] = [slotIndex] via the device protocol verified in
  /// Phase A.5.  After writing, waits briefly for the device firmware
  /// to load the slot's preset into the active registers, then issues
  /// a full 121-register read so the UI state reflects the device's
  /// actual post-switch state — not a software cache.
  ///
  /// Replaces the legacy [loadSlot] path that did 4 separate writes
  /// (setVoltage / setCurrent / setOVP / setOCP).  Kept for fallback
  /// only; UI now calls [quickSwitch].
  Future<void> quickSwitch(int slotIndex) async {
    if (slotIndex < 0 || slotIndex > 9) return;
    _activeSlot = slotIndex;
    notifyListeners();

    // Phase B.1 — OVP/OCP are per-slot (user clarification after
    // hardware regression).  The active OVP/OCP values live at the
    // slot's storage address HR[80+N*4+2 / 80+N*4+3], NOT at HR82/83
    // (which is M0's storage and only reflects M0's OVP/OCP per the
    // datasheet address-overlap note in register_definition.dart:546).
    // Switching to M1 → device uses M1's OVP from HR86/87; the UI
    // must read those same bytes, not HR82/83.
    final slotBase = 80 + slotIndex * 4;
    final slotOvpAddr = slotBase + 2;
    final slotOcpAddr = slotBase + 3;

    try {
      // Phase B.1 — capture BEFORE snapshot for debug log so
      // M0↔M1/M2 bidirectional switches can be diffed in the console.
      final before = await _service.readRawRegisters(
          dedup: 'qsw_pre', expireMs: 1500);
      if (before != null && before.length >= 84) {
        debugPrint('[QSW] before M$slotIndex  '
            'HR19=${_reg(before, 19)}  '
            'HR8=${_reg(before, 8) / 100.0}V  '
            'HR9=${_reg(before, 9) / 1000.0}A  '
            'M${slotIndex}OVP=${_reg(before, slotOvpAddr) / 100.0}V  '
            'M${slotIndex}OCP=${_reg(before, slotOcpAddr) / 1000.0}A');
      } else {
        debugPrint('[QSW] before M$slotIndex  '
            'read failed/null (len=${before?.length})');
      }

      await _service.quickSwitch(slotIndex);
      // Allow ~600ms for the device firmware to apply the slot preset.
      // 600ms is comfortably above the FAST poll interval (150ms × ~4
      // cycles) so the next read reflects a settled state.
      await Future.delayed(const Duration(milliseconds: 600));
      // Refresh UI state from the device (full read at user priority).
      final raw = await _service.readRawRegisters(
          dedup: 'quick_switch', expireMs: 1500);
      if (raw != null && raw.length >= 20) {
        _data = _data.copyWith(
          // Init-read fields: read once and retained.  quickSwitch
          // refresh can update them too since the full read covers
          // HR0..HR120.
          modelId: raw[0],
          firmwareVersion: raw[3],
          systemTempF: raw[7].toSigned(16).toDouble(),
          // Fast-poll fields.
          setVoltage: raw[8] / 100.0,
          setCurrent: raw[9] / 1000.0,
          keyLock: raw[15],
          protectionStatus: raw[16],
          isConstantCurrent: raw[17] == 1,
          outputEnabled: raw[18] == 1,
          // Phase B.1 — OVP/OCP for the ACTIVE slot.  Source = slot's
          // own storage at HR[80+slot*4+2/3].  Reading HR82/83 instead
          // would show M0's OVP/OCP regardless of active slot (that
          // was the pre-fix bug — UI kept showing M0 protection
          // values even after switching to M1/M2).
          ovp: raw.length > slotOvpAddr
              ? raw[slotOvpAddr] / 100.0
              : _data.ovp,
          ocp: raw.length > slotOcpAddr
              ? raw[slotOcpAddr] / 1000.0
              : _data.ocp,
        );
        notifyListeners();
        // Phase B.1 — AFTER snapshot.  Key: HR19 must match slotIndex
        // (device-side confirmation), HR8/HR9 should match the slot's
        // stored preset, OVP/OCP come from the slot's own storage.
        if (raw.length >= 84) {
          debugPrint('[QSW] after  M$slotIndex  '
              'HR19=${_reg(raw, 19)} (expect=$slotIndex)  '
              'HR8=${_reg(raw, 8) / 100.0}V  '
              'HR9=${_reg(raw, 9) / 1000.0}A  '
              'M${slotIndex}OVP=${_reg(raw, slotOvpAddr) / 100.0}V  '
              'M${slotIndex}OCP=${_reg(raw, slotOcpAddr) / 1000.0}A');
        }
      }
    } catch (e) {
      debugPrint('[PROVIDER] quickSwitch M$slotIndex FAILED: $e');
    }
  }

  /// Bounds-safe accessor used by [quickSwitch] debug logs.
  int _reg(List<int> regs, int addr) =>
      addr < regs.length ? regs[addr] : -1;

  @Deprecated('Use quickSwitch(slotIndex) instead — Phase B replaced '
      'this 4-write path with a single HR[19] quick-switch.  Kept '
      'for fallback / A/B comparison; no UI caller remains.')
  Future<void> loadSlot(int index) async {
    _activeSlot = index;
    final cached = _slots[index];

    if (cached != null && cached.length >= 4) {
      // Optimistic: update all 4 values at once, then write
      final prev = _data;
      _data = _data.copyWith(
        setVoltage: cached[0],
        setCurrent: cached[1],
        ovp: cached[2],
        ocp: cached[3],
      );
      notifyListeners();

      try {
        await _service.setVoltage(cached[0]);
        await _service.setCurrent(cached[1]);
        await _service.setOVP(cached[2]);
        await _service.setOCP(cached[3]);
      } catch (e) {
        debugPrint('[PROVIDER] loadSlot M$index FAILED: $e');
        _data = prev;
        notifyListeners();
        return;
      }
    } else {
      await _service.loadMemorySlot(index);
    }
    notifyListeners();
  }

  Future<void> fullPoll() async {
    final data = await _service.readAllRegisters();
    if (data != null) {
      _data = data;
      notifyListeners();
    }
  }

  Future<List<int>?> fullPollRaw({String? dedup, int? expireMs}) =>
      _service.readRawRegisters(dedup: dedup, expireMs: expireMs);

  void writeRawRegister(int address, int value) {
    _service.writeRegister(address, value).catchError((e) {
      debugPrint('[PROVIDER] writeRawRegister HR[$address] failed: $e');
    });
  }

  Future<void> saveSlot(int index) async {
    try {
      await _service.saveMemorySlot(
        index,
        _data.setVoltage,
        _data.setCurrent,
        _data.ovp,
        _data.ocp,
      );
      await _loadOneSlot(index);
    } catch (e) {
      debugPrint('[PROVIDER] saveSlot($index) failed: $e');
      rethrow;
    }
  }
}
