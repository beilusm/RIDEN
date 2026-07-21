/// Register schema for the RIDEN power supply (HR[0..120]).
///
/// **Design principle**: this file is intended to become the single
/// source of truth for the register map shared by Dashboard,
/// RegisterPage, Write Dialog, Memory Slot, CSV Export and the
/// future Script API.
///
/// **Source policy**: every confirmed field must come directly from
/// the device's official Modbus register specification (datasheet).
/// Until the datasheet is available, a register may be marked with
/// [RegisterSource.codeConfirmed] when (and only when) the same
/// scale/unit/access combination is observable from multiple
/// independent code paths in the existing application — never from
/// a single inference.
///
/// Registers that have neither datasheet confirmation nor
/// multi-path code confirmation are kept as placeholders with
/// [RegisterAccess.unknown] / [RegisterType.unknown].  The UI
/// renders these rows with a grey `?` badge, no edit action, no
/// scaling and no unit.
library;

// ── Enums ───────────────────────────────────────────────────────────

/// Access mode for a single register.
///
/// [unknown] is used for any register whose access mode has not
/// been confirmed — the UI must refuse to write to such registers.
enum RegisterAccess { ro, rw, unknown }

/// Wire-type of a single register.
enum RegisterType {
  uint16,  // 16-bit unsigned integer
  int16,   // 16-bit two's-complement signed integer
  bitmap,  // bit field, see [RegisterDefinition.bitDefinitions]
  boolean, // 0 / 1 only
  enumKind, // enumerated uint16, see [RegisterDefinition.enumValues]
  unknown, // protocol not confirmed
}

/// Functional category used to group registers in the UI and CSV
/// export.  [unknown] means the category has not been confirmed.
enum RegisterCategory {
  info,        // model ID, firmware, etc.
  measurement, // Vout / Iout / Vin / temperature
  setpoint,    // Vset / Iset
  protection,  // OVP / OCP
  status,      // status flags, CC/CV, output enable
  slot,        // M0..M9 memory slot
  system,      // backlight, beep, etc.
  unknown,
}

/// Polling policy declared by the schema.  Worker FAST/SLOW loops
/// still use their hard-coded start/count; this field only informs
/// future phase 4 migration and the RegisterPage UI badge.
enum RegisterPolling {
  fast,        // read by the 150ms FAST loop
  slow,        // read by the 1s SLOW slot loop
  background,  // read once at connect
  manual,      // only read on user action
  unknown,
}

/// Provenance of a [RegisterDefinition] entry.
///
/// [datasheet]  — copied directly from the official register map.
/// [codeConfirmed] — same scale/unit/access observed across
///   multiple independent code paths; not a single inference.
/// [inferred]   — single-path inference, kept only as a hint.
/// [placeholder] — no information, fillin for the address slot.
enum RegisterSource {
  datasheet,
  codeConfirmed,
  inferred,
  placeholder,
}

// ── Bit definition ──────────────────────────────────────────────────

/// Meaning of a single bit inside a bitmap register.
class BitDefinition {
  final int bit;              // 0..15
  final String name;          // e.g. 'OVP'
  final String description;   // human-readable

  const BitDefinition({
    required this.bit,
    required this.name,
    this.description = '',
  });
}

// ── Write range ─────────────────────────────────────────────────────

/// Physical-value range a writable register accepts.  Stored in
/// device units (i.e. *after* scaling).  `null` means unbounded or
/// unknown.
class RegisterWriteRange {
  final double min;
  final double max;

  const RegisterWriteRange(this.min, this.max);
}

// ── Definition ──────────────────────────────────────────────────────

/// Definition of a single holding register.
class RegisterDefinition {
  final int address;
  final String name;
  final String description;
  final RegisterAccess access;
  final RegisterType type;

  /// Divisor applied to the raw 16-bit value to derive the physical
  /// value.  `1` means "do not scale — show the raw value".
  final double scale;

  /// Physical unit (e.g. 'V', 'A', 'mAh').  Empty string means
  /// "no unit known — do not append anything".
  final String unit;

