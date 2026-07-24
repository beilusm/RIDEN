import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/models/power_snapshot.dart';
import 'package:riden_power_supply/services/snapshot_store.dart';

/// Phase E — unit tests for [SnapshotStore].
///
/// SnapshotStore is a single-isolate, in-memory cache of the latest
/// [PowerSnapshot] published from the provider's `_onData` callback.
/// Strict contract (per the Phase E design doc):
///
///   * No Modbus reads / no Timer / no Scheduler interaction.
///   * [update] overwrites — no dedup is attempted (throttling is the
///     DataLogger layer's responsibility).
///   * [latest] returns the cached reference directly — callers must
///     treat it as read-only.
///   * [clear] forgets the stored snapshot; safe to call on an empty
///     store.
///
/// All operations are synchronous; no `fakeAsync`, no real timer.
void main() {
  group('SnapshotStore — empty initial state', () {
    test('latest() returns null before any update', () {
      expect(SnapshotStore().latest(), isNull);
    });

    test('clear() on an empty store is a no-op (no throw)', () {
      final s = SnapshotStore();
      s.clear();
      s.clear();
      expect(s.latest(), isNull);
    });
  });

  group('SnapshotStore.update', () {
    test('stores a snapshot retrievable via latest()', () {
      final s = SnapshotStore();
      final snap = _snap(slot: 0);
      s.update(snap);
      expect(identical(s.latest(), snap), isTrue,
          reason: 'latest() returns the cached reference directly per the '
              'read-only contract — callers must NOT mutate it');
    });

    test('a second update supersedes the first (no dedup attempted)', () {
      final s = SnapshotStore();
      final a = _snap(slot: 0, voltage: 5.0);
      final b = _snap(slot: 0, voltage: 12.0);
      s.update(a);
      s.update(b);
      expect(identical(s.latest(), b), isTrue);
      expect(s.latest()!.voltage, 12.0,
          reason: 'the latest update wins — store does not dedup, '
              'throttling is the DataLogger layer\'s responsibility');
    });

    test(
        'update with an equivalent snapshot still overwrites (no dedup)', () {
      final s = SnapshotStore();
      final a = _snap(slot: 0);
      final b = _snap(slot: 0); // equal field values, distinct instance
      s.update(a);
      s.update(b);
      expect(identical(s.latest(), b), isTrue,
          reason: 'no dedup — store keeps the last reference');
    });

    test('update transitions null → snapshot → null → snapshot (repeatable)',
        () {
      final s = SnapshotStore();
      expect(s.latest(), isNull);
      s.update(_snap(slot: 1));
      expect(s.latest()!.activeSlot, 1);
      s.clear();
      expect(s.latest(), isNull);
      s.update(_snap(slot: 2));
      expect(s.latest()!.activeSlot, 2);
    });
  });

  group('SnapshotStore.clear', () {
    test('clear() after update sets latest() to null', () {
      final s = SnapshotStore()..update(_snap(slot: 3));
      expect(s.latest(), isNotNull);
      s.clear();
      expect(s.latest(), isNull);
    });

    test('update() works again after clear()', () {
      final s = SnapshotStore()..update(_snap(slot: 4));
      s.clear();
      s.update(_snap(slot: 5));
      expect(s.latest()!.activeSlot, 5);
    });
  });
}

PowerSnapshot _snap({required int slot, double voltage = 12.0}) =>
    PowerSnapshot(
      timestamp: DateTime(2026, 7, 24, 20, 30, 1),
      voltage: voltage,
      current: 2.5,
      power: voltage * 2.5,
      inputVoltage: 24.0,
      temperature: 35.0,
      outputEnable: true,
      protectionState: 0,
      activeSlot: slot,
    );
