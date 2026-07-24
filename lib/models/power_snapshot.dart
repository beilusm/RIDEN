import '../models/power_supply_data.dart';

/// Phase E — business-level device state snapshot for the recording
/// pipeline.
///
/// Distinct from [PowerSupplyData] (the worker→UI wire model) in two
/// key ways:
///   1. **No register addresses, no HR raw values, no Modbus-specific
///      scalings** — consumers (DataLogger) see only physical units
///      (V / A / W / °C) and high-level enums (outputEnable,
///      protectionState, activeSlot).  This is the user's explicit
///      requirement: "Logger 只能消费业务数据模型".
///   2. **A single, complete measurement** — `PowerSupplyData` snapshots
///      arriving from the worker isolate alternate between "FAST-poll
///      partial" (only measurement fields) and "SLOW-poll partial"
///      (only slot storage).  [SnapshotStore] holds the *merged* view
///      and publishes [PowerSnapshot] from that merged view, so a
///      DataLogger consumer always sees a complete record every
///      tick.
///
/// Construction is via [PowerSnapshot.from] which reads the canonical
/// merged [PowerSupplyData] the provider holds after the
/// `_sub.listen` / `_onData` merge chain.  This keeps the snapshot
/// strictly downstream of all merge / active-slot-sync logic and
/// phase B.2 ovp/ocp guards.
class PowerSnapshot {
  /// UTC-capable timestamp of the merged measurement.
  final DateTime timestamp;

  /// Output voltage in volts (V).
  final double voltage;

  /// Output current in amps (A).
  final double current;

  /// Output power in watts (W) — derived as `voltage * current`.
  final double power;

  /// Input (DC supply) voltage in volts (V) — read from HR[14].
  final double inputVoltage;

  /// Device temperature in degrees Celsius (°C) — read from HR[5].
  final double temperature;

  /// Whether the output stage is enabled (HR[18] == 1).
  final bool outputEnable;

  /// Protection status enum (HR[16]): 0=normal, 1=OVP, 2=OCP, 3=OTP.
  final int protectionState;

  /// Active memory slot (0..9) — mirrored from
  /// `PowerSupplyProvider._activeSlot`.  Set by quickSwitch / SLOW-poll
  /// SLOT-sync, *not* read from a single HR address (HR[19] is read
  /// only on quickSwitch round-trips, not on the FAST poll path).
  final int activeSlot;

  const PowerSnapshot({
    required this.timestamp,
    required this.voltage,
    required this.current,
    required this.power,
    required this.inputVoltage,
    required this.temperature,
    required this.outputEnable,
    required this.protectionState,
    required this.activeSlot,
  });

  /// Build a [PowerSnapshot] from the provider's canonical merged
  /// [PowerSupplyData] (post active-slot-sync, post phase B.2
  /// ovp/ocp guard).  `activeSlot` comes from the provider's slot
  /// tracker rather than the snapshot itself, because the snapshot
  /// doesn't carry slot-identity (only slot *storage* via
  /// `memorySlots`}.
  ///
  /// `power` is derived here rather than taken from
  /// `PowerSupplyData.outputPower` to keep this model self-contained
  /// for serialization (CSV rows) — the value is identical.
  factory PowerSnapshot.from(PowerSupplyData data, {required int activeSlot}) {
    return PowerSnapshot(
      timestamp: data.timestamp,
      voltage: data.outputVoltage,
      current: data.outputCurrent,
      power: data.outputVoltage * data.outputCurrent,
      inputVoltage: data.inputVoltage,
      temperature: data.temperature,
      outputEnable: data.outputEnabled,
      protectionState: data.protectionStatus,
      activeSlot: activeSlot,
    );
  }

  /// Serialize this snapshot as a single CSV row (no trailing
  /// newline).  Column order matches the Phase E design doc:
  ///
  ///     time, voltage, current, power, inputVoltage, temperature,
  ///     outputEnable, protectionState, activeSlot
  ///
  /// `time` is formatted as ISO-8601 with seconds precision (no
  /// fractional seconds, no timezone suffix) — matches the design
  /// doc's example `2026-07-24T20:30:01`.
  ///
  /// Boolean `outputEnable` serializes as the literal `true` /
  /// `false` (lowercase) — matches the design doc's example row
  /// `...,true,0,3`.
  String toCsvRow() {
    final t = timestamp.toIso8601String().split('T').join('T');
    // Trim fractional seconds if present (.xxx) — keep
    // yyyy-mm-ddTHH:MM:SS only.
    final dot = t.indexOf('.');
    final time = dot >= 0 ? t.substring(0, dot) : t;
    return [
      time,
      _fmt(voltage),
      _fmt(current),
      _fmt(power),
      _fmt(inputVoltage),
      _fmt(temperature),
      outputEnable.toString(),
      protectionState.toString(),
      activeSlot.toString(),
    ].join(',');
  }

  /// Format a double for CSV — trim trailing zeros but keep at
  /// least one decimal (so `12.0` stays `12.0`, not `12`).  Avoids
  /// scientific notation for the expected value ranges (mV-scale
  /// power fits easily in plain decimal).
  static String _fmt(double v) {
    // Two decimals is plenty for V / A / W / °C at this device's
    // resolution; trim trailing zeros for compactness.
    var s = v.toStringAsFixed(2);
    if (s.contains('.')) {
      // Strip trailing zeros but keep at least one digit after the
      // decimal point (so `12.00` → `12`, not `12.`).  We
      // intentionally keep the trailing zero for hundredths so CSV
      // consumers see consistent column widths.
      while (s.endsWith('0') && !s.endsWith('.0')) {
        s = s.substring(0, s.length - 1);
      }
    }
    return s;
  }

  @override
  String toString() =>
      'PowerSnapshot(t=$timestamp, V=$voltage, A=$current, W=$power, '
      'Vin=$inputVoltage, T=$temperature, out=$outputEnable, '
      'prot=$protectionState, slot=$activeSlot)';
}
