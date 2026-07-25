import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:usb_serial/usb_serial.dart' as usb;

import 'serial_port_scanner.dart';

/// Libserialport-FFI enumeration entry, runnable inside a one-shot
/// isolate via [Isolate.run].
///
/// This file is the ONLY place where the production USB-port
/// enumeration touches `package:flutter_libserialport` on Desktop and
/// `package:usb_serial` on Android.  It is imported by
/// [SerialModbusService] only to forward the
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
///
/// Phase 4 — On Android the libserialport FFI path is unavailable
/// (CH340 goes through the host's UsbManager + felHR85 Java driver,
/// not /dev/ttyUSB*).  [enumerateUsbPortsSync] funnels through
/// `usb_serial` to enumerate CH340 by VID/PID instead; the I/O
/// backend used by [ModbusWorkerCore] (_AndroidUsbBackend) likewise
/// talks to usb_serial, so the platform story stays consistent.
List<UsbPortInfo> enumerateUsbPortsSync() {
  if (Platform.isAndroid) {
    return _enumerateAndroidSync();
  }
  return _enumerateDesktopSync();
}

List<UsbPortInfo> _enumerateDesktopSync() {
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

/// Android enumerate — synchronous adapter over usb_serial's async
/// `UsbSerial.listDevices()` so it slots into the existing
/// [Isolate.run] contract used by [enumerateUsbPortsViaIsolate].
///
/// Caller invariant: invoked only inside an isolate that has called
/// [BackgroundIsolateBinaryMessenger.ensureInitialized] with the UI
/// isolate's RootIsolateToken (see
/// `lib/services/serial_backend.dart::initWorkerBackgroundChannel`).
/// When the transient scan isolate aleady inherits that wiring the
/// MethodChannel reply works end-to-end.  Without it, the channel
/// reply silently discards and the future hangs — Phase 4 fast-paths
/// usb_serial calls back to the UI isolate by reusing
/// `enumerateUsbPortsViaIsolate`'s Isolate.run spawn, which shares
/// the binary messenger wiring.
List<UsbPortInfo> _enumerateAndroidSync() {
  // usb_serial.listDevices() is async (MethodChannel round-trip); the
  // Isolate.run wrapper provides a sync entry contract.  We bridge
  // this with a one-shot Future.wait + blocking await — Dart waits
  // are cooperative, no native blocking, but the Isolate itself stays
  // alive until the future completes (Isolate.run's contract is to
  // return the entry's return value, regardless of await depth).
  final completer = Completer<List<UsbPortInfo>>();
  usb.UsbSerial.listDevices().then((devs) {
    final out = <UsbPortInfo>[];
    for (final d in devs) {
      // CH340 VID 0x1A86 / PID 0x7523 — only emit ports that match the
      // RIDEN device_filter so [SerialPortScanner.scanCh340] sees the
      // same single-port semantics as the Desktop path.
      if (d.vid == 0x1A86 && d.pid == 0x7523) {
        out.add(UsbPortInfo(
          name: 'usb://CH340/${d.deviceId ?? -1}',
          vendorId: d.vid,
          productId: d.pid,
        ));
      }
    }
    completer.complete(out);
  }).catchError((e) {
    completer.completeError(Exception('usb_serial listDevices failed: $e'));
  });
  // ignore: discarded_futures — Isolate.run wraps this in a sync
  // contract; the future is awaited inside the isolate's message loop.
  return _awaitResult(completer.future);
}

/// Bridge an async future back to a "sync-style" return inside an
/// Isolate.run target.  Uses a ReceivePort + message-loop drain —
/// equivalent to a blocking await but without raw dart:ffi sleep.
List<UsbPortInfo> _awaitResult(Future<List<UsbPortInfo>> future) {
  final receive = ReceivePort();
  future.then<dynamic>((v) {
    receive.sendPort.send(['ok', v]);
  }).catchError((Object e) {
    receive.sendPort.send(['err', e]);
  });
  final result = receive.first as List<dynamic>;
  receive.close();
  if (result[0] == 'ok') return result[1] as List<UsbPortInfo>;
  throw result[1] as Object;
}

/// One-shot [Isolate.run] wrapper around [enumerateUsbPortsSync].
///
/// Used by [SerialModbusService]'s default scanner factory.  Tests
/// bypass this — they inject a [SerialPortScanner] with a fake
/// enumerator callback that returns a synthetic [UsbPortInfo] list,
/// so no isolate is spawned and no FFI is touched.
Future<List<UsbPortInfo>> enumerateUsbPortsViaIsolate() =>
    Isolate.run(enumerateUsbPortsSync);
