// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/services/serial_port_scanner.dart';

/// Pure-Dart unit tests for [SerialPortScanner].  No isolate spawn,
/// no FFI, no `package:flutter_libserialport` import on this side —
/// the enumerator is injected as a fake async callback returning a
/// synthetic [UsbPortInfo] list.
///
/// The production path (`SerialModbusService.connect` →
/// `enumerateUsbPortsViaIsolate`) is exercised separately in
/// [test/serial_connect_applies_scanner_test.dart] against a real
/// [ModbusWorkerHandle.spawn] — that one touches libserialport FFI
/// in the worker isolate; this file is hermetic.
void main() {
  // ── Identifiers ────────────────────────────────────────────────────

  group('SerialPortScanner CH340 identifiers', () {
    test('expose the documented WCH VID/PID pair', () {
      expect(SerialPortScanner.ch340VendorId, 0x1A86);
      expect(SerialPortScanner.ch340ProductId, 0x7523);
    });
  });

  // ── Happy path ──────────────────────────────────────────────────────

  group('SerialPortScanner.scanCh340 happy path', () {
    test('finds CH340 among multiple USB-serial adapters', () async {
      // Two non-CH340 USB serials (FTDI + ST-Link VCP) and the
      // actual CH340 — scanner must return the CH340's port name
      // regardless of position in the list.
      final scanner = SerialPortScanner(() async => <UsbPortInfo>[
            const UsbPortInfo(
                name: '/dev/ttyACM0',
                vendorId: 0x0483,
                productId: 0x3748),
            const UsbPortInfo(
                name: '/dev/ttyUSB0',
                vendorId: SerialPortScanner.ch340VendorId,
                productId: SerialPortScanner.ch340ProductId),
            const UsbPortInfo(
                name: '/dev/ttyUSB1',
                vendorId: 0x0403,
                productId: 0x6001),
          ]);
      final r = await scanner.scanCh340();
      expect(r.found, isTrue, reason: 'CH340 present → must be found');
      expect(r.portName, '/dev/ttyUSB0');
      expect(r.reason, contains('CH340 found at /dev/ttyUSB0'));
      expect(r.scanned.length, 3,
          reason: 'scanned list contains all enumerated ports '
              'for host diagnostics even on success');
    });

    test('CH340 as the only port succeeds', () async {
      final scanner = SerialPortScanner(() async => const <UsbPortInfo>[
            UsbPortInfo(
                name: 'COM5',
                vendorId: SerialPortScanner.ch340VendorId,
                productId: SerialPortScanner.ch340ProductId),
          ]);
      final r = await scanner.scanCh340();
      expect(r.found, isTrue);
      expect(r.portName, 'COM5',
          reason: 'cross-platform: Windows COM* port names flow '
              'through the scanner unchanged');
    });

    test('first CH340 wins when multiple CH340s attached', () async {
      // Rare in practice but a documented selection policy — first
      // match in enumeration order, deterministic across hosts that
      // order ports by kernel enumeration (Linux sysfs, Windows
      // SetupDi order).
      final scanner = SerialPortScanner(() async => <UsbPortInfo>[
            const UsbPortInfo(
                name: '/dev/ttyUSB0',
                vendorId: SerialPortScanner.ch340VendorId,
                productId: SerialPortScanner.ch340ProductId),
            const UsbPortInfo(
                name: '/dev/ttyUSB1',
                vendorId: SerialPortScanner.ch340VendorId,
                productId: SerialPortScanner.ch340ProductId),
          ]);
      final r = await scanner.scanCh340();
      expect(r.found, isTrue);
      expect(r.portName, '/dev/ttyUSB0',
          reason: 'first-match policy keeps selection deterministic');
      expect(r.scanned.length, 2);
    });

    test('same VID but wrong PID is not a match', () async {
      // CH341 has the same VID (0x1A86) but a different product ID
      // for some modes — must NOT be misclassified as the CH340
      // we expect for the RIDEN supply.
      final scanner = SerialPortScanner(() async => const <UsbPortInfo>[
            UsbPortInfo(
                name: '/dev/ttyUSB0',
                vendorId: SerialPortScanner.ch340VendorId,
                productId: 0x5512), // not the CH340 PID
          ]);
      final r = await scanner.scanCh340();
      expect(r.found, isFalse,
          reason: 'PID mismatch must disqualify even when VID matches');
    });
  });

  // ── Failure paths ───────────────────────────────────────────────────

  group('SerialPortScanner.scanCh340 failure paths', () {
    test('returns notFound on an empty port list', () async {
      final scanner = SerialPortScanner(
          () async => const <UsbPortInfo>[]);
      final r = await scanner.scanCh340();
      expect(r.found, isFalse);
      expect(r.portName, isNull);
      expect(r.reason, 'No serial ports found on host');
      expect(r.scanned, isEmpty);
    });

    test('returns notFound when no port matches CH340 VID/PID', () async {
      final scanner = SerialPortScanner(() async => <UsbPortInfo>[
            const UsbPortInfo(
                name: '/dev/ttyUSB0',
                vendorId: 0x0403,
                productId: 0x6001), // FTDI
            const UsbPortInfo(
                name: '/dev/ttyACM0',
                vendorId: 0x0483,
                productId: 0x3748), // ST-Link
          ]);
      final r = await scanner.scanCh340();
      expect(r.found, isFalse);
      expect(r.portName, isNull);
      expect(r.reason, contains('none matches CH340'));
      expect(r.scanned.length, 2,
          reason: 'exact enumerated list returned alongside the '
              'not-found reason — UI can show the user "these ports '
              'exist but none is your power supply"');
    });

    test('returns notFound when all ports are non-USB (null VID/PID)',
        () async {
      // Native UART / desktop motherboard serial, Bluetooth serial
      // adapters.  libserialport returns null VID/PID for these
      // because they don't have a USB descriptor at all.
      final scanner = SerialPortScanner(() async => const <UsbPortInfo>[
            UsbPortInfo(name: '/dev/ttyS0'),
            UsbPortInfo(name: '/dev/ttyS1'),
          ]);
      final r = await scanner.scanCh340();
      expect(r.found, isFalse,
          reason: 'null VID/PID never matches the CH340 constants');
      expect(r.scanned.length, 2);
    });

    test('collapses enumerator errors into a notFound result', () async {
      // Mirrors what `enumerateUsbPortsViaIsolate` would surface
      // should libserialport dylib load / sp_list_ports fail.  The
      // caller (connect path) still gets a SerialPortScanException,
      // never a raw exception.
      final scanner = SerialPortScanner(
          () async => throw Exception('libserialport not found'));
      final r = await scanner.scanCh340();
      expect(r.found, isFalse);
      expect(r.portName, isNull);
      expect(r.reason, contains('Port enumeration failed'));
      expect(r.reason, contains('libserialport not found'));
    });
  });

  // ── Data-class invariants ──────────────────────────────────────────

  group('UsbPortInfo / SerialPortScanResult value semantics', () {
    test('UsbPortInfo is value-equal', () {
      const a = UsbPortInfo(name: '/dev/ttyUSB0', vendorId: 0x1A86, productId: 0x7523);
      const b = UsbPortInfo(name: '/dev/ttyUSB0', vendorId: 0x1A86, productId: 0x7523);
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });

    test('SerialPortScanResult.found is a derived property', () {
      const found = SerialPortScanResult(
        portName: '/dev/ttyUSB0',
        reason: 'CH340 found at /dev/ttyUSB0',
      );
      const missing = SerialPortScanResult.notFound('no match');
      expect(found.found, isTrue);
      expect(missing.found, isFalse);
    });

    test('SerialPortScanException carries the scanned ports for UI diag',
        () {
      const scanned = <UsbPortInfo>[
        UsbPortInfo(name: '/dev/ttyUSB0', vendorId: 0x0403, productId: 0x6001),
      ];
      final exc = SerialPortScanException('no CH340 present', scanned: scanned);
      expect(exc.reason, 'no CH340 present');
      expect(exc.scanned, same(scanned),
          reason: 'preserves the list ref so the UI can iterate '
              'without copy');
      expect(exc.toString(), contains('no CH340 present'));
    });
  });
}
