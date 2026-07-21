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
    // no-op for mock (state is held in local fields)
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
  @override
  Future<List<int>?> readRawRegisters({String? dedup, int? expireMs}) async =>
      List.filled(121, 0);

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
      auxVoltage: 3.31,
      temperature: _temperature,
      outputVoltage: _vOut,
      outputCurrent: _iOut,
      inputVoltageAlt: _vIn,
      isConstantCurrent: _ccMode,
      outputEnabled: _outputEnabled,
      capacityMah: _capacityMah,
      energyMwh: _energyMwh,
      setVoltage: _vSet,
      setCurrent: _iSet,
      memorySlots: [],
      screenBrightness: 3,
    ));
  }
}
