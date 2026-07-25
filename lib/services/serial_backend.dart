import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken;
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:usb_serial/usb_serial.dart' as usb;

/// Abstract serial backend.  Both Desktop (libserialport FFI, sync
/// blocking read) and Android (usb_serial platform channel, async
/// Stream-based read) implement this interface so [ModbusWorkerCore]
/// can stay platform-agnostic.
///
/// Designed for use in the **worker isolate only** — neither backend
/// is safe to call from the UI isolate (libserialport would block
/// the UI; usb_serial would silently route through the wrong
/// BinaryMessenger).
abstract interface class SerialBackend {
  /// Open the port.  `portName` semantics are platform-specific:
  /// Desktop — device path `/dev/ttyUSB0` / `COM3` (null = auto-detect
  /// first matching CH340-style name in [SerialPort.availablePorts]).
  /// Android — ignored (CH340 is auto-found by VID 0x1A86 / PID
  /// 0x7523).  Throws on open failure.
  Future<void> open({String? portName, required int baudRate});

  /// List available port names.  Desktop — device paths.  Android —
  /// synthetic `usb://CH340/<deviceId>` strings (one per CH340 found).
  Future<List<String>> enumeratePortNames();

  /// Write bytes to the port.
  Future<void> write(Uint8List data);

  /// Read up to [maxCount] bytes, waiting at most [timeout] for the
  /// first chunk to arrive.  Returns an empty [Uint8List] on timeout.
  /// Implementation must NOT block the caller beyond [timeout] + a
  /// small epsilon.
  Future<Uint8List> readChunk(int maxCount, Duration timeout);

  /// True if the port is currently open and usable.
  bool get isOpen;

  /// Close the port.  Idempotent.
  Future<void> close();

  /// Release underlying handle / subscription.  Idempotent.
  void dispose();
}

/// Desktop backend — wraps `flutter_libserialport` FFI.
///
/// `readChunk` keeps libserialport's synchronous blocking read
/// semantics (it runs in the worker isolate, so blocking is fine —
/// the UI isolate stays responsive).  The `Future` wrapper is just
/// for [SerialBackend] interface uniformity; it completes
/// synchronously.
class _LibserialportBackend implements SerialBackend {
  SerialPort? _port;

  @override
  Future<void> open({String? portName, required int baudRate}) async {
    portName ??= _autoDetect();
    if (portName == null) {
      throw Exception('No serial port found. Connect RIDEN via CH340 USB.');
    }
    _port = SerialPort(portName);
    if (!_port!.openReadWrite()) {
      final err = SerialPort.lastError;
      _port!.dispose();
      _port = null;
      throw Exception(
          'Failed to open $portName: ${err?.message ?? "unknown"}');
    }
    final cfg = _port!.config;
    cfg.baudRate = baudRate;
    cfg.bits = 8;
    cfg.parity = SerialPortParity.none;
    cfg.stopBits = 1;
    cfg.setFlowControl(SerialPortFlowControl.none);
    _port!.config = cfg;
  }

  static String? _autoDetect() {
    for (final p in SerialPort.availablePorts) {
      final lower = p.toLowerCase();
      // Linux: /dev/ttyUSB* or /dev/ttyACM*
      // macOS: /dev/cu.usbserial* or /dev/cu.usbmodem*
      // Windows: COM*
      if (lower.contains('ttyusb') ||
          lower.contains('ttyacm') ||
          lower.contains('usbserial') ||
          lower.contains('usbmodem') ||
          lower.contains('cuserial') ||
          lower.startsWith('com')) {
        return p;
      }
    }
    final ports = SerialPort.availablePorts;
    return ports.isNotEmpty ? ports.first : null;
  }

  @override
  Future<List<String>> enumeratePortNames() async =>
      SerialPort.availablePorts;

  @override
  Future<void> write(Uint8List data) async {
    _port!.write(data);
  }

  @override
  Future<Uint8List> readChunk(int maxCount, Duration timeout) async {
    if (_port == null || !_port!.isOpen) return Uint8List(0);
    return _port!.read(maxCount, timeout: timeout.inMilliseconds);
  }

  @override
  bool get isOpen => _port != null && _port!.isOpen;

  @override
  Future<void> close() async {
    _port?.close();
  }

  @override
  void dispose() {
    _port?.dispose();
    _port = null;
  }
}

/// Android backend — wraps `usb_serial` platform channel.
///
/// `usb_serial` is a Flutter plugin that uses MethodChannel /
/// EventChannel; calling it from a worker isolate requires
/// [BackgroundIsolateBinaryMessenger.ensureIsolateBackgroundInitialized]
/// to be called once at worker startup with the [RootIsolateToken]
/// from the UI isolate (see [initWorkerBackgroundChannel]).
///
/// CH340 detection is by VID/PID; the `portName` arg to [open] is
/// ignored — we always open the first CH340 found.
///
/// The [readChunk] adapter subscribes to `inputStream` once and
/// satisfies each read request from a buffered queue, falling back
/// to a [Completer] wait when the buffer is empty — this preserves
/// the same `attempt <= 1 ? 80 : 30` timing semantics as the desktop
/// `_accumulateRead` loop without ever canceling the underlying
/// subscription.
class _AndroidUsbBackend implements SerialBackend {
  usb.UsbPort? _port;
  StreamSubscription<Uint8List>? _sub;
  final List<Uint8List> _rxBufs = [];
  Completer<Uint8List>? _pendingRead;
  bool _isOpen = false;

