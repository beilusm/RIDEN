// ignore_for_file: deprecated_member_use_from_same_package
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';
import 'package:riden_power_supply/providers/power_supply_provider.dart';

/// Phase B tests: verify the provider's new quickSwitch() path
/// replaces the legacy loadSlot() behaviour end-to-end against the
/// mock service.
void main() {
  late MockModbusService svc;
  late PowerSupplyProvider provider;

  setUp(() async {
    svc = MockModbusService();
    provider = PowerSupplyProvider(svc);
    await svc.connect();
    // Set up a clearly distinguishable pair of presets.
    await svc.saveMemorySlot(0, 5.00, 1.00, 6.0, 2.0);
    await svc.saveMemorySlot(1, 12.00, 3.00, 13.0, 4.0);
    await svc.saveMemorySlot(2, 19.50, 0.50, 20.0, 0.5);
  });

  tearDown(() async {
    await svc.disconnect();
  });

  test('quickSwitch(0) sets activeSlot=0 and emits notifyListeners',
      () async {
    final notifications = <int>[];
    provider.addListener(() => notifications.add(notifications.length));

    await provider.quickSwitch(0);

    expect(provider.activeSlot, 0);
    // quickSwitch notifies at least twice: once on activeSlot set,
    // once after the read refresh.
    expect(notifications.length, greaterThanOrEqualTo(2));
  });

  test('quickSwitch(target) refreshes data from device read', () async {
    // The provider's initial _data.setVoltage is 0 (default).  After
    // quickSwitch, the provider's read-refresh should populate
    // setVoltage from the mock's readRawRegisters (which mirrors the
    // mock's current _vSet = 4.20 V).  This proves the refresh path
    // pulls from the device read, not a software-optimistic clone.
    expect(provider.data.setVoltage, 0,
        reason: 'provider initial setVoltage is default 0');
    await provider.quickSwitch(1);
    expect(provider.data.setVoltage, 4.20,
        reason: 'after quickSwitch, setVoltage comes from mock '
            'readRawRegisters (mirror of _vSet = 4.20)');
    expect(provider.data.outputEnabled, isA<bool>());
  });

  test('quickSwitch clamps out-of-range and is a no-op', () async {
    final initial = provider.activeSlot;
    await provider.quickSwitch(-1);
    expect(provider.activeSlot, initial,
        reason: 'negative index must be ignored');
    await provider.quickSwitch(99);
    expect(provider.activeSlot, initial,
        reason: 'index > 9 must be ignored');
  });

  test('quickSwitch reads keyLock / protectionStatus after switch',
      () async {
    await provider.quickSwitch(2);
    // readRawRegisters mock returns keyLock=0, protectionStatus=0.
    expect(provider.data.keyLock, 0);
    expect(provider.data.protectionStatus, 0);
  });

  test('legacy loadSlot still works (deprecated, not removed)', () async {
    // Calling the deprecated method should not throw.  This guards
    // against accidental removal during the Phase B transition.
    await provider.loadSlot(2);
    expect(provider.activeSlot, 2);
  });

  test('quickSwitch exposes new data fields (firmwareVersion, etc.)',
      () async {
    await provider.quickSwitch(0);
    expect(provider.data.firmwareVersion, 0x0100);
    expect(provider.data.systemTempF, greaterThan(0));
  });
}
