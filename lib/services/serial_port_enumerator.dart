import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter/services.dart' show RootIsolateToken;
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
/// from CLAUDE.md (Desktop 路径 — libserialport FFI 是真同步阻塞
/// I/O，必须放 isolate).
///
/// ── Android 例外 ──────────────────────────────────────────────────
/// Android 路径上的 usb_serial 是 platform channel API（异步非阻塞
/// MethodChannel），不是 FFI；调用 `UsbSerial.listDevices()` 不阻塞
/// UI isolate。它需要 RootIsolateToken + Activity 上下文才能路由
/// MethodChannel — transient `Isolate.run` 启动的 isolate 没有传 token，
/// 调用会 throw StateError 导致 app crash。
///
/// 故 Android 路径在 UI isolate 直接 await，不走 `Isolate.run`。这
/// 不违反"UI 不直接访问 SerialPort"铁律的本意 — 该铁律针对 libserialport
/// FFI 同步阻塞调用，不针对 platform channel async 调用。
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
    throw StateError(
        'Android path should not call enumerateUsbPortsSync — use '
        'enumerateUsbPortsViaIsolate (it routes Android through a '
        'direct UI-isolate Future, not Isolate.run).');
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

/// Android enumeration — async (platform channel) function returning
/// the list of [UsbPortInfo] for CH340 adapters found by the host
/// UsbManager.  Must run in the UI isolate (or any isolate whose
/// `BackgroundIsolateBinaryMessenger.ensureInitialized` was called
/// with the UI's RootIsolateToken).
///
/// Caller invariant: invoked in the UI isolate (the default scanner
/// factory wires this up via [SerialModbusService]'s
/// `_defaultScannerFactory`).
Future<List<UsbPortInfo>> _enumerateAndroidAsync() async {
  final devs = await usb.UsbSerial.listDevices();
  final out = <UsbPortInfo>[];
  for (final d in devs) {
    if (d.vid == 0x1A86 && d.pid == 0x7523) {
      out.add(UsbPortInfo(
        name: 'usb://CH340/${d.deviceId ?? -1}',
        vendorId: d.vid,
        productId: d.pid,
      ));
    }
  }
  return out;
}

/// One-shot [Isolate.run] wrapper around [enumerateUsbPortsSync]
/// (Desktop) or a direct `await _enumerateAndroidAsync()` (Android).
///
/// Phase 4 — Android path returns the Future directly without
/// spawning an isolate; usb_serial MethodChannel needs the UI
/// RootIsolateToken which transient Isolate.run isolates don't carry.
///
/// Used by [SerialModbusService]'s default scanner factory.  Tests
/// bypass this — they inject a [SerialPortScanner] with a fake
/// enumerator callback that returns a synthetic [UsbPortInfo] list,
/// so no isolate is spawned and no FFI is touched.
Future<List<UsbPortInfo>> enumerateUsbPortsViaIsolate() {
  if (Platform.isAndroid) {
    return _enumerateAndroidAsync();
  }
  return Isolate.run(_enumerateDesktopSync);
}

// Suppress unused warning when building Android runner dependencies —
// RootIsolateToken is imported byserial_backend.dart separately.
// Kept here for documentation of the contract (no runtime effect).
// ignore: unused_element
void _androidTokenContractNote(RootIsolateToken? token) => token;
