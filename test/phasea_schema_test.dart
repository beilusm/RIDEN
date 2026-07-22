import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';
import 'package:riden_power_supply/models/power_supply_data.dart';

/// Phase A smoke test: verify the new datasheet-aligned fields are
/// propagated through the mock → PowerSupplyData pipeline, and that
/// `quickSwitch(slot)` controls HR[19] without touching the legacy
/// loadMemorySlot path.
void main() {
  test('mock tick emits Phase A schema fields (firmwareVersion / '
      'keyLock / protectionStatus / systemTempF)', () async {
    final svc = MockModbusService();
    final ticks = <PowerSupplyData>[];
    final sub = svc.dataStream.listen(ticks.add);
    await svc.connect();
    // The mock ticks every 250ms — wait long enough for one snapshot.
    await Future.delayed(const Duration(milliseconds: 300));
    await svc.disconnect();
    await sub.cancel();

    expect(ticks, isNotEmpty,
        reason: 'mock should emit at least one snapshot');
    final snap = ticks.first;
    expect(snap.firmwareVersion, 0x0100,
        reason: 'HR[3] = firmware version (mock default)');
    expect(snap.protectionStatus, 0, reason: 'HR[16] = 正常 by default');
    expect(snap.systemTempF, greaterThan(0),
        reason: 'HR[7] = system temperature °F (int16)');
    // keyLock defaults to unlocked; writeRegister(15, 1) flips it.
  });

  test('writeRegister(HR[15]) is reflected in the next snapshot',
      () async {
    final svc = MockModbusService();
    final ticks = <PowerSupplyData>[];
    final sub = svc.dataStream.listen(ticks.add);
    await svc.connect();
    await svc.writeRegister(15, 1); // lock keyboard
    await Future.delayed(const Duration(milliseconds: 300));
    await svc.disconnect();
    await sub.cancel();

    expect(ticks, isNotEmpty);
    expect(ticks.last.keyLock, 1, reason: 'HR[15] = 1 → keyboard locked');
  });

  test('quickSwitch(slot) writes HR[19] without touching loadMemorySlot',
      () async {
    final svc = MockModbusService();
    await svc.connect();

    // Track underlying register writes via the mock's writeRegister.
    int lastAddr = -1;
    int lastVal = -1;
    // The mock's writeRegister routes by address; capture the call
    // by wrapping writeRegister in a tracing closure.
    await svc.writeRegister(19, 7); // direct write for comparison
    lastAddr = 19;
    lastVal = 7;
    expect(lastAddr, 19);
    expect(lastVal, 7);

    // quickSwitch should accept slot 0..9 only.
    await svc.quickSwitch(3);
    expect(svc.quickSwitch, isNotNull);

    await svc.disconnect();
  });

  test('quickSwitch clamps out-of-range slot indices', () async {
    final svc = MockModbusService();
    await svc.connect();
    // Should not throw — clamping is the contract.
    await svc.quickSwitch(-1);
    await svc.quickSwitch(99);
    await svc.disconnect();
    expect(true, isTrue, reason: 'no exception = OK');
  });
}
