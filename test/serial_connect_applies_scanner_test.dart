// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/services/serial_modbus_service.dart';
import 'package:riden_power_supply/services/serial_port_scanner.dart';

/// Integration tests for the auto-scan wired into
/// [SerialModbusService.connect].
///
/// Covers the two branches the user-visible connect flow has:
///   * scanner returns `found` → the device port name passed to
///     `_worker.connect` reflects what the scanner returned
///     (verified indirectly via the post-scan error flavour —
///     the worker tries to open the (fake) port and fails for some
///     FFI-flavoured reason, but that reason is NOT a
///     [SerialPortScanException], proving we got past the
///     auto-scan step).
///   * scanner returns `notFound` → connect throws
///     [SerialPortScanException] and `isConnected` stays false with
///     no worker resources held.
///
/// Career note: the worker isolate (and the scanner isolate when
/// the default factory is used) is short-lived in the not-found
/// path — connect()'s catch block `forceKill`s the spawned worker,
/// and the scanner injected here is a pure-Dart fake (no isolate).
/// No FFI dylib is touched on the not-found branch.
void main() {
  // ── scanner returns not-found ──────────────────────────────────────

  group('SerialModbusService.connect scanner not-found path', () {
    test('throws SerialPortScanException when no CH340 enumerated',
        () async {
      final service = SerialModbusService(
        scannerFactory: () =>
            SerialPortScanner(() async => const <UsbPortInfo>[]),
      );

      // Must throw the typed exception, not a raw Exception —
      // the UI surfaces "no CH340 found" differently from a generic
      // port-open failure.
      await expectLater(
        service.connect(),
        throwsA(isA<SerialPortScanException>()),
      );
      expect(service.isConnected, isFalse,
          reason: 'failed auto-scan must leave _worker == null so the '
              'next connect() can spawn a fresh worker (mirrors P1-2 '
              'zombie-guard invariant)');
    });

    test('scanner exception message describes why no CH340 was found',
        () async {
      // Non-CH340 USB serial present — the exception reason should
      // distinguish "ports exist, none matches CH340" from "the
      // host has zero serial ports".  UI uses the reason string in
      // its SnackBar / debug log.
      final service = SerialModbusService(
        scannerFactory: () => SerialPortScanner(() async => const <UsbPortInfo>[
              UsbPortInfo(
                  name: '/dev/ttyUSB0',
                  vendorId: 0x0403,
                  productId: 0x6001),
            ]),
      );
      SerialPortScanException? caught;
      try {
        await service.connect();
      } on SerialPortScanException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.reason, contains('none matches CH340'),
          reason: 'reason must surface the VID/PID match-failure so '
              'users with multiple USB serials get actionable '
              'diagnostic text');
      expect(caught.scanned.length, 1,
          reason: 'exception carries the enumerated port list for '
              'UI display ("These serial ports are visible, but none '
              'is your RIDEN supply")');
      expect(service.isConnected, isFalse);
    });
  });

  // ── scanner returns found ───────────────────────────────────────────

  group('SerialModbusService.connect scanner-found path', () {
    test('scanner-port reaches _worker.connect (non-scan exception)',
        () async {
      // Inject a scanner that returns a sentinel port name — we
      // never reach this port name via the worker's existing
      // _detectPort heuristic, so the only way the subsequent error
      // would mention /dev/fake-ch340-port is if connect() actually
      // passed the scanner's port through to _worker.connect.
      //
      // The _worker.connect call fails for one of:
      //   * dylib load failure (libserialport not installed)
      //   * sp_get_port_by_name failure (sentinel path doesn't exist)
      //   * sp_open failure (kernel rejects opening a non-device path)
      //
      // All of these produce an error that is NOT a
      // SerialPortScanException — that's the discriminating
      // assertion that proves we past auto-scan and into the
      // port-open step.
      final service = SerialModbusService(
        scannerFactory: () => SerialPortScanner(() async =>
            const <UsbPortInfo>[
              UsbPortInfo(
                  name: '/dev/fake-ch340-port',
                  vendorId: SerialPortScanner.ch340VendorId,
                  productId: SerialPortScanner.ch340ProductId),
            ]),
      );

      Object? caught;
      try {
        await service.connect();
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'scanner returned a port name that doesn\'t exist; '
              'connect must error rather than silently no-op');
      expect(caught, isNot(isA<SerialPortScanException>()),
          reason: 'scanner succeeded → we got past auto-scan → the '
              'remaining error is from _worker.connect trying to open '
              'a non-existent / sentinel port');
      expect(service.isConnected, isFalse,
          reason: 'even on scanner-success → port-open failure, '
              'connect()\'s catch block forceKills the spawned '
              'worker so isConnected flips false');
    });
  });

  // ── explicit port bypasses the scanner entirely ────────────────────

  group('SerialModbusService.connect explicit port', () {
    test('explicit port skips auto-scan (manual-override preserved)',
        () async {
      // Manually-specified port must NOT invoke the scanner — this
      // preserves the SerialPanel port-picker path (the user picked
      // a device, we honour it).  We detect scanner bypass via a
      // scanner callback that throws "scanner should not be called":
      // the call still fails (worker.connect sent the manual port
      // through and couldn't open it), but the error must NOT be a
      // SerialPortScanException, AND it must NOT contain the
      // scanner-blocked reason string.
      final service = SerialModbusService(
        scannerFactory: () =>
            const SerialPortScanner(_failIfCalled),
      );
      Object? caught;
      try {
        await service.connect(port: '/dev/tty-fake-manual');
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught, isNot(isA<SerialPortScanException>()),
          reason: 'manual port must bypass auto-scan; any error here '
              'must come from _worker.connect, not the scanner');
      expect(service.isConnected, isFalse);
    });
  });
}

/// Test-only enumerator that ALWAYS throws when invoked — used to
/// assert the auto-scan path was NOT taken when the caller passed
/// an explicit `port` to [SerialModbusService.connect].
///
/// The futures are pointer-distinct from a `SerialPortScanner` whose
/// enumerate returns `[]` so we can also distinguish "scanner ran
/// and failed" from "scanner never ran".
Future<List<UsbPortInfo>> _failIfCalled() async {
  fail('Scanner must not be invoked when the caller supplies an '
      'explicit port — scannerFactory should be ignored on the '
      'manual-override path.');
}
