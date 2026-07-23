// ignore_for_file: unused_field
import 'dart:async';
import 'dart:math';
import '../models/power_supply_data.dart';
import 'modbus_service.dart';

/// Generates realistic simulated power-supply data so the UI can be
/// previewed without a physical device connected.
///
/// The mock holds a "virtual setpoint" and simulates a load that draws
/// current proportional to the set voltage, with small random drifts
/// that mimic real ADC noise.
class MockModbusService implements ModbusService {
  final _controller = StreamController<PowerSupplyData>.broadcast();
  Timer? _timer;

  // Virtual device state
  final _rng = Random();
  double _vOut = 4.20;
  double _iOut = 1.52;
  double _vSet = 4.20;
  double _iSet = 2.00;
  double _ovp = 62.00; // held for slot-load restore path
  double _ocp = 6.200; // held for slot-load restore path
  bool _outputEnabled = true;
  bool _ccMode = false;
  int _energyMwh = 22;
  int _capacityMah = 15;
  double _temperature = 30.0;
  double _vIn = 15.72;
  int _slotIndex = 0;
  // Phase A mock additions for the schema-audit register map.
  final int _firmwareVersion = 0x0100; // mock firmware 1.0.0
  int _keyLock = 0; // 0=unlocked by default (writable via HR[15])
  final int _protectionStatus = 0; // 0=normal (mock never asserts OVP/OCP/OTP)
  final double _systemTempF = 86.0; // ~30°C in Fahrenheit
  int _quickSlot = 0; // mirrors the value last written to HR[19]

  // Mock slot storage: index → [vSetRaw, iSetRaw, ovpRaw, ocpRaw]
  final Map<int, List<int>> _slots = {
    0: [35, 2000, 6200, 6200],
    1: [500, 5000, 600, 6200],
    2: [500, 6100, 6200, 6200],
    3: [500, 6100, 6200, 6200],
    4: [500, 6100, 6200, 6200],
    5: [500, 6100, 6200, 6200],
    6: [500, 6100, 6200, 6200],
    7: [500, 6100, 6200, 6200],
    8: [500, 6100, 6200, 6200],
    9: [500, 6100, 6200, 6200],
  };

  @override
  bool get isConnected => _timer != null && _timer!.isActive;

  @override
  Stream<PowerSupplyData> get dataStream => _controller.stream;

  @override
  Future<void> connect({String? port, int baudRate = 115200, int address = 1}) async {
    if (isConnected) return;
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    // Emit first value immediately
    _tick();
  }

