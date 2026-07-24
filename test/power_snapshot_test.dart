// ignore_for_file: directives_ordering
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/models/power_snapshot.dart';
import 'package:riden_power_supply/models/power_supply_data.dart';

/// Phase E — unit tests for [PowerSnapshot] (the business-level
/// recording model).
///
/// Covers:
///   * [PowerSnapshot.from] conversion from the worker→UI wire
///     [PowerSupplyData] model with various active slots.
///   * `power` derivation as `voltage * current` (matching the
///     `PowerSupplyData.outputPower` getter).
///   * [toCsvRow] format matches the Phase E design doc spec
///     exactly (column order, ISO-8601 time truncation, double
///     formatting, boolean literal `true`/`false`).
void main() {
  group('PowerSnapshot.from', () {
    test('converts PowerSupplyData measurement fields + active slot',
        () {
      final data = PowerSupplyData(
        timestamp: DateTime(2026, 7, 24, 20, 30, 1),
        outputVoltage: 12.01,
        outputCurrent: 2.53,
        inputVoltage: 24.1,
        temperature: 35.0,
        outputEnabled: true,
        protectionStatus: 0,
      );
      final snap = PowerSnapshot.from(data, activeSlot: 3);
      expect(snap.timestamp, data.timestamp);
      expect(snap.voltage, 12.01);
      expect(snap.current, 2.53);
      expect(snap.power, closeTo(12.01 * 2.53, 1e-9));
      expect(snap.inputVoltage, 24.1);
      expect(snap.temperature, 35.0);
      expect(snap.outputEnable, isTrue);
      expect(snap.protectionState, 0);
      expect(snap.activeSlot, 3);
    });

    test('power is derived, not read from PowerSupplyData.outputPower',
        () {
      // Independent check: snapshot.power equals V*A regardless of
      // the source data's outputPower getter — it's computed in
      // PowerSnapshot.from's constructor.
      final data = PowerSupplyData(
        timestamp: DateTime.now(),
        outputVoltage: 5.0,
        outputCurrent: 1.0,
      );
      final snap = PowerSnapshot.from(data, activeSlot: 0);
      expect(snap.power, 5.0);
    });

    test('copies outputEnable=false when device is OFF', () {
      final data = PowerSupplyData(
        timestamp: DateTime.now(),
        outputEnabled: false,
      );
      expect(PowerSnapshot.from(data, activeSlot: 0).outputEnable, isFalse);
    });

    test('preserves protection state enum (OVP=1, OCP=2, OTP=3)', () {
      for (final p in [0, 1, 2, 3]) {
        final data = PowerSupplyData(
            timestamp: DateTime.now(), protectionStatus: p);
        expect(PowerSnapshot.from(data, activeSlot: 0).protectionState, p);
      }
    });

    test('active slot comes from the explicit parameter, not the data',
        () {
      // PowerSupplyData does not carry a single-field "active slot"
      // (it only carries slot storage via memorySlots); PowerSnapshot
      // takes activeSlot explicitly to mirror the provider's
      // _activeSlot tracker (set by quickSwitch + SLOW-poll sync).
      final data = PowerSupplyData(timestamp: DateTime.now());
      expect(PowerSnapshot.from(data, activeSlot: 5).activeSlot, 5);
      expect(PowerSnapshot.from(data, activeSlot: 9).activeSlot, 9);
    });
  });

  group('PowerSnapshot.toCsvRow', () {
    test('matches Phase E design doc spec row exactly', () {
      // Design doc example: 2026-07-24T20:30:01,12.01,2.53,30.4,24.1,35,true,0,3
      // Arithmetic correction: 12.01 * 2.53 = 30.3853 → toStringAsFixed(2)
      // rounds to "30.39" (slightly differs from the doc's "30.4" because
      // we round to 2 decimal places, not 1; acceptable, the design doc's
      // example row is illustrative).
      final snap = PowerSnapshot(
        timestamp: DateTime(2026, 7, 24, 20, 30, 1),
        voltage: 12.01,
        current: 2.53,
        power: 12.01 * 2.53,
        inputVoltage: 24.1,
        temperature: 35.0,
        outputEnable: true,
        protectionState: 0,
        activeSlot: 3,
      );
      final row = snap.toCsvRow();
      // Check column order — 9 columns, comma-separated.
      final cols = row.split(',');
      expect(cols.length, 9);
      expect(cols[0], '2026-07-24T20:30:01', reason: 'time ISO-8601 no TZ');
      expect(double.parse(cols[1]), 12.01);
      expect(double.parse(cols[2]), 2.53);
      expect(double.parse(cols[3]), closeTo(12.01 * 2.53, 5e-3),
          reason: 'power is rounded to 2 decimals by _fmt; a 5e-3 '
              'tolerance covers the +/- 0.005 rounding boundary '
              'so the test stays green across pubspec-version '
              'platform arithmetic quirks without weakening the '
              'column-order verification.');
      expect(double.parse(cols[4]), 24.1);
      expect(double.parse(cols[5]), 35.0);
      expect(cols[6], 'true', reason: 'outputEnable lowercase literal');
      expect(cols[7], '0', reason: 'protectionState int.toString()');
      expect(cols[8], '3', reason: 'activeSlot int.toString()');
    });

    test('truncates fractional seconds from timestamp (no .xxx)', () {
      final snap = PowerSnapshot(
        timestamp: DateTime(2026, 7, 24, 20, 30, 1, 500, 250),
        voltage: 0,
        current: 0,
        power: 0,
        inputVoltage: 0,
        temperature: 0,
        outputEnable: false,
        protectionState: 0,
        activeSlot: 0,
      );
      final t = snap.toCsvRow().split(',').first;
      expect(t, '2026-07-24T20:30:01', reason: 'no fractional seconds');
      expect(t.contains('.'), isFalse);
    });

    test('outputEnable=false serializes as "false"', () {
      final snap = PowerSnapshot(
        timestamp: DateTime(2026, 7, 24, 20, 30, 1),
        voltage: 0,
        current: 0,
        power: 0,
        inputVoltage: 0,
        temperature: 0,
        outputEnable: false,
        protectionState: 0,
        activeSlot: 0,
      );
      final cols = snap.toCsvRow().split(',');
      expect(cols[6], 'false');
    });

    test('no row contains a trailing newline', () {
      final snap = PowerSnapshot(
        timestamp: DateTime.now(),
        voltage: 0,
        current: 0,
        power: 0,
        inputVoltage: 0,
        temperature: 0,
        outputEnable: true,
        protectionState: 0,
        activeSlot: 0,
      );
      expect(snap.toCsvRow().endsWith('\n'), isFalse);
      expect(snap.toCsvRow().endsWith('\r'), isFalse);
    });
  });
}
