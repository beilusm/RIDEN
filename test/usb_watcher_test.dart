// ignore_for_file: avoid_print
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/providers/power_supply_provider.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';
import 'package:riden_power_supply/services/serial_port_scanner.dart';

/// Phase D — USB watcher coverage for [PowerSupplyProvider].
///
/// Replaces the Phase C `auto_scan_retry_test.dart` (400ms blind
/// `connect` retry) with the 1s `scanCh340()` driven watcher that
/// keeps the device's serial port cold while the CH340 is absent —
/// the core user requirement "持续监控但不要压垮下位机的响应性能".
///
/// Uses [fake_async] so the 1s periodic timer advances without real
/// wall-clock delay.  [_UsbControllableMock] wraps [MockModbusService]
/// to drive the watcher state machine:
///   * `plugCh340()` / `unplugCh340()` — flip the mock's USB state
///     so the next `scanCh340()` call returns found / notFound.
///   * `connectCount` — externally-observable signal the watcher tick
///     invoked `connect()` (concatenated with `super.connect`).
void main() {
  group('PowerSupplyProvider USB watcher (Phase D)', () {
    test('isUsbWatching reflects the timer arma state', () {
      fakeAsync((async) {
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);

        expect(provider.isUsbWatching, isFalse,
            reason: 'no timer before startUsbWatch');
        provider.startUsbWatch();
        expect(provider.isUsbWatching, isTrue,
            reason: 'timer armed immediately by startUsbWatch');

        // First tick fires synchronously — scanCh340 future chain
        // resolves and connect() is invoked once microtasks flush.
        async.flushMicrotasks();
        expect(svc.connectCount, greaterThanOrEqualTo(1));

        provider.stopUsbWatch();
        expect(provider.isUsbWatching, isFalse,
            reason: 'stopUsbWatch nullifies the timer');
      });
    });

    test('first tick fires synchronously — connect observed without '
        'waiting 1s on app boot', () {
      fakeAsync((async) {
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        // Sync section of startUsbWatch has invoked _usbWatchTick,
        // which scheduled the scanCh340 future + then-callback.  The
        // resulting chain (await scanCh340 → connect → mock
        // await super.connect) is still pending.  Flush microtasks
        // before asserting connected.
        async.flushMicrotasks();

        expect(svc.connectCount, 1,
            reason: 'first tick fires synchronously from startUsbWatch '
                'so the user sees a connect attempt without waiting '
                '1s on app boot');
        expect(provider.connected, isTrue,
            reason: 'CH340 present + mock connect succeeds → provider '
                'enters connected state');
      });
    });

    test('auto-scan path surfaces resolved port name (Phase D fix)', () {
      fakeAsync((async) {
        // Regression for the user-reported bug "为什么 ui 没刷新当前
        // 选择的串口设备": the auto-scan path calls connect() with
        // port=null, so the provider's old `_connectedPort = port`
        // stored null.  The UI's serial panel then couldn't show
        // which port the device was actually on (it fell back to
        // the panel's own internal _port state, not the real
        // resolved CH340 port).  Fix: provider reads
        // `_service.currentPort` after connect succeeds — that
        // reflects the port the service's scanner actually picked.
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(provider.connected, isTrue);
        expect(provider.connectedPort, '/dev/ttyUSB0',
            reason: 'auto-scan path must surface the service\'s '
                'resolved port name so the UI serial panel shows '
                'the actual port the worker is talking through, '
                'not the caller\'s null input.  Regression for the '
                '"UI 不刷新当前选择的串口设备" bug.');
      });
    });

    test('connected state keeps timer armed but skips connect calls',
        () {
      fakeAsync((async) {
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(provider.connected, isTrue);
        expect(svc.connectCount, 1);

        // Advance past many 1s ticks — `_connected` guard must
        // short-circuit every tick so connect() is NOT called again
        // (CH340 still present → scanCh340 found → tick's `if
        // (_connected) return` after the found branch).  Timer
        // stays armed so the next unplugged CH340 will trigger a
        // watcher disconnect.
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(svc.connectCount, 1,
            reason: 'connected state skips every subsequent tick '
                'when CH340 is still present — connect() must not '
                'be re-invoked when already connected');
        expect(provider.isUsbWatching, isTrue,
            reason: 'timer stays armed in the connected state so the '
                'unplug path can still fire watcher disconnect');
      });
    });

    test('not connected + no CH340 → no connect call (device stays cold)',
        () {
      fakeAsync((async) {
        // Leave the mock in the default unplugCh340 state — the
        // user's core requirement: "持续监控但不要压垮下位机的响应
        // 性能".  The watcher keeps polling scanCh340() but never
        // invokes connect() (no worker spawn, no Modbus poll loop).
        final svc = _UsbControllableMock();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(svc.connectCount, 0,
            reason: 'CH340 absent → scanCh340 returns notFound → '
                'tick no-ops, connect() is NOT called.  The device '
                'serial port stays cold — no Modbus traffic, no '
                'worker spawn.');
        expect(provider.connected, isFalse);
        expect(provider.isUsbWatching, isTrue,
            reason: 'watcher stays armed while idle so the moment a '
                'CH340 is plugged in, the next tick connects');

        // Advance several 1s ticks — every tick should still no-op
        // (no CH340 discovered).  Let advance to confirm connect
        // stays at 0 across ticks.
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(svc.connectCount, 0,
            reason: '3s of idle ticks (no CH340) — connectCount '
                'must stay exactly 0 — confirms the user\'s core '
                '"the device stays cold" requirement.');
      });
    });

    test('CH340 appears mid-stream → next tick auto-connects', () {
      fakeAsync((async) {
        final svc = _UsbControllableMock();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(svc.connectCount, 0, reason: 'no CH340 at boot');

        // User plugs the CH340 in mid-session.  The next 1s tick
        // observes the new USB state and invokes connect.
        svc.plugCh340();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(svc.connectCount, 1,
            reason: 'after plugCh340 + 1s tick → scanCh340 sees CH340 '
                '→ watcher invokes connect()');
        expect(provider.connected, isTrue,
            reason: 'connect succeeded → provider enters connected '
                'state — automatic recovery from the unplug-replug '
                'cycle without a button press.');
      });
    });

    test('connected + CH340 vanishes → proactive disconnect(stopWatcher:'
        'false) — watcher stays armed', () {
      fakeAsync((async) {
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(provider.connected, isTrue);

        // User yanks the USB cable mid-session.  The very next 1s
        // tick observes CH340 absent and calls
        // disconnect(stopWatcher: false) — tears down the worker
        // immediately (saving the ~250ms `_accumulateRead` timeout
        // against the dead port) but keeps the watcher armed so
        // the app reconnects automatically when the CH340 comes
        // back.
        svc.unplugCh340();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(provider.connected, isFalse,
            reason: 'CH340 disappeared → watcher invoked '
                'disconnect(stopWatcher: false) → _connected=false');
        expect(provider.isUsbWatching, isTrue,
            reason: 'watcher stays armed after the proactive '
                'disconnect — `stopWatcher: false` leaves the timer '
                'alone so the next plug-in relights connect without '
                'user action');
        expect(svc.connectCount, 1,
            reason: 'no new connect since disconnect; just the one '
                'from the original boot handshake');

        // Now plug the CH340 back in.  The next 1s tick should
        // observe it present and re-invoke connect() → automatic
        // recovery from a transient unplug.
        svc.plugCh340();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(svc.connectCount, 2,
            reason: 'CH340 reappeared → next tick relit connect() '
                '→ watcher auto-recovered without user intervention');
        expect(provider.connected, isTrue,
            reason: 'relit connect succeeded → provider re-enters '
                'connected state; user just sees the chart resume.');
      });
    });

    test('user disconnect then unplug+replug auto-reconnects (Phase D '
        'follow-up fix for "manual disconnect → unplug → replug → no '
        'auto-reconnect")', () {
      fakeAsync((async) {
        // Regression for user-reported bug:
        //   1. connected state
        //   2. manual disconnect → previously stopUsbWatch cancelled
        //      the watcher entirely
        //   3. unplug device → no watcher to observe
        //   4. plug in device → no auto-reconnect (watcher was dead)
        //
        // Phase D follow-up fix: disconnect() sets the
        // _userDisconnected flag but keeps the watcher armed.  The
        // flag suppresses auto-reconnect while the CH340 is still
        // plugged (respect user's intent).  When the watcher observes
        // the physical unplug, the flag clears — so the next plug-in
        // reconnects automatically.
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(svc.connectCount, 1);
        expect(provider.isUsbWatching, isTrue);
        expect(provider.connected, isTrue);

        // User explicit disconnect — fire-and-forget (do NOT await:
        // async test bodies inside fakeAsync don't pump the future
        // chain past `await`).  Pump the microtasks after the call
        // so the disconnect future chain completes.
        provider.disconnect();
        async.flushMicrotasks();

        // After user disconnect, watcher STAYS ARMED (Phase D
        // follow-up — no longer stopUsbWatch here).  The user intent
        // flag holds so subsequent ticks don't immediately undo the
        // disconnect while the CH340 stays plugged.
        expect(provider.isUsbWatching, isTrue,
            reason: 'Phase D follow-up: watcher stays armed even '
                'after user disconnect so future unplug+replug can '
                'auto-reconnect.  Previously the watcher was stopped '
                'here, which caused the "unplug+replug → no auto-'
                'reconnect" bug.');
        expect(provider.connected, isFalse,
            reason: 'disconnect succeeded, _connected=false');
        expect(svc.connectCount, 1,
            reason: 'no new connect from disconnect call');

        // Advance past many 1s cycles — CH340 still plugged, but
        // _userDisconnected flag must hold → no auto-reconnect.
        // This is the explicit-disconnect-respected invariant.
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(svc.connectCount, 1,
            reason: 'CH340 still plugged + _userDisconnected flag '
                'set → every watcher tick no-ops.  User disconnect '
                'is respected while the cable remains plugged.');

        // User physically unplugs.  Watcher next tick observes
        // scanCh340().found == false + _userDisconnected flag →
        // clears the flag (unplug moots the user-intent state).
        svc.unplugCh340();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(svc.connectCount, 1,
            reason: 'physical unplug + not connected → no connect '
                'attempt (watcher\'s no-op branch for absent CH340)');

        // User physically plugs back in.  Watcher tick sees
        // scanCh340().found == true + flag cleared → invokes
        // connect() automatically — THE user-requested behaviour.
        svc.plugCh340();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(svc.connectCount, 2,
            reason: 'Phase D follow-up regression: after manual '
                'disconnect + physical unplug + replug, the app '
                'must auto-reconnect without user intervention — '
                'the _userDisconnected flag was cleared by the '
                'physical unplug so this plug-in event is treated '
                'as a fresh session.');
        expect(provider.connected, isTrue,
            reason: 'auto-reconnect after replug → provider re-'
                'enters connected state; user just sees the chart '
                'resume.  Regression for the reported bug "manual '
                'disconnect → unplug → replug → no auto-reconnect".');
      });
    });

    test('manual disconnect + manual connect cycle preserves watcher '
        '(Phase D fix)', () {
      fakeAsync((async) {
        // Regression for "手动点击几次 connect 和 disconnect 自动
        // 连接和自动识别会出问题": previously, manual disconnect
        // stopped the watcher (default stopWatcher: true) and manual
        // connect() did NOT re-arm it → subsequent unplug / worker
        // crash had no auto-recovery → app stuck "disconnected".
        //
        // Phase D follow-up changed the semantics: disconnect() no
        // longer stops the watcher; it just sets a _userDisconnected
        // flag.  Any connect() call (manual or auto) clears the
        // flag.  So manual disconnect → manual connect is now
        // always safe — the watcher always stays armed, and any
        // subsequent unplug+replug auto-recovers.
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(provider.connected, isTrue);
        expect(provider.isUsbWatching, isTrue);
        expect(svc.connectCount, 1);

        // User explicit disconnect — fire-and-forget (sync-style
        // fakeAsync body, no await: pump microtasks to let the
        // disconnect future chain resolve).
        provider.disconnect();
        async.flushMicrotasks();
        expect(provider.isUsbWatching, isTrue,
            reason: 'Phase D follow-up: watcher stays armed after '
                'user disconnect — only dispose() stops the watcher.');
        expect(provider.connected, isFalse);

        // User manually reconnects.  connect() clears the
        // _userDisconnected flag and re-affirms the watcher (no-op
        // if already armed).  After this point, the user-disconnect
        // intent is fully consumed.
        provider.connect(port: '/dev/ttyUSB0');
        async.flushMicrotasks();
        expect(provider.connected, isTrue);
        expect(svc.connectCount, 2);
        expect(provider.isUsbWatching, isTrue,
            reason: 'watcher stays armed after manual connect — '
                'regression for the "几次 connect 和 disconnect 后'
                '自动连接失效" bug.');

        // Simulate unplug + replug — the (still-armed) watcher must
        // auto-reconnect, proving the manual disconnect/connect
        // cycle preserved watcher semantics (not just ticked the
        // "armed" flag without actually working).
        svc.unplugCh340();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(provider.connected, isFalse,
            reason: 'unplug observed → proactive disconnect');

        svc.plugCh340();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(svc.connectCount, greaterThan(2),
            reason: 're-plug observed → watcher relights connect — '
                'this would have failed before the fix because the '
                'manual disconnect had permanently stopped the '
                'watcher and the subsequent manual connect did not '
                're-arm it.');
        expect(provider.connected, isTrue);
      });
    });

    test('worker crash relights connect via the still-armed watcher', () {
      fakeAsync((async) {
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(provider.connected, isTrue);
        expect(svc.connectCount, 1);
        expect(provider.isUsbWatching, isTrue,
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
        expect(provider.isUsbWatching, isTrue,
            reason: 'the watcher was NOT cancelled by the crash — '
                'disconnect() is the only thing that cancels it '
                '(default stopWatcher: true).  Crash recovery relies '
                'on the next 1s tick relighting connect() once '
                'scanCh340() reports the CH340 is still present.');

        // Advance past the next 1s cycle — the watcher must call
        // scanCh340() again, observe the CH340 still plugged in,
        // and invoke connect().
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(svc.connectCount, 2,
            reason: 'auto-scan relights connect after worker crash '
                'without user intervention');
        expect(provider.connected, isTrue,
            reason: 'relit connect succeeds → provider re-enters '
                'connected state');
      });
    });

    test('dispose cancels the watcher (no leak)', () {
      fakeAsync((async) {
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);
        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(provider.isUsbWatching, isTrue);

        provider.dispose();
        expect(provider.isUsbWatching, isFalse,
            reason: 'dispose() cancels the watcher so no periodic '
                'Timer leaks after the provider is destroyed');
      });
    });

    test('startUsbWatch is idempotent on repeat calls', () {
      fakeAsync((async) {
        final svc = _UsbControllableMock()..plugCh340();
        final provider = PowerSupplyProvider(svc);

        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(svc.connectCount, 1);

        // Second startUsbWatch must be a no-op — calling it twice
        // never spawns a second timer (which would double the tick
        // rate to 500ms).
        provider.startUsbWatch();
        async.flushMicrotasks();
        expect(svc.connectCount, 1,
            reason: 'second startUsbWatch is a no-op because the '
                'timer is already armed — the `if (_usbWatchTimer '
                '!= null) return` guard prevents duplicate timers');
      });
    });
  });
}

