// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/services/modbus_worker.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';
import 'package:riden_power_supply/providers/power_supply_provider.dart';
import 'package:riden_power_supply/models/power_supply_data.dart';

/// P1-2 — SerialModbusService worker-lifecycle regression coverage.
///
/// Two independent layers are tested here.  Constraints:
///   - Real-hardware integration (MODBUS over /dev/ttyUSB*) is NOT
///     exercised — see `phaseb1_hw_regression.dart` for that pattern.
///   - The provider crash-propagation test goes through the public
///     [ModbusService.dataStream] surface so it stays isolated from
///     the Serial-modbus isolate plumbing.
///
/// What IS covered:
///   1. `ModbusWorkerHandle.isDead` getter (new in P1-2) returns false
///      on a freshly-spawned handle and true after `forceKill()`.
///      This is the signal SerialModbusService relies on to skip the
///      slow `await w.shutdown().timeout(5s)` round-trip when the
///      worker has already died, and to recognise a zombie handle
///      during `connect()` before a fresh spawn.
///
///   2. `PowerSupplyProvider._onData` flips `_connected = false`,
///      upgrades the cached `_data.commStatus` to `CommStatus.error`,
///      and notifies listeners when the service emits a snapshot with
///      `CommStatus.error` (the worker-crash signal).  This is what
///      SerialModbusService._handleWorkerError produces when the
///      underlying isolate dies — the mock's `simulateCrash()`
///      mirrors that exact snapshot.
void main() {
  // ── Layer 1: ModbusWorkerHandle.isDead lifecycle ──────────────────

  group('ModbusWorkerHandle.isDead', () {
    test('is false immediately after spawn', () async {
      final handle = await ModbusWorkerHandle.spawn();
      expect(handle.isDead, isFalse,
          reason: 'freshly-spawned handle must report isDead==false so '
              'SerialModbusService.connect() does not classify it as a '
              'zombie on the first reconnect attempt');
      handle.forceKill();
    });

    test('is true after forceKill', () async {
      final handle = await ModbusWorkerHandle.spawn();
      handle.forceKill();
      expect(handle.isDead, isTrue,
          reason: 'forceKill sets _dead=true synchronously; the isDead '
              'getter must reflect that so SerialModbusService.disconnect '
              'can short-circuit the slow shutdown round-trip');
    });

    test('is true after shutdown completes', () async {
      final handle = await ModbusWorkerHandle.spawn();
      // shutdown() sends a clean-shutdown message then triggers
      // _cleanup(), which closes the uiPort and kills the isolate.
      // After it returns, the handle is considered dead — the spawn-
      // path guard (`if (_worker != null && _worker!.isDead)`) and
      // disconnect()'s fast-path both rely on this.
      await handle.shutdown();
      expect(handle.isDead, isTrue,
          reason: 'shutdown() runs _cleanup() which sets _dead=true '
              'via Isolate.kill triggering the onExit message — but '
              'even without that, _cleanup() guarantees _dead=true '
              'by the time shutdown() returns');
    });
  });

  // ── Layer 2: PowerSupplyProvider worker-crash propagation ────────

  group('PowerSupplyProvider worker-crash propagation (P1-2)', () {
    late MockModbusService svc;
    late PowerSupplyProvider provider;
    final notifications = <int>[];

    setUp(() async {
      svc = MockModbusService();
      provider = PowerSupplyProvider(svc);
      provider.addListener(() => notifications.add(notifications.length));
      await svc.connect();
      await provider.connect();
    });

    tearDown(() async {
      await provider.disconnect();
      await svc.disconnect();
    });

    test('provider starts connected with commStatus online', () {
      expect(provider.connected, isTrue);
      expect(provider.data.commStatus, CommStatus.online);
    });

    test('simulateCrash flips _connected=false and upgrades to error',
        () async {
      // Preconditions: provider has had at least one successful poll
      // so _lastPollOk is fresh (would otherwise mask the crash).
      expect(provider.connected, isTrue);

      // Snapshot length before the crash signal — used to assert that
      // the crash path does NOT append a chart point (a crash isn't
      // a measurement, it's a status transition).
      final chartLengthBefore = provider.chartData.length;

      // Emit the worker-crash snapshot (mirrors
      // SerialModbusService._handleWorkerError's _dataController.add
      // with commStatus: error).
      svc.simulateCrash();

      // Let the listener fire on the microtask queue.
      await Future<void>.delayed(Duration.zero);

      expect(provider.connected, isFalse,
          reason: 'worker-crash snapshot must flip _connected=false so '
              'the UI reconnect button lights up');
      expect(provider.data.commStatus, CommStatus.error,
          reason: 'provider upgrades the snapshot offline→error per '
              'P1-2 (CLAUDE.md P1-2 guidance)');
      expect(notifications, isNotEmpty,
          reason: 'provider.notifyListeners must fire so the UI '
              're-renders the error state');
      expect(provider.chartData.length, lessThanOrEqualTo(chartLengthBefore),
          reason: 'crash snapshot must NOT append a chart point — '
              'a failure is a status, not a measurement');
    });

    test('simulateCrash is idempotent on repeat emissions', () async {
      svc.simulateCrash();
      await Future<void>.delayed(Duration.zero);
      // First crash: flips _connected, notifies once.
      final firstConnected = provider.connected;
      final firstCommStatus = provider.data.commStatus;
      final notificationsAfterFirst = notifications.length;

      // Second crash: wasConnected is now false, so the early-return
      // branch inside _onData must short-circuit — no second notify,
      // no re-flip of the same flags.
      svc.simulateCrash();
      await Future<void>.delayed(Duration.zero);

      expect(firstConnected, isFalse);
      expect(firstCommStatus, CommStatus.error);
      expect(provider.connected, isFalse,
          reason: 'second crash must not re-flip already-false state');
      expect(provider.data.commStatus, CommStatus.error);
      // notifications should not have advanced (wasConnected=false
      // short-circuits the body).
      expect(notifications.length, notificationsAfterFirst,
          reason: 'second crash with wasConnected=false must NOT '
              'call notifyListeners — the wasConnected guard is the '
              'P1-2 idempotency contract');
    });

    test('normal poll snapshot does not trigger crash handling', () async {
      // Re-issue MockModbusService's _tick by waiting one of its
      // 250ms cycles — the resulting snapshot has commStatus.online
      // (default PowerSupplyData), so it must take the normal path:
      // _connected stays true, commStatus stays online.
      final notificationsBefore = notifications.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(provider.connected, isTrue,
          reason: 'normal poll snapshot must not flip _connected');
      expect(provider.data.commStatus, isNot(CommStatus.error),
          reason: 'normal poll must not upgrade to CommStatus.error');
      expect(notifications.length, greaterThan(notificationsBefore),
          reason: 'normal poll should fire at least one notify');
    });
  });
}
