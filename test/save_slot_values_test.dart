import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/models/power_supply_data.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';
import 'package:riden_power_supply/services/modbus_service.dart';
import 'package:riden_power_supply/services/serial_port_scanner.dart';
import 'package:riden_power_supply/providers/power_supply_provider.dart';

/// Tests for [PowerSupplyProvider.saveSlotValues] — the M1..M9 storage
/// edit API surfaced by the Edit entry inside the preset dialog.
///
/// Storage-only edit contract (see provider docstring):
///   * writes HR[80 + index*4 + 0..3] on the device via
///     [ModbusService.saveMemorySlot];
///   * re-reads the slot via [_loadOneSlot] → caches [provider.slotValues];
///   * does NOT touch the live active Vset/Iset (HR8/HR9) — only the
///     slot storage; an OVP/OCP edit on the active slot happens to
///     land on the same physical register (HR[80+activeSlot*4+2/3])
///     by virtue of the Phase B.2 address overlap, but V-Set/I-Set
///     storage edits require a subsequent [quickSwitch] to apply to
///     the live output.
void main() {
  late MockModbusService svc;
  late PowerSupplyProvider provider;

  setUp(() async {
    svc = MockModbusService();
    provider = PowerSupplyProvider(svc);
    await svc.connect();
    // Distinguishing presets so slot edits are easy to assert.
    await svc.saveMemorySlot(0, 5.00, 1.00, 6.0, 2.0);
    await svc.saveMemorySlot(1, 12.00, 3.00, 13.0, 4.0);
    await svc.saveMemorySlot(2, 19.50, 0.50, 20.0, 0.5);
  });

  tearDown(() async {
    await svc.disconnect();
  });

  test('saveSlotValues updates the cached slotValues via service write',
      () async {
    // The mock seed only populated slots 0..2; M3 starts empty.
    expect(provider.slotValues(3), isNull,
        reason: 'M3 storage seeded null before the test edit');

    // Edit M3 → write storage + read back to refresh cache.
    await provider.saveSlotValues(3, 7.50, 0.750, 8.0, 0.900);

    final cached = provider.slotValues(3);
    expect(cached, isNotNull);
    expect(cached!.length, 4);
    expect(cached[0], closeTo(7.50, 1e-3), reason: 'vSet cached');
    expect(cached[1], closeTo(0.750, 1e-3), reason: 'iSet cached');
    expect(cached[2], closeTo(8.0, 1e-3), reason: 'ovp cached');
    expect(cached[3], closeTo(0.900, 1e-3), reason: 'ocp cached');
  });

  test('saveSlotValues overwrites a previously-seeded slot', () async {
    // M1 was seeded with (12.00, 3.00, 13.0, 4.0).  refreshAllSlots
    // syncs the provider's _slots cache from the mock so the
    // pre-edit assertion below resolves.
    await provider.refreshAllSlots();
    expect(provider.slotValues(1), [12.00, 3.00, 13.0, 4.0]);

    await provider.saveSlotValues(1, 24.00, 5.00, 25.0, 5.5);

    expect(provider.slotValues(1), [24.00, 5.000, 25.0, 5.500]);
  });

  test('saveSlotValues fires notifyListeners after the read-back refresh',
      () async {
    final notifications = <int>[];
    provider.addListener(() => notifications.add(notifications.length));

    // Four listener notifications expected:
    //   1) pre-write service.saveMemorySlot emits nothing on the
    //      provider itself, but `_loadOneSlot`'s notifyListeners()
    //      fires at least once after the read-back populates the
    //      cache.  We require at least one.
    await provider.saveSlotValues(2, 21.0, 0.55, 22.0, 0.60);

    expect(notifications.length, greaterThanOrEqualTo(1),
        reason: 'saveSlotValues must notify so the preset dialog '
            'rebuilds with the new cached values');
  });

  test('saveSlotValues on out-of-range indices is a silent no-op',
      () async {
    final notifications = <int>[];
    provider.addListener(() => notifications.add(notifications.length));

    // Negative and >9 indices are guarded.  Neither the service call
    // nor the notify path should run.
    await provider.saveSlotValues(-1, 1.0, 1.0, 1.0, 1.0);
    await provider.saveSlotValues(10, 1.0, 1.0, 1.0, 1.0);

    expect(notifications.length, 0,
        reason: 'out-of-range index must short-circuit before '
            'the service write or notify');
    // Cache untouched.
    expect(provider.slotValues(-1), isNull);
    expect(provider.slotValues(10), isNull);
  });

  test('saveSlotValues is a storage-only edit — live Vset/Iset untouched',
      () async {
    // Seed the live _data with a clearly distinguishable value via
    // quickSwitch(1) — provider's quickSwitch copies the device's
    // post-switch HR8/HR9 read into _data.setVoltage/setCurrent.
    await provider.quickSwitch(1);
    final liveVBefore = provider.data.setVoltage;
    final liveIBefore = provider.data.setCurrent;
    expect(liveVBefore, greaterThan(0),
        reason: 'sanity — quickSwitch(1) populated live setVoltage');

    // Edit M2 storage (not the active slot).  Live Vset/Iset must
    // be unchanged because saveMemorySlot writes HR[80 + 2*4 + 0..3]
    // (= HR88..HR91), not HR8/HR9.
    await provider.saveSlotValues(2, 30.00, 6.0, 31.0, 6.2);

    expect(provider.data.setVoltage, liveVBefore,
        reason: 'storage edit on an inactive slot must NOT touch '
            'live active Vset (HR8)');
    expect(provider.data.setCurrent, liveIBefore,
        reason: 'storage edit on an inactive slot must NOT touch '
            'live active Iset (HR9)');
  });

  test('saveSlotValues can edit M0 even though UI hides it from the dialog',
      () async {
    // The UI preset dialog only shows M1..M9 (Phase B.1 / M0-read-only
    // rule), but the provider method must still accept index 0 as a
    // ranged-valid input so future surfaces (e.g. RegisterPage raw
    // writes) can use it.  This test guards the lower bound.
    await provider.refreshAllSlots();
    final before = provider.slotValues(0);
    expect(before, [5.00, 1.000, 6.0, 2.000],
        reason: 'M0 seeded in setUp');

    await provider.saveSlotValues(0, 3.30, 0.330, 3.5, 0.350);

    expect(provider.slotValues(0), [3.30, 0.330, 3.5, 0.350]);
  });

  test('saveSlotValues propagates service failures (no silent swallow)',
      () async {
    // Inject a service that throws on saveMemorySlot to verify the
    // provider re-raises instead of swallowing.  We do NOT subclass
    // MockModbusService because its concrete behaviour has no
    // connect-state guard; instead, we wrap one and delegate only
    // read paths so the pre-edit read-back in [_loadOneSlot] (and
    // active/SLOT-sync) still works.
    final throwing = _ThrowingSaveMock(svc);
    final p = PowerSupplyProvider(throwing);
    await p.connect();

    expect(
      p.saveSlotValues(2, 21.0, 0.5, 22.0, 0.6),
      throwsA(isA<Object>()),
      reason: 'saveSlotValues must rethrow service failures so the '
          'UI SnackBar / error path can surface them — silent '
          'swallow would leave the UI in a stale-but-no-error state',
    );

    await p.disconnect();
  });
}

