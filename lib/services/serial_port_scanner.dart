import 'dart:async';

/// USB descriptor info reported per serial port from the host.
///
/// Populated by [SerialPortScanner]'s enumerator callback.  The
/// production enumerator (see `serial_port_enumerator.dart`) runs
/// libserialport's `sp_get_port_usb_vid_pid` inside a one-shot
/// isolate, so the UI isolate never touches SerialPort (project
///铁律: UI isolate 永远不直接访问 SerialPort — see CLAUDE.md).
///
/// Non-USB transports (e.g., native UART on `/dev/ttyS0`, Bluetooth
/// serial adapters) report `null` for both [vendorId] and
/// [productId] — matches libserialport's behaviour when the port's
/// transport is not USB.
class UsbPortInfo {
  /// OS-visible port name (e.g., `/dev/ttyUSB0`, `COM3`).
  final String name;

  /// USB Vendor ID assigned by USB-IF, or `null` when the port is
  /// not a USB-serial adapter.
  final int? vendorId;

  /// USB Product ID assigned by the vendor, or `null` when the port
  /// is not a USB-serial adapter.
  final int? productId;

  const UsbPortInfo({required this.name, this.vendorId, this.productId});

  @override
  String toString() {
    final vid = vendorId == null ? 'null' : vendorId!.toRadixString(16);
    final pid = productId == null ? 'null' : productId!.toRadixString(16);
    return 'UsbPortInfo($name, vid=0x$vid, pid=0x$pid)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UsbPortInfo &&
          name == other.name &&
          vendorId == other.vendorId &&
          productId == other.productId;

  @override
  int get hashCode => Object.hash(name, vendorId, productId);
}

/// Outcome of a [SerialPortScanner.scanCh340] sweep.
///
/// `portName` is the resolved CH340 port name on success, else null.
/// `reason` carries a user-readable diagnostic for both failure and
/// success cases — the UI surfaces the reason in the SnackBar / log
/// even when [found] is true (e.g. "CH340 found at /dev/ttyUSB0"),
/// so the user can see what was picked.
///
/// `scanned` exposes the full enumerated list so callers can log
/// every detected port — handy for the "what else is on this host"
/// diagnostics when no CH340 turns up.
class SerialPortScanResult {
  final String? portName;
  final String reason;
  final List<UsbPortInfo> scanned;

  /// True when [portName] is non-null — the scanner resolved a CH340.
  bool get found => portName != null;

  const SerialPortScanResult({
    this.portName,
    required this.reason,
    this.scanned = const <UsbPortInfo>[],
  });

  /// Convenience factory for the not-found case — exposes the
  /// diagnostic [reason] and the full enumerated list.
  const SerialPortScanResult.notFound(this.reason,
      {this.scanned = const <UsbPortInfo>[]})
      : portName = null;
}

/// Raised by `SerialModbusService.connect` when [SerialPortScanner]
/// returns no CH340 port.
///
/// Carries the [scanned] list so the caller (UI / test) can log
/// every enumerated port for diagnostics — useful when the user
/// has multiple non-CH340 USB-serial adapters plugged in and the
/// reason text alone doesn't tell them which one is which.
class SerialPortScanException implements Exception {
  final String reason;
  final List<UsbPortInfo> scanned;

  SerialPortScanException(this.reason, {this.scanned = const <UsbPortInfo>[]});

  @override
  String toString() => 'SerialPortScanException: $reason';
}

/// Host-port scanner that finds the CH340 USB-to-serial adapter
/// used to talk to the RIDEN power supply.
///
/// Pure Dart class — no Flutter / dart:ffi / package import.  The
/// actual port enumeration runs in a one-shot isolate via the
/// injected [_enumerate] callback.  Production wires the callback to
/// `enumerateUsbPortsViaIsolate` (see `serial_port_enumerator.dart`)
/// so the synchronous FFI calls (`sp_get_port_by_name` +
/// `sp_get_port_usb_vid_pid`) never run in the UI isolate, preserving
/// the "UI isolate 永远不直接访问 SerialPort" invariant from
/// CLAUDE.md.
///
/// Unit tests inject a fake enumerator with a synthetic list —
/// no isolate spawn, no FFI, deterministic input.
///
/// CH340 identifiers per the WCH datasheet:
///   * Vendor ID  0x1A86
///   * Product ID 0x7523  (CH340 in serial mode)
class SerialPortScanner {
  /// WCH CH340/CH341 vendor ID (per USB-IF assignment).
  static const int ch340VendorId = 0x1A86;

  /// CH340 product ID (USB-serial mode).
  static const int ch340ProductId = 0x7523;

  /// Source of host port descriptors.  Production wires this to
  /// `enumerateUsbPortsViaIsolate`; tests inject a fake enumerator
  /// with a synthetic list.
  final Future<List<UsbPortInfo>> Function() _enumerate;

  const SerialPortScanner(this._enumerate);

  /// Enumerate host ports and return the first one whose USB
  /// descriptor reports VID [ch340VendorId] and PID [ch340ProductId].
  ///
  /// Returns a [SerialPortScanResult] that always carries `reason`
  /// and the full `scanned` list.  Callers branch on [SerialPortScanResult.found]
  /// and surface the reason to the user.
  ///
  /// Selection policy: first-match by enumeration order.  When
  /// multiple CH340s are attached (rare in practice), picking the
  /// first one matches the existing `_detectPort` heuristic and
  /// keeps the behaviour deterministic across hosts that order
  /// ports by kernel enumeration.
  ///
  /// Enumerator failures (e.g., libserialport dylib load error)
  /// are collapsed into a not-found result — the caller still
  /// gets a [SerialPortScanException] through `connect`, not a
  /// raw exception type they'd have to special-case.
  Future<SerialPortScanResult> scanCh340() async {
    final List<UsbPortInfo> ports;
    try {
      ports = await _enumerate();
    } catch (e) {
      return SerialPortScanResult.notFound(
        'Port enumeration failed: $e',
      );
    }
    if (ports.isEmpty) {
      return const SerialPortScanResult.notFound(
        'No serial ports found on host',
      );
    }
    UsbPortInfo? match;
    for (final p in ports) {
      if (p.vendorId == ch340VendorId && p.productId == ch340ProductId) {
        match = p;
        break;
      }
    }
    if (match == null) {
      return SerialPortScanResult.notFound(
        '${ports.length} serial port(s) found, none matches CH340 '
        'VID 0x1A86 / PID 0x7523',
        scanned: ports,
      );
    }
    return SerialPortScanResult(
      portName: match.name,
      reason: 'CH340 found at ${match.name}',
      scanned: ports,
    );
  }
}
