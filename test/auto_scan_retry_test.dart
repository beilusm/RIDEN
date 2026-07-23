// ignore_for_file: avoid_print, deprecated_member_use_from_same_package
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/providers/power_supply_provider.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';

/// Auto-scan retry timer coverage for [PowerSupplyProvider].
///
/// Uses [fake_async] to fast-forward the 400ms periodic timer inside
/// the provider without real wall-clock delay.  A [ModbusService]
/// subclass [_ConnectCountingMock] wraps [MockModbusService] to
/// observe the connect-call count — the only externally-visible
/// signal that the timer fired.  Two flavours are used:
///   * [_AlwaysFailMock] — every `connect()` throws, exercising the
///     retry loop (timer stays armed, ticks keep arriving).
///   * [_AlwaysSucceedMock] — `connect()` succeeds on first call,
///     exercising the "connected state skips ticks" path.
void main() {
  group('PowerSupplyProvider auto-scan retry timer', () {
    test('isAutoScanning reflects the timer arma state', () {
      fakeAsync((async) {
        final svc = _AlwaysSucceedMock();
        final provider = PowerSupplyProvider(svc);

        expect(provider.isAutoScanning, isFalse,
            reason: 'no timer before startAutoScan');
        provider.startAutoScan();
        expect(provider.isAutoScanning, isTrue,
            reason: 'timer armed immediately by startAutoScan');

        // First tick fires synchronously — connect call must be
        // observed after flushing microtasks.
        async.flushMicrotasks();
        expect(svc.connectCount, greaterThanOrEqualTo(1));

        provider.stopAutoScan();
        expect(provider.isAutoScanning, isFalse,
            reason: 'stopAutoScan nullifies the timer');
      });
    });

    test('startAutoScan fires the first connect tick immediately', () {
      fakeAsync((async) {
        final svc = _AlwaysSucceedMock();
        final provider = PowerSupplyProvider(svc);

        provider.startAutoScan();
        // Sync section of startAutoScan has invoked _autoScanTick,
        // which called connect() — but the resulting future chain
        // (await _service.connect → _connected = true) is still
        // pending.  Flush the microtasks before asserting connected.
        async.flushMicrotasks();

        expect(svc.connectCount, 1,
            reason: 'first tick fires synchronously from startAutoScan '
                'so the user sees a connect attempt without waiting '
                '400ms on app boot');
        expect(provider.connected, isTrue,
            reason: 'mock connect succeeds → provider enters connected');
      });
    });

    test('connected state keeps timer armed but skips ticks', () {
      fakeAsync((async) {
        final svc = _AlwaysSucceedMock();
        final provider = PowerSupplyProvider(svc);

        provider.startAutoScan();
        async.flushMicrotasks();
        expect(provider.connected, isTrue);
        expect(svc.connectCount, 1);

        // Advance past many 400ms cycles — `_connected || _connecting`
        // guard must short-circuit every tick so connect() is NOT
        // called again.  Timer remains armed so worker crash can
        // relight it (see test below).
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(svc.connectCount, 1,
            reason: 'connected state skips every subsequent tick — '
                'connect() must not be re-invoked when already '
                'connected');
        expect(provider.isAutoScanning, isTrue,
            reason: 'timer stays armed in the connected state so the '
                'P1-2 worker-crash recovery path can relight connect '
                'when _connected flips false');
      });
    });

    test('autoScan retries every 400ms while connect keeps failing', () {
      fakeAsync((async) {
        final svc = _AlwaysFailMock();
        final provider = PowerSupplyProvider(svc);

        provider.startAutoScan();
        async.flushMicrotasks();
        expect(svc.connectCount, 1, reason: 'first tick synchronous');

        async.elapse(const Duration(milliseconds: 400));
        async.flushMicrotasks();
        expect(svc.connectCount, 2, reason: 'first periodic tick at 400ms');

        async.elapse(const Duration(milliseconds: 400));
        async.flushMicrotasks();
        expect(svc.connectCount, 3, reason: 'second periodic tick at 800ms');

        // Fast-forward a longer interval to assert linearity.
        async.elapse(const Duration(milliseconds: 1600));
        async.flushMicrotasks();
        expect(svc.connectCount, 7,
            reason: '4 more ticks (at 1200/1600/2000/2400ms) → 7 total');

        expect(provider.connected, isFalse,
            reason: 'failing connect must keep _connected == false so '
                'the tick guard does NOT short-circuit');
        expect(provider.isAutoScanning, isTrue,
            reason: 'timer stays armed across failure storms so the '
                'app recovers the moment a CH340 is plugged in');
      });
    });

    test('disconnect stops the auto-scan timer', () {
      fakeAsync((async) {
        // Use the failing mock so _connected stays false — that way
        // the only thing stopping further ticks is the explicit
        // stopAutoScan() inside disconnect().
        final svc = _AlwaysFailMock();
        final provider = PowerSupplyProvider(svc);

        provider.startAutoScan();
        async.flushMicrotasks();
        expect(svc.connectCount, 1);
        expect(provider.isAutoScanning, isTrue);

        provider.disconnect();
        expect(provider.isAutoScanning, isFalse,
            reason: 'disconnect must nullify the auto-scan timer so '
                'the user\'s explicit DISCONNECT is honoured — '
                'otherwise the next ~400ms tick would re-fire '
                'connect() and undo the disconnect');

        // Advance time well past several 400ms cycles — no further
        // connect call must be observed.
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(svc.connectCount, 1,
            reason: 'after stopAutoScan, the timer is cancelled and '
                'no further ticks fire');
      });
    });

    test('worker crash relights connect via the still-armed timer', () {
      fakeAsync((async) {
        final svc = _AlwaysSucceedMock();
        final provider = PowerSupplyProvider(svc);

        provider.startAutoScan();
        async.flushMicrotasks();
        expect(provider.connected, isTrue);
        expect(svc.connectCount, 1);
        expect(provider.isAutoScanning, isTrue,
            reason: 'timer stays armed while connected (ticked no-op)');

        // Simulate a worker crash (P1-2 _handleWorkerError path):
        // MockModbusService.simulateCrash emits a commStatus.error
        // snapshot that PowerSupplyProvider._onData treats as the
        // authoritative crash signal — flips _connected=false,
        // upgrades to CommStatus.error, cancels _sub.
        svc.simulateCrash();
        async.flushMicrotasks();
        expect(provider.connected, isFalse,
            reason: 'P1-2 crash flips _connected=false');
        expect(provider.isAutoScanning, isTrue,
            reason: 'the timer was NOT cancelled by the crash — '
                'disconnect() is the only thing that cancels it. '
                'Crash recovery relies on the next 400ms tick '
                'relighting connect().');

        // Advance past the next 400ms cycle — the timer should
        // call connect() and the mock succeed again.
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        expect(svc.connectCount, 2,
            reason: 'auto-scan relights connect after worker crash '
                'without user intervention — exact behaviour the user '
                'asked for ("sustained auto-retry while absent")');
        expect(provider.connected, isTrue,
            reason: 'relit connect succeeds → provider re-enters '
                'connected state');
      });
    });

    test('dispose cancels the timer (no leak)', () {
      fakeAsync((async) {
        final svc = _AlwaysSucceedMock();
        final provider = PowerSupplyProvider(svc);
        provider.startAutoScan();
        async.flushMicrotasks();
        expect(provider.isAutoScanning, isTrue);

        provider.dispose();
        expect(provider.isAutoScanning, isFalse,
            reason: 'dispose() must cancel the auto-scan timer to '
                'avoid leaking a periodic Timer after the provider '
                'instance is destroyed');
      });
    });

    test('startAutoScan is idempotent on repeat calls', () {
      fakeAsync((async) {
        final svc = _AlwaysSucceedMock();
        final provider = PowerSupplyProvider(svc);

        provider.startAutoScan();
        async.flushMicrotasks();
        expect(svc.connectCount, 1);

        // Second startAutoScan must be a no-op — calling it twice
        // never spawns a second timer (which would double the tick
        // rate to 200ms).
        provider.startAutoScan();
        async.flushMicrotasks();
        expect(svc.connectCount, 1,
            reason: 'second startAutoScan is a no-op because the '
                'timer is already armed — the `if (_autoScanTimer != '
                'null) return` guard prevents duplicate timers');
      });
    });
  });
}