  /// Functional grouping for UI / CSV.  [RegisterCategory.unknown]
  /// means the category has not been confirmed.
  final RegisterCategory category;

  /// Maps this register to a field of [PowerSupplyData] (e.g.
  /// 'outputVoltage').  `null` means the schema does not wire the
  /// register into any Dashboard field.  Used by the future
  /// generic decoder; the current worker still uses hard-coded
  /// decoders and ignores this field.
  final String? dashboardField;

  /// Where the FAST/SLOW loop should read this register.  The
  /// current worker ignores this field; it is kept here for the
  /// phase-4 migration and the RegisterPage badge.
  final RegisterPolling polling;

  /// Physical-value range accepted when writing.  `null` means
  /// unknown — the UI should fall back to raw `0..65535`.
  final RegisterWriteRange? writeRange;

  /// Bit meanings for [RegisterType.bitmap] registers.  Empty for
  /// non-bitmap types.
  final List<BitDefinition> bitDefinitions;

  /// Enumerated values for [RegisterType.enumKind] registers.
  /// `rawValue → label`.  Empty for non-enum types.
  final Map<int, String> enumValues;

  /// Where this definition came from.  See [RegisterSource].
  final RegisterSource source;

  /// True when this entry is known to have conflicting definitions
  /// across the codebase (e.g. HR[14] is read with two different
  /// scales).  Kept as a flag so the UI can badge it and the
  /// phase-3 conflicts file can be cross-referenced.  See
  /// [register_conflicts.dart].
  final bool conflict;

  const RegisterDefinition({
    required this.address,
    required this.name,
    required this.description,
    required this.access,
    required this.type,
    this.scale = 1,
    this.unit = '',
    this.category = RegisterCategory.unknown,
    this.dashboardField,
    this.polling = RegisterPolling.unknown,
    this.writeRange,
    this.bitDefinitions = const [],
    this.enumValues = const {},
    this.source = RegisterSource.placeholder,
    this.conflict = false,
  });

  // ── Derived helpers ─────────────────────────────────────────────

  /// True only when this register is confirmed enough to scale.
  bool get isScaled =>
      access != RegisterAccess.unknown &&
      type != RegisterType.unknown &&
      source != RegisterSource.placeholder &&
      scale > 1;

  /// Decimal places for the scaled display.
  int get decimals {
    if (!isScaled) return 0;
    if (scale >= 1000) return 3;
    if (scale >= 100) return 2;
    if (scale >= 10) return 1;
    return 0;
  }

  /// True when the Write Dialog may offer an edit action.
  bool get isWritable => access == RegisterAccess.rw && !conflict;

  /// Format a raw register value as a display string with unit.
  String format(int raw) {
    if (!isScaled) return '$raw';
    final scaled = raw / scale;
    final num = scaled.toStringAsFixed(decimals);
    return unit.isEmpty ? num : '$num $unit';
  }
}

// ── Table ───────────────────────────────────────────────────────────

/// Central register schema.
///
/// [RegisterTable.all] always returns 121 entries (address 0..120).
/// Every entry whose address is not present in [_confirmed] is a
/// placeholder with [RegisterAccess.unknown] /
/// [RegisterType.unknown] / [RegisterSource.placeholder].
///
/// To add a confirmed register, append an entry to the [_confirmed]
/// map below.  See the source policy at the top of this file.
class RegisterTable {
  RegisterTable._();

  /// All 121 register definitions, ordered by address.
  static final List<RegisterDefinition> all = _buildAll();

  /// Lookup by address.
  ///
  /// In-range addresses always return a definition (placeholder if
  /// not confirmed).  Out-of-range addresses return null.
  static RegisterDefinition? get(int addr) {
    if (addr < 0 || addr > 120) return null;
    return all[addr];
  }

  /// Backwards-compatible alias for [get].
  static RegisterDefinition? at(int addr) => get(addr);

  /// True only for confirmed writable registers.
  static bool isWritable(int addr) =>
      get(addr)?.isWritable ?? false;

  // ── Internals ───────────────────────────────────────────────────