/// Test double that delegates reads / connect / disconnect / slot
/// enumeration to a wrapped [MockModbusService], but throws on
/// [saveMemorySlot] to simulate a device-side write failure
/// (e.g. framing error / timeout) during an EDIT.
class _ThrowingSaveMock implements ModbusService {
  final MockModbusService _inner;
  _ThrowingSaveMock(this._inner);

  @override
  Future<void> saveMemorySlot(
      int slotIndex, double vSet, double iSet, double ovp, double ocp) {
    throw StateError('test: simulated device write failure');
  }

  // ── Delegate everything else ──────────────────────────────────
  @override
  Stream<PowerSupplyData> get dataStream => _inner.dataStream;
  @override
  bool get isConnected => _inner.isConnected;
  @override
  String? get currentPort => _inner.currentPort;
  @override
  Future<void> connect({String? port, int baudRate = 115200, int address = 1}) =>
      _inner.connect(port: port, baudRate: baudRate, address: address);
  @override
  Future<List<String>> listPorts() => _inner.listPorts();
  @override
  Future<SerialPortScanResult> scanCh340() => _inner.scanCh340();
  @override
  Future<void> disconnect() => _inner.disconnect();
  @override
  Future<void> writeRegister(int address, int value) =>
      _inner.writeRegister(address, value);
  @override
  Future<void> setVoltage(double volts) => _inner.setVoltage(volts);
  @override
  Future<void> setCurrent(double amps) => _inner.setCurrent(amps);
  @override
  Future<void> setOutput(bool enable) => _inner.setOutput(enable);
  @override
  Future<void> quickSwitch(int slotIndex) => _inner.quickSwitch(slotIndex);
  @override
  @Deprecated('Use quickSwitch(slotIndex) instead — Phase B verified '
      'HR[19] as the device-side quick-switch entry point')
  Future<void> loadMemorySlot(int slotIndex) => _inner.loadMemorySlot(slotIndex);
  @override
  Future<List<int>?> readMemorySlot(int slotIndex) =>
      _inner.readMemorySlot(slotIndex);
  @override
  Future<List<MemorySlot>> readAllMemorySlots() =>
      _inner.readAllMemorySlots();
  @override
  Future<void> setOVP(double volts) => _inner.setOVP(volts);
  @override
  Future<void> setOCP(double amps) => _inner.setOCP(amps);
  @override
  Future<PowerSupplyData?> readAllRegisters() => _inner.readAllRegisters();
  @override
  Future<List<int>?> readRawRegisters({String? dedup, int? expireMs}) =>
      _inner.readRawRegisters(dedup: dedup, expireMs: expireMs);
  @override
  void pauseTieredPolling() => _inner.pauseTieredPolling();
  @override
  void resumeTieredPolling() => _inner.resumeTieredPolling();
  @override
  void incNotify() => _inner.incNotify();
}