  static const int _ch340Vid = 0x1A86;
  static const int _ch340Pid = 0x7523;

  @override
  Future<void> open({String? portName, required int baudRate}) async {
    final devs = await usb.UsbSerial.listDevices();
    usb.UsbDevice? ch340;
    for (final d in devs) {
      if (d.vid == _ch340Vid && d.pid == _ch340Pid) {
        ch340 = d;
        break;
      }
    }
    if (ch340 == null) {
      throw Exception(
          'CH340 not found (expected vid=0x${_ch340Vid.toRadixString(16)} '
          'pid=0x${_ch340Pid.toRadixString(16)}, saw ${devs.length} USB devices)');
    }
    _port = await ch340.create();
    if (_port == null) {
      throw Exception('UsbDevice.create() returned null for CH340');
    }
    if (!await _port!.open()) {
      _port = null;
      throw Exception('UsbPort.open() returned false');
    }
    await _port!.setPortParameters(
      baudRate,
      usb.UsbPort.DATABITS_8,
      usb.UsbPort.STOPBITS_1,
      usb.UsbPort.PARITY_NONE,
    );
    await _port!.setDTR(true);
    await _port!.setRTS(true);
    _sub = _port!.inputStream?.listen(
      (data) {
        if (_pendingRead != null && !_pendingRead!.isCompleted) {
          final c = _pendingRead!;
          _pendingRead = null;
          c.complete(data);
        } else {
          _rxBufs.add(data);
        }
      },
      onError: (Object e) {
        if (_pendingRead != null && !_pendingRead!.isCompleted) {
          _pendingRead!.completeError(e);
          _pendingRead = null;
        }
      },
      onDone: () {
        _isOpen = false;
      },
    );
    _isOpen = true;
  }

  @override
  Future<List<String>> enumeratePortNames() async {
    final devs = await usb.UsbSerial.listDevices();
    final out = <String>[];
    for (final d in devs) {
      if (d.vid == _ch340Vid && d.pid == _ch340Pid) {
        out.add('usb://CH340/${d.deviceId ?? -1}');
      }
    }
    return out;
  }

  @override
  Future<void> write(Uint8List data) async {
    if (_port == null) throw StateError('UsbPort not open');
    await _port!.write(data);
  }

  @override
  Future<Uint8List> readChunk(int maxCount, Duration timeout) async {
    // First drain the buffered queue.
    if (_rxBufs.isNotEmpty) {
      final next = _rxBufs.first;
      if (next.length <= maxCount) {
        _rxBufs.removeAt(0);
        return Uint8List.fromList(next);
      }
      final head = Uint8List.fromList(next.sublist(0, maxCount));
      _rxBufs[0] = Uint8List.fromList(next.sublist(maxCount));
      return head;
    }
    if (!_isOpen || _port == null) return Uint8List(0);
    // Wait for next stream event with a one-shot Completer.
    final c = Completer<Uint8List>();
    _pendingRead = c;
    try {
      final data = await c.future.timeout(timeout);
      // Truncate if larger than maxCount — remainder goes back to buffer.
      if (data.length <= maxCount) return Uint8List.fromList(data);
      final head = Uint8List.fromList(data.sublist(0, maxCount));
      _rxBufs.insert(0, Uint8List.fromList(data.sublist(maxCount)));
      return head;
    } on TimeoutException {
      _pendingRead = null;
      return Uint8List(0);
    }
  }

  @override
  bool get isOpen => _isOpen && _port != null;

  @override
  Future<void> close() async {
    _isOpen = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await _port?.close();
    } catch (_) {}
    _rxBufs.clear();
    if (_pendingRead != null && !_pendingRead!.isCompleted) {
      _pendingRead!.completeError(StateError('Port closed'));
      _pendingRead = null;
    }
  }

  @override
  void dispose() {
    _isOpen = false;
    _sub?.cancel();
    _sub = null;
    _port = null;
    _rxBufs.clear();
    if (_pendingRead != null && !_pendingRead!.isCompleted) {
      _pendingRead!.completeError(StateError('backend disposed'));
      _pendingRead = null;
    }
  }
}

/// Factory: pick backend by host platform.
SerialBackend createBackend() {
  if (Platform.isAndroid) return _AndroidUsbBackend();
  return _LibserialportBackend();
}

/// Called once on worker isolate startup so [_AndroidUsbBackend] can
/// use Flutter platform channels (MethodChannel / EventChannel) from
/// the worker isolate.  On Desktop this is a no-op — libserialport
/// uses dart:ffi and does not require a RootIsolateToken.
///
/// Pre-condition: caller passes the [RootIsolateToken] captured in
/// the UI isolate via [RootIsolateToken.instance].  Passing `null`
/// makes this call a no-op (Desktop path).
///
/// Flutter 3.44 renamed the API from
/// `ensureIsolateBackgroundInitialized` to
/// `BackgroundIsolateBinaryMessenger.ensureInitialized`; this is the
/// static entry that wires up the worker isolate's binary messenger
/// backend so platform channel messages route through to the host
/// plugin (Android usb_serial; libserialport has no channels so
/// nothing else happens on Desktop).
void initWorkerBackgroundChannel(RootIsolateToken? rootToken) {
  if (rootToken == null) return;
  try {
    BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
  } catch (_) {
    // Desktop — libserialport uses FFI, no channel wiring needed.
    // Swallow any unexpected failure so a non-Android host doesn't
    // crash the worker on startup.
  }
}
