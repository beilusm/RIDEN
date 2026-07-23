import 'dart:isolate';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'serial_port_scanner.dart';

/// Libserialport-FFI enumeration entry, runnable inside a one-shot
/// isolate via [Isolate.run].
///
/// This file is the ONLY place where the production USB-port
/// enumeration touches `package:flutter_libserialport`.  It is
/// imported by [SerialModbusService] only to forward the
/// [enumerateUsbPortsViaIsolate] callback into a [SerialPortScanner]
/// — the UI isolate never invokes [SerialPort] methods directly,
/// preserving the "UI isolate 永远不直接访问 SerialPort" invariant
/// from CLAUDE.md.
///
/// Each call spins up a fresh isolate via [Isolate.run], runs the
/// synchronous enumeration, returns the list, and the isolate is
/// auto-killed by `Isolate.run`'s lifecycle.  One scan ≈ one
/// short-lived isolate ≈ a few hundred ms — acceptable for the
/// connect-time auto-detect flow which runs at most once per user
/// connect attempt.
///
/// Robustness contract: a single vanished port (e.g. hot-unplug
/// between `sp_list_ports` and `sp_get_port_by_name`) must not break
/// the whole scan.  Each port is wrapped in a try/catch and skipped
/// on failure — the resulting list is whatever successfully
/// enumerated.
List<UsbPortInfo> enumerateUsbPortsSync() {
  final out = <UsbPortInfo>[];
  for (final name in SerialPort.availablePorts) {
    int? vid;
    int? pid;
    try {
      final port = SerialPort(name);
      try {
        vid = port.vendorId;
        pid = port.productId;
      } finally {
        // Release the sp_port handle promptly — the worker isolate
        // also calls SerialPort(name) during _connect, and we don't
        // want to keep two fd-less handles alive needlessly.
        port.dispose();
      }
    } catch (_) {
      // Skip — port vanished mid-enumeration or FFI lookup failed.
      // The scan continues so one missing port doesn't mask the
      // others.  See file header for the robustness contract.
    }
    out.add(UsbPortInfo(name: name, vendorId: vid, productId: pid));
  }
  return out;
}

/// One-shot [Isolate.run] wrapper around [enumerateUsbPortsSync].
///
/// Used by [SerialModbusService]'s default scanner factory.  Tests
/// bypass this — they inject a [SerialPortScanner] with a fake
/// enumerator callback that returns a synthetic [UsbPortInfo] list,
/// so no isolate is spawned and no FFI is touched.
Future<List<UsbPortInfo>> enumerateUsbPortsViaIsolate() =>
    Isolate.run(enumerateUsbPortsSync);