/// Subclass of [MockModbusService] that counts `connect` calls and
/// always succeeds (mimics a CH340 plugged in and responding).  The
/// mock's `connect()` returns a synchronously-completed future per
/// the inherited async body — exactly one 250ms `Timer.periodic` for
/// `_tick` is spawned per successful call.  Subsequent invocations
/// route through the `if (isConnected) return` early-return so the
/// provider's auto-scan loop observes them but the mock doesn't
/// spawn a second timer.
class _AlwaysSucceedMock extends MockModbusService {
  int connectCount = 0;

  @override
  Future<void> connect({
    String? port,
    int baudRate = 115200,
    int address = 1,
  }) async {
    connectCount++;
    await super.connect(port: port, baudRate: baudRate, address: address);
  }
}

/// Subclass of [MockModbusService] that counts `connect` calls and
/// throws on every invocation — exercises the auto-scan retry loop
/// where the user hasn't plugged the CH340 in yet.  The provider's
/// `connect()` catch block debugPrints the cause and rethrows, which
/// the auto-scan tick's `catchError((_) {})` swallows so the periodic
/// timer keeps firing every 400ms.
class _AlwaysFailMock extends MockModbusService {
  int connectCount = 0;

  @override
  Future<void> connect({
    String? port,
    int baudRate = 115200,
    int address = 1,
  }) async {
    connectCount++;
    throw Exception('fake connect failure for auto-scan retry test');
  }
}