  static List<RegisterDefinition> _buildAll() {
    final list = <RegisterDefinition>[];
    for (int addr = 0; addr <= 120; addr++) {
      list.add(_confirmed[addr] ?? _placeholder(addr));
    }
    return list;
  }

  static RegisterDefinition _placeholder(int addr) => RegisterDefinition(
        address: addr,
        name: 'HR${addr.toString().padLeft(3, '0')}',
        description: 'Unknown',
        access: RegisterAccess.unknown,
        type: RegisterType.unknown,
        source: RegisterSource.placeholder,
      );

  /// Confirmed register definitions keyed by address.
  ///
  /// Each entry must follow the source policy:
  /// - [RegisterSource.datasheet] — copied from the official
  ///   protocol specification.
  /// - [RegisterSource.codeConfirmed] — same scale/unit/access
  ///   observed across multiple independent code paths.
  /// - [RegisterSource.inferred] — only when no better evidence
  ///   exists; flagged with [RegisterDefinition.conflict] if it
  ///   disagrees with another code path.
  ///
  /// When in doubt, leave the entry out; the placeholder is
  /// always safe.
  static final Map<int, RegisterDefinition> _confirmed = _buildConfirmed();

  static Map<int, RegisterDefinition> _buildConfirmed() => {
    // ── Measurement: voltage / current (multi-path confirmed) ─────
    8: RegisterDefinition(
      address: 8,
      name: 'Set Voltage',
      description: '电压设定值',
      access: RegisterAccess.rw,
      type: RegisterType.uint16,
      scale: 100,
      unit: 'V',
      category: RegisterCategory.setpoint,
      dashboardField: 'setVoltage',
      polling: RegisterPolling.fast,
      writeRange: RegisterWriteRange(0, 62),
      source: RegisterSource.codeConfirmed,
    ),
    9: RegisterDefinition(
      address: 9,
      name: 'Set Current',
      description: '电流设定值',
      access: RegisterAccess.rw,
      type: RegisterType.uint16,
      scale: 1000,
      unit: 'A',
      category: RegisterCategory.setpoint,
      dashboardField: 'setCurrent',
      polling: RegisterPolling.fast,
      writeRange: RegisterWriteRange(0, 6.2),
      source: RegisterSource.codeConfirmed,
    ),
    10: RegisterDefinition(
      address: 10,
      name: 'Output Voltage',
      description: '实际输出电压',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      scale: 100,
      unit: 'V',
      category: RegisterCategory.measurement,
      dashboardField: 'outputVoltage',
      polling: RegisterPolling.fast,
      source: RegisterSource.codeConfirmed,
    ),
    11: RegisterDefinition(
      address: 11,
      name: 'Output Current',
      description: '实际输出电流',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      scale: 1000,
      unit: 'A',
      category: RegisterCategory.measurement,
      dashboardField: 'outputCurrent',
      polling: RegisterPolling.fast,
      source: RegisterSource.codeConfirmed,
    ),

    // ── Measurement: conflict flagged (HR14 /100 vs /10) ──────────
    14: RegisterDefinition(
      address: 14,
      name: 'Input Voltage',
      description: '输入电压 — 代码同时存在 /100 与 /10 两种解码，未定',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      scale: 1, // unset until conflict resolved
      unit: 'V',
      category: RegisterCategory.measurement,
      dashboardField: 'inputVoltage',
      polling: RegisterPolling.fast,
      conflict: true,
      source: RegisterSource.inferred,
    ),

    // ── Protection: top-level OVP / OCP ───────────────────────────
    // NOTE: HR82/83 are also the M0 slot OVP/OCP fields — see
    // register_conflicts.dart.  Marked conflict to surface the
    // ambiguity in the UI until the datasheet is consulted.
    82: RegisterDefinition(
      address: 82,
      name: 'OVP',
      description: '过压保护阈值 — 与 M0 slot 的 OVP 字段地址重叠',
      access: RegisterAccess.rw,
      type: RegisterType.uint16,
      scale: 100,
      unit: 'V',
      category: RegisterCategory.protection,
      dashboardField: 'ovp',
      polling: RegisterPolling.fast,
      writeRange: RegisterWriteRange(0, 62),
      conflict: true,
      source: RegisterSource.codeConfirmed,
    ),
    83: RegisterDefinition(
      address: 83,
      name: 'OCP',
      description: '过流保护阈值 — 与 M0 slot 的 OCP 字段地址重叠',
      access: RegisterAccess.rw,
      type: RegisterType.uint16,
      scale: 1000,
      unit: 'A',
      category: RegisterCategory.protection,
      dashboardField: 'ocp',
      polling: RegisterPolling.fast,
      writeRange: RegisterWriteRange(0, 6.2),
      conflict: true,
      source: RegisterSource.codeConfirmed,
    ),

    // ── Status / control (single-path inferred, kept as placeholder+conflict) ──
    // These registers are read as bool (==1) in the worker, but the
    // full bit semantics are unconfirmed.  Left as unknown so the UI
    // refuses to write; conflict flag surfaces the gap.
    15: RegisterDefinition(
      address: 15,
      name: 'Status Flags',
      description: '状态位图 — bit 含义未确认',
      access: RegisterAccess.ro,
      type: RegisterType.bitmap,
      category: RegisterCategory.status,
      dashboardField: 'statusFlags',
      polling: RegisterPolling.fast,
      conflict: true,
      source: RegisterSource.inferred,
    ),
    17: RegisterDefinition(
      address: 17,
      name: 'CC/CV Mode',
      description: '1=恒流模式 — 寄存器全宽含义未确认',
      access: RegisterAccess.ro,
      type: RegisterType.boolean,
      category: RegisterCategory.status,
      dashboardField: 'isConstantCurrent',
      polling: RegisterPolling.fast,
      conflict: true,
      source: RegisterSource.inferred,
    ),
    18: RegisterDefinition(
      address: 18,
      name: 'Output Enable',
      description: '0=关闭 输出 / 1=开启输出 — 寄存器全宽含义未确认',
      access: RegisterAccess.rw,
      type: RegisterType.boolean,
      category: RegisterCategory.status,
      dashboardField: 'outputEnabled',
      polling: RegisterPolling.fast,
      writeRange: RegisterWriteRange(0, 1),
      conflict: true,
      source: RegisterSource.inferred,
    ),

    // ── Info / measurement (single-path inferred) ────────────────
    0: RegisterDefinition(
      address: 0,
      name: 'Model ID',
      description: '设备型号编号',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      category: RegisterCategory.info,
      dashboardField: 'modelId',
      polling: RegisterPolling.background,
      source: RegisterSource.inferred,
    ),
    3: RegisterDefinition(
      address: 3,
      name: 'Aux Voltage',
      description: '辅助输出电压',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      scale: 10,
      unit: 'V',
      category: RegisterCategory.measurement,
      dashboardField: 'auxVoltage',
      polling: RegisterPolling.background,
      source: RegisterSource.codeConfirmed,
    ),
    5: RegisterDefinition(
      address: 5,
      name: 'Temperature',
      description: '机箱温度',
      access: RegisterAccess.ro,
      type: RegisterType.int16,
      unit: '°C',
      category: RegisterCategory.measurement,
      dashboardField: 'temperature',
      polling: RegisterPolling.fast,
      source: RegisterSource.inferred,
    ),
    7: RegisterDefinition(
      address: 7,
      name: 'Internal State',
      description: '设备内部状态码',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      category: RegisterCategory.status,
      dashboardField: 'internalState',
      polling: RegisterPolling.background,
      source: RegisterSource.inferred,
    ),

    // ── Cumulative counters (single-path inferred) ───────────────
    39: RegisterDefinition(
      address: 39,
      name: 'Capacity',
      description: '累积输出容量',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      unit: 'mAh',
      category: RegisterCategory.measurement,
      dashboardField: 'capacityMah',
      polling: RegisterPolling.fast,
      source: RegisterSource.inferred,
    ),
    41: RegisterDefinition(
      address: 41,
      name: 'Energy',
      description: '累积输出能量',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      unit: 'mWh',
      category: RegisterCategory.measurement,
      dashboardField: 'energyMwh',
      polling: RegisterPolling.fast,
      source: RegisterSource.inferred,
    ),
    72: RegisterDefinition(
      address: 72,
      name: 'Backlight',
      description: '屏幕背光亮度',
      access: RegisterAccess.rw,
      type: RegisterType.uint16,
      category: RegisterCategory.system,
      dashboardField: 'screenBrightness',
      polling: RegisterPolling.manual,
      source: RegisterSource.inferred,
    ),

    // ── Memory slots M0..M9 (HR[80..119]) ────────────────────────
    // Each slot spans 4 registers: [V-Set, I-Set, OVP, OCP].
    // Scales are confirmed across three code paths
    // (_slowPoll, _parseAllRegs, _loadOneSlot, refreshAllSlots,
    // saveMemorySlot).  Each slot row is generated below so the
    // category/dashboardField/polling declarations stay explicit
    // instead of being generated by a loop in the UI layer.
    80: _slotDef(80, 0, 'V-Set'),
    81: _slotDef(81, 0, 'I-Set'),
    // 82/83 already declared above (top-level OVP/OCP overlap).
    84: _slotDef(84, 1, 'V-Set'),
    85: _slotDef(85, 1, 'I-Set'),
    86: _slotDef(86, 1, 'OVP'),
    87: _slotDef(87, 1, 'OCP'),
    88: _slotDef(88, 2, 'V-Set'),
    89: _slotDef(89, 2, 'I-Set'),
    90: _slotDef(90, 2, 'OVP'),
    91: _slotDef(91, 2, 'OCP'),
    92: _slotDef(92, 3, 'V-Set'),
    93: _slotDef(93, 3, 'I-Set'),
    94: _slotDef(94, 3, 'OVP'),
    95: _slotDef(95, 3, 'OCP'),
    96: _slotDef(96, 4, 'V-Set'),
    97: _slotDef(97, 4, 'I-Set'),
    98: _slotDef(98, 4, 'OVP'),
    99: _slotDef(99, 4, 'OCP'),
    100: _slotDef(100, 5, 'V-Set'),
    101: _slotDef(101, 5, 'I-Set'),
    102: _slotDef(102, 5, 'OVP'),
    103: _slotDef(103, 5, 'OCP'),
    104: _slotDef(104, 6, 'V-Set'),
    105: _slotDef(105, 6, 'I-Set'),
    106: _slotDef(106, 6, 'OVP'),
    107: _slotDef(107, 6, 'OCP'),
    108: _slotDef(108, 7, 'V-Set'),
    109: _slotDef(109, 7, 'I-Set'),
    110: _slotDef(110, 7, 'OVP'),
    111: _slotDef(111, 7, 'OCP'),
    112: _slotDef(112, 8, 'V-Set'),
    113: _slotDef(113, 8, 'I-Set'),
    114: _slotDef(114, 8, 'OVP'),
    115: _slotDef(115, 8, 'OCP'),
    116: _slotDef(116, 9, 'V-Set'),
    117: _slotDef(117, 9, 'I-Set'),
    118: _slotDef(118, 9, 'OVP'),
    119: _slotDef(119, 9, 'OCP'),
  };

  /// Helper: build a memory-slot register definition.
  ///
  /// `slotIndex` is 0..9 and `field` is one of
  /// {'V-Set', 'I-Set', 'OVP', 'OCP'}.  Scales confirmed across
  /// multiple code paths (see top of file).
  static RegisterDefinition _slotDef(int addr, int slotIndex, String field) {
    final isOCP = field == 'OCP';
    final isISet = field == 'I-Set';
    return RegisterDefinition(
      address: addr,
      name: 'M$slotIndex $field',
      description: '预设 M$slotIndex 的 $field 值',
      access: RegisterAccess.rw,
      type: RegisterType.uint16,
      scale: isOCP || isISet ? 1000 : 100,
      unit: isOCP || isISet ? 'A' : 'V',
      category: RegisterCategory.slot,
      polling: RegisterPolling.slow,
      writeRange: RegisterWriteRange(
        0,
        (isOCP || isISet) ? 6.2 : 62,
      ),
      source: RegisterSource.codeConfirmed,
    );
  }
}