  @override
  Future<List<String>> listPorts() async =>
      ['/dev/ttyUSB0', '/dev/ttyUSB1', 'MOCK'];

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
  }

  // ── Write helpers ──────────────────────────────────────────────

  @override
  Future<void> writeRegister(int address, int value) async {
    // Mock-side routing for the new Phase A writes so UI / provider
    // code can be validated against the schema even without a device.
    switch (address) {
      case 15:
        _keyLock = value.clamp(0, 1);
        break;
      case 19:
        // HR[19] — quick-switch to M0..M9. Mirror the value so a
        // subsequent readRawRegisters() can observe the change.
        _quickSlot = value.clamp(0, 9);
        break;
      default:
        // no-op for mock (other writes target setVoltage etc. via
        // their typed setters).
        break;
    }
  }

  @override
  Future<void> quickSwitch(int slotIndex) async {
    _quickSlot = slotIndex.clamp(0, 9);
  }

  @override
  Future<void> setVoltage(double volts) async {
    _vSet = volts.clamp(0, 62);
    if (_outputEnabled) _vOut = _vSet;
  }

  @override
  Future<void> setCurrent(double amps) async {
    _iSet = amps.clamp(0, 6.2);
  }

  @override
  Future<void> setOutput(bool enable) async {
    _outputEnabled = enable;
    if (!enable) {
      _vOut = 0;
      _iOut = 0;
    } else {
      _vOut = _vSet;
      _iOut = _iSet.clamp(0, 2.0); // load-limited
    }
  }

  @override
  @Deprecated('Use quickSwitch(slotIndex) instead — Phase B verified '
      'HR[19] as the device-side quick-switch entry point')
  Future<void> loadMemorySlot(int slotIndex) async {
    _slotIndex = slotIndex;
    final raw = _slots[slotIndex];
    if (raw != null && raw.length >= 4) {
      _vSet = raw[0] / 100.0;
      _iSet = raw[1] / 1000.0;
      _ovp = raw[2] / 100.0;
      _ocp = raw[3] / 1000.0;
      if (_outputEnabled) _vOut = _vSet;
    }
  }

  @override
  Future<void> saveMemorySlot(int index, double vSet, double iSet, double ovp, double ocp) async {
    _slots[index] = [(vSet * 100).round(), (iSet * 1000).round(), (ovp * 100).round(), (ocp * 1000).round()];
  }

  @override
  Future<List<int>?> readMemorySlot(int index) async {
    return _slots[index];
  }

  /// Phase B.1 — mock bulk-read all 10 memory slots.  The mock's
  /// `_slots` map is the source of truth, so we synthesise the
  /// [MemorySlot] list directly without going through the simulated
  /// register array (the same approach [readRawRegisters] uses for
  /// HR[80..119]).
  @override
  Future<List<MemorySlot>> readAllMemorySlots() async {
    final result = <MemorySlot>[];
    for (int s = 0; s < 10; s++) {
      final raw = _slots[s];
      if (raw != null && raw.length >= 4) {
        result.add(MemorySlot(
          index: s,
          vSet: raw[0] / 100.0,
          iSet: raw[1] / 1000.0,
          ovp: raw[2] / 100.0,
          ocp: raw[3] / 1000.0,
        ));
      }
    }
    return result;
  }

  @override
  Future<void> setOVP(double volts) async {
    _ovp = volts.clamp(0, 62);
  }
  @override
  Future<void> setOCP(double amps) async {
    _ocp = amps.clamp(0, 6.2);
  }

  @override
  Future<PowerSupplyData?> readAllRegisters() async {
    return PowerSupplyData(timestamp: DateTime.now());
  }

  /// Return a synthetic 121-register snapshot that mirrors the
  /// mock's current internal state.  This simulates what a real
  /// device would report on a full read and lets the Phase A.5
  /// verification flow exercise the full plumbing against the mock.
  @override
  Future<List<int>?> readRawRegisters({String? dedup, int? expireMs}) async {
    final regs = List<int>.filled(121, 0);
    regs[0] = 60067; // modelId
    regs[3] = _firmwareVersion;
    regs[5] = _temperature.round();
    regs[7] = _systemTempF.round();
    regs[8] = (_vSet * 100).round();
    regs[9] = (_iSet * 1000).round();
    regs[10] = (_vOut * 100).round();
    regs[11] = (_iOut * 1000).round();
    regs[14] = (_vIn * 100).round();
    regs[15] = _keyLock;
    regs[16] = _protectionStatus;
    regs[17] = _ccMode ? 1 : 0;
    regs[18] = _outputEnabled ? 1 : 0;
    regs[19] = _quickSlot;
    regs[39] = _capacityMah;
    regs[41] = _energyMwh;
    // Phase B.1 — HR82/HR83 (active OVP/OCP) intentionally NOT
    // populated here: they are the SAME register bytes as M0 slot
    // storage (datasheet address-overlap, see register_definition).
    // The slot-loop below populates regs[80..119] which includes the
    // M0 OVP/OCP at regs[82]/[83].  Setting them separately would be
    // dead code (loop overwrites).
    regs[72] = 3; // screen brightness (legacy mock default)
    for (int s = 0; s < 10; s++) {
      final raw = _slots[s];
      if (raw != null && raw.length >= 4) {
        regs[80 + s * 4] = raw[0];
        regs[80 + s * 4 + 1] = raw[1];
        regs[80 + s * 4 + 2] = raw[2];
        regs[80 + s * 4 + 3] = raw[3];
      }
    }
    return regs;
  }

  @override
  void pauseTieredPolling() {}
  @override
  void resumeTieredPolling() {}
  @override
  void incNotify() {}

  // ── Internal tick ──────────────────────────────────────────────

  void _tick() {
    _temperature += (_rng.nextDouble() - 0.5) * 0.1;
    _temperature = _temperature.clamp(25, 45);

    _vIn += (_rng.nextDouble() - 0.5) * 0.02;
    _vIn = _vIn.clamp(14.5, 16.5);

    if (_outputEnabled) {
      // Slight drift around setpoint to mimic regulation
      _vOut += (_rng.nextDouble() - 0.5) * 0.008;
      _vOut = _vOut.clamp(0, _vSet + 0.05);
      if (_vOut > _vSet) _vOut = _vSet + 0.002;

      _iOut += (_rng.nextDouble() - 0.5) * 0.003;
      _iOut = _iOut.clamp(0, _iSet);
      if (_iOut >= _iSet - 0.002) {
        _ccMode = true;
        _iOut = _iSet;
      } else {
        _ccMode = false;
      }

      _energyMwh += _rng.nextInt(2);
      _capacityMah += _rng.nextInt(1);
    }

    _controller.add(PowerSupplyData(
      timestamp: DateTime.now(),
      modelId: 60067,
      inputVoltage: _vIn,
      temperature: _temperature,
      outputVoltage: _vOut,
      outputCurrent: _iOut,
      // Phase B.2 — inputVoltageAlt /10 path removed (service parity).
      keyLock: _keyLock,
      protectionStatus: _protectionStatus,
      isConstantCurrent: _ccMode,
      outputEnabled: _outputEnabled,
      capacityMah: _capacityMah,
      energyMwh: _energyMwh,
      firmwareVersion: _firmwareVersion,
      systemTempF: _systemTempF,
      setVoltage: _vSet,
      setCurrent: _iSet,
      memorySlots: [],
      screenBrightness: 3,
    ));
  }

  /// Test helper (P1-2): emit a single snapshot with
  /// [CommStatus.error] into the data stream to verify that
  /// [PowerSupplyProvider._onData] flips `_connected = false` and
  /// upgrades its own `commStatus` to `error` when the service
  /// signals a worker-level crash.
  ///
  /// Mirrors what [SerialModbusService._handleWorkerError] does on
  /// a real [ModbusWorkerHandle] isolate crash — the mock has no
  /// isolate to actually kill, so we synthesize the same error
  /// snapshot instead.  Not invoked by any production path.
  void simulateCrash() {
    _controller.add(PowerSupplyData(
      timestamp: DateTime.now(),
      commStatus: CommStatus.error,
    ));
  }
}
