import 'dart:async';
import '../models/power_supply_data.dart';
import 'serial_port_scanner.dart';

/// Abstract interface for Modbus RTU communication with the RIDEN
/// power supply.  Swap implementations at runtime to switch between
/// mock (preview / dev) and real serial hardware.
abstract class ModbusService {
  /// Stream that emits a fresh [PowerSupplyData] snapshot on every
  /// successful poll cycle.
  Stream<PowerSupplyData> get dataStream;

  /// Whether the service is currently connected / polling.
  bool get isConnected;

  /// Phase D fix — the actual port name the service is connected to.
  ///
  /// Differs from the caller-supplied port (which may be `null` on
  /// the auto-scan path) because the service's internal scanner may
  /// resolve a CH340 port name when the caller passed `null` to
  /// [connect].  Exposed so the provider / UI can display the
  /// *resolved* port name (e.g. `/dev/ttyUSB0`) rather than the raw
  /// caller input.  Returns `null` when not connected.
  String? get currentPort;

  /// Open the connection and start the polling timer.
  Future<void> connect({String? port, int baudRate = 115200, int address = 1});

  /// Enumerate available serial port names on the host.
  /// Returns an empty list when no ports are detected.
  Future<List<String>> listPorts();

  /// Phase D — lightweight USB-port probe for the CH340 adapter
  /// WITHOUT sending any Modbus traffic.  Runs
  /// `sp_get_port_usb_vid_pid` inside a one-shot isolate (production
  /// path) and returns a [SerialPortScanResult] whose [SerialPortScanResult.found]
  /// flag tells the caller whether a CH340 is currently attached.
  ///
  /// Used by [PowerSupplyProvider]'s USB watcher (1s cadence) so the
  /// polling loop stays cold while the CH340 is absent — the worker
  /// isolate is NOT spawned, no `_accumulateRead` round-trips hit the
  /// device's serial port, and the only cost is the host-side USB
  /// enumeration (~20-50ms per tick).  connect() is only invoked
  /// AFTER the watcher observes a CH340 surface.
  ///
  /// Symmetric teardown: when an already-connected device is
  /// physically unplugged, the watcher's next tick observes `found
  /// == false` and proactively tears down the worker BEFORE the
  /// pending Modbus READ times out (saving up to ~250ms of futile
  /// `_accumulateRead` against a dead port).
  ///
  /// Tests override this on the mock service to simulate plug /
  /// unplug events without spawning an isolate.
  Future<SerialPortScanResult> scanCh340();

  /// Stop polling and release the underlying connection.
  Future<void> disconnect();

  /// Write a single holding-register value.
  /// [address] – register address (0-indexed from the register map).
  /// [value]   – raw 16-bit integer to write.
  Future<void> writeRegister(int address, int value);

  /// Convenience: set output voltage (HR[8] × 100 → raw).
  Future<void> setVoltage(double volts);

  /// Convenience: set output current (HR[9] × 1000 → raw).
  Future<void> setCurrent(double amps);

  /// Convenience: toggle output on/off (HR[18]).
  Future<void> setOutput(bool enable);

  /// Convenience: trigger a hardware quick-switch to memory slot
  /// M0..M9 by writing the slot index to HR[19] (0x0013).
  ///
  /// Per the device datasheet, writing a value 0..9 to HR[19] causes
  /// the device firmware to load the corresponding preset's Vset /
  /// Iset / OVP / OCP into the active registers.  This is the
  /// fast path — no extra round-trips to read the slot first.
  ///
  /// The legacy [loadMemorySlot] path (read slot → write each field
  /// back via [setVoltage]/[setOCP]/…) is preserved for backwards
  /// compatibility.  Use [quickSwitch] for new code paths.
  Future<void> quickSwitch(int slotIndex);

  /// Convenience: load a memory slot to registers HR[8-9] and
  /// HR[80+n*4+2] / HR[80+n*4+3] for OVP/OCP.
  ///
  /// Deprecated since Phase B — the verified device protocol supports
  /// a one-shot hardware switch via [quickSwitch] (write HR[19] = Mx).
  /// New code must use [quickSwitch].  This implementation is
  /// preserved for fallback / A/B comparison and is not called from
  /// any UI path anymore.
  @Deprecated('Use quickSwitch(slotIndex) instead — Phase B verified '
      'HR[19] as the device-side quick-switch entry point')
  Future<void> loadMemorySlot(int slotIndex);

  /// Save current set-points (Vset, Iset, OVP, OCP) into a memory slot.
  Future<void> saveMemorySlot(int slotIndex, double vSet, double iSet, double ovp, double ocp);

  /// Read a single memory slot's raw register values.
  /// Returns [vSetRaw, iSetRaw, ovpRaw, ocpRaw] or null on failure.
  Future<List<int>?> readMemorySlot(int slotIndex);

  /// Bulk-read all 10 memory slots (HR[80..119]) in a single Modbus RTU
  /// round-trip.  Returns a list of parsed [MemorySlot] objects — slots
  /// whose registers fell outside a partial read are skipped, so the
  /// returned list may have fewer than 10 entries on truncated reads.
  ///
  /// Phase B.1 — replaces the previous `for (i in 0..9) readMemorySlot(i)`
  /// cycle in [PowerSupplyProvider.refreshAllSlots] / [_startBgSlotRefresh]
  /// (10 sequential 4-register reads, ~250ms each → worst-case ~2.5s).
  /// One bulk 40-register read is ~250ms total and exposes slot storage
  /// latency comparable to a single FAST poll cycle.
  Future<List<MemorySlot>> readAllMemorySlots();

  /// Convenience: set OVP (over-voltage protection) — device-specific.
  Future<void> setOVP(double volts);

  /// Convenience: set OCP (over-current protection) — device-specific.
  Future<void> setOCP(double amps);

  /// Read all 121 registers at once (HR[0-120]), for debugging.
  Future<PowerSupplyData?> readAllRegisters();

  /// Return raw register values HR[0-120] as a list of ints.
  ///
  /// Optional [dedup] coalesces repeated reads with the same key
  /// (pending-only — never running).  Optional [expireMs] makes a
  /// queued read auto-cancel after the given delay, so a slow device
  /// cannot pile up stale reads forever.
  Future<List<int>?> readRawRegisters({String? dedup, int? expireMs});

  /// Pause tiered polling timers (for register view mode).
  void pauseTieredPolling();

  /// Resume tiered polling timers (back to dashboard).
  void resumeTieredPolling();

  /// [PERF] Increment notifyListeners counter for timeline profiling.
  void incNotify() {}
}