/// Mock whose USB enumeration state the test can drive indirectly
/// from the test thread (plugCh340 / unplugCh340), and whose
/// `connect()` counts calls.
///
/// Inherits the rest of [MockModbusService]'s behaviour — including
/// the periodic 250ms timer that emits realistic data into
/// `_controller`, and [MockModbusService.simulateCrash] for the
/// worker-crash recovery test.
class _UsbControllableMock extends MockModbusService {
  int connectCount = 0;
  bool _hasCh340 = false;

  /// Test hook: simulate the user plugging the CH340 adapter in.
  void plugCh340() => _hasCh340 = true;

  /// Test hook: simulate the user yanking the CH340 adapter out.
  void unplugCh340() => _hasCh340 = false;

  @override
  Future<SerialPortScanResult> scanCh340() async {
    return _hasCh340
        ? const SerialPortScanResult(
            portName: '/dev/ttyUSB0',
            reason: 'fake: CH340 present at /dev/ttyUSB0',
          )
        : const SerialPortScanResult.notFound('fake: CH340 absent');
  }

  /// Phase D fix regression — overrides the mock's default `null`
  /// with the fake CH340 port name so the provider can pick it up
  /// via `_service.currentPort` on the auto-scan path (where the
  /// caller passes `port: null` to `connect()`).
  @override
  String? get currentPort => _hasCh340 ? '/dev/ttyUSB0' : null;

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
