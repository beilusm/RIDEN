// ignore_for_file: deprecated_member_use_from_same_package
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';
import 'package:riden_power_supply/providers/power_supply_provider.dart';

/// Phase B.1 — stability fixes for quickSwitch + slot-load audit:
///
/// 1) quickSwitch now refreshes OVP/OCP (HR82/HR83) along with
///    Vset/Iset and the rest of the active registers.  Previously
///    the UI's PROTECTION panel stayed stale until the next FAST
///    poll (~150ms worst-case).
///
/// 2) quickSwitch logs [QSW] before/after lines with HR19/HR8/HR9/
///    HR82/HR83 so M0↔M1/M2 bidirectional switches can be diffed
///    in the console — verification that the device-side HR19 write
///    actually loaded the expected preset.
///
/// 3) Slot menu load (`refreshAllSlots`) was previously 10 sequential
///    `readMemorySlot(i)` calls (~250ms each, ~2.5s worst-case total).
///    Phase B.1 collapses to one bulk `readAllMemorySlots()` call
///    (HR[80..119], 40 registers, one RTU round-trip, ~250ms total).
void main() {
  late MockModbusService svc;
  late PowerSupplyProvider provider;

  setUp(() async {
    svc = MockModbusService();
    provider = PowerSupplyProvider(svc);
    await svc.connect();
    // Distinguishing presets so the slot-load assertions are
    // unambiguous: each slot has a unique Vset × 100 raw value.
    await svc.saveMemorySlot(0, 5.00, 1.00, 6.0, 2.0);
    await svc.saveMemorySlot(1, 12.00, 3.00, 13.0, 4.0);
    await svc.saveMemorySlot(2, 19.50, 0.50, 20.0, 0.5);
    await svc.saveMemorySlot(3, 1.00, 0.10, 2.0, 0.05);
  });

  tearDown(() async {
    await svc.disconnect();
  });

  // ── Task 1: OVP/OCP refresh after quickSwitch ─────────────────────

  test('quickSwitch refreshes ovp/ocp from the post-switch device read',
      () async {
    // Phase B.1 (revised after hardware regression + user
    // clarification): OVP/OCP are PER-SLOT.  The active slot's OVP/OCP
    // live at HR[80+slot*4+2 / 80+slot*4+3], NOT at HR82/HR83 (which is
    // M0's own storage).  setUp saved M1 with OVP=13.0V / OCP=4.0A
    // at HR[84..87].  After quickSwitch(1), the provider must read
    // from M1's storage address (HR86/87), not from HR82/83 (which
    // would always show M0's OVP).
    expect(provider.data.ovp, 62.0,
        reason: 'PowerSupplyData default ovp (no switch yet)');
    expect(provider.data.ocp, 6.2,
        reason: 'PowerSupplyData default ocp (no switch yet)');

    await provider.quickSwitch(1);

    // M1 stored OVP/OCP from setUp = 13.0V / 4.0A (at HR86/87).
    expect(provider.data.ovp, 13.0,
        reason: 'ovp refreshed from M1 storage HR86 = 13.0V');
    expect(provider.data.ocp, 4.0,
        reason: 'ocp refreshed from M1 storage HR87 = 4.0A');
  });

  test('quickSwitch does not regress previously-refreshed fields', () async {
    // Sanity: pre-existing fields (setVoltage/setCurrent/keyLock/
    // protectionStatus/isConstantCurrent/outputEnabled) should
    // still be populated after the Phase B.1 fix added ovp/ocp.
    await provider.quickSwitch(2);
    expect(provider.data.setVoltage, greaterThan(0));
    expect(provider.data.setCurrent, greaterThan(0));
    expect(provider.data.keyLock, isA<int>());
    expect(provider.data.protectionStatus, isA<int>());
    expect(provider.data.isConstantCurrent, isA<bool>());
    expect(provider.data.outputEnabled, isA<bool>());
  });

  // ── Task 3: bulk slot read replaces 10× sequential readCycle ─────

  test('readAllMemorySlots returns 10 MemorySlot objects in one call',
      () async {
    final slots = await svc.readAllMemorySlots();
    expect(slots.length, 10, reason: 'mock has all 10 slots populated');
    // Spot-check: M1 must carry the Vset we saved in setUp.
    final m1 = slots.firstWhere((s) => s.index == 1);
    expect(m1.vSet, 12.00);
    expect(m1.iSet, 3.00);
    expect(m1.ovp, 13.0);
    expect(m1.ocp, 4.0);
  });

  test('refreshAllSlots populates _slots map via single bulk read', () async {
    // Before: provider's _slots map is empty (no refresh called yet).
    expect(provider.slotValues(0), isNull);
    expect(provider.slotValues(1), isNull);

    await provider.refreshAllSlots();

    // After: all 10 slots are populated by the bulk read.
    for (int i = 0; i < 10; i++) {
      expect(provider.slotValues(i), isNotNull,
          reason: 'slot $i must be populated by bulk read');
    }
    // Spot-check the setUp-saved slot values.
    expect(provider.slotValues(1), [12.00, 3.00, 13.0, 4.0]);
    expect(provider.slotValues(2), [19.50, 0.50, 20.0, 0.5]);
    // Mark loaded so listeners are not re-triggered by the bg refresh.
    expect(provider.slotValues(3), [1.00, 0.10, 2.0, 0.05]);
  });

  test('refreshAllSlots is idempotent on repeat calls', () async {
    await provider.refreshAllSlots();
    final first = provider.slotValues(0);
    await provider.refreshAllSlots();
    final second = provider.slotValues(0);
    expect(second, equals(first),
        reason: 'repeat bulk read must return the same slot values');
  });
}
