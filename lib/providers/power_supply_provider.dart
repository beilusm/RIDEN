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

  int _bgSlotIndex = 0;
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
    _bgSlotTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_bgSlotIndex >= 10) {
        _bgSlotTimer?.cancel();
        _bgSlotTimer = null;
        _slotsLoaded = true;
        return;
      }
      _loadOneSlot(_bgSlotIndex);
      _bgSlotIndex++;
    });
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

  Future<void> refreshAllSlots() async {
    for (int i = 0; i < 10; i++) {
      try {
        final raw = await _service.readMemorySlot(i);
        if (raw != null && raw.length >= 4) {
          _slots[i] = [raw[0] / 100.0, raw[1] / 1000.0, raw[2] / 100.0, raw[3] / 1000.0];
        }
      } catch (e) {
        debugPrint('[PROVIDER] refreshAllSlots($i) failed: $e');
      }
    }
    _slotsLoaded = true;
    _bgSlotTimer?.cancel();
    notifyListeners();
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
