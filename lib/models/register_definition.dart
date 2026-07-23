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
    // ── HR[0..19]: device register map (user-confirmed) ───────────
    // Authoritative definitions for the first 20 holding registers
    // supplied directly from the device register map.  These entries
    // use [RegisterSource.datasheet].
    //
    // Notes:
    // - HR[3] (Firmware Version) and HR[7] (System Temp F) disagree
    //   with the legacy worker hard-coded decoders, which read HR[3]
    //   as aux-voltage /10 V and HR[7] as internal-state.  The Modbus
    //   communication layer is intentionally left untouched per the
    //   “不修改 Modbus 通信架构” rule; the worker code paths are now
    //   inconsistent with the schema and flagged for a separate
    //   follow-up alignment task.
    // - HR[14] (Input Voltage): conflict 已在 Phase B.2 清除；编码
    //   = 实际电压 × 100（raw ÷ 100 = V）。/10 路径已从
    //   _parseAllRegs 与 mock 中删除，PowerSupplyData.inputVoltageAlt
    //   字段保留为 default 0 不再赋值。详见
    //   register_conflicts.dart address 14 [RESOLVED]。
    // - HR[15] / HR[17] / HR[18] previously carried `conflict` flags
    //   because their bit layout was unconfirmed; the datasheet
    //   confirms the enum/boolean semantics, so the flags are cleared
    //   here.  The `register_conflicts.dart` ledger is intentionally
    //   left untouched.
    0: const RegisterDefinition(
      address: 0,
      name: 'Model ID',
      description: '产品型号',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      category: RegisterCategory.info,
      dashboardField: 'modelId',
      polling: RegisterPolling.background,
      source: RegisterSource.datasheet,
    ),
    1: const RegisterDefinition(
      address: 1,
      name: 'Serial Number Hi',
      description: '产品序列号高16位',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      category: RegisterCategory.info,
      polling: RegisterPolling.background,
      source: RegisterSource.datasheet,
    ),
    2: const RegisterDefinition(
      address: 2,
      name: 'Serial Number Lo',
      description: '产品序列号低16位',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      category: RegisterCategory.info,
      polling: RegisterPolling.background,
      source: RegisterSource.datasheet,
    ),
    3: const RegisterDefinition(
      address: 3,
      name: 'Firmware Version',
      description: '产品固件版本',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      category: RegisterCategory.info,
      polling: RegisterPolling.background,
      source: RegisterSource.datasheet,
    ),
    4: const RegisterDefinition(
      address: 4,
      name: 'System Temp C Sign',
      description: '0=正，1=负',
      access: RegisterAccess.ro,
      type: RegisterType.enumKind,
      enumValues: {0: '正', 1: '负'},
      category: RegisterCategory.measurement,
      polling: RegisterPolling.fast,
      source: RegisterSource.datasheet,
    ),
    5: const RegisterDefinition(
      address: 5,
      name: 'System Temp C',
      description: '系统摄氏温度数值',
      access: RegisterAccess.ro,
      type: RegisterType.int16,
      unit: '°C',
      category: RegisterCategory.measurement,
      dashboardField: 'temperature',
      polling: RegisterPolling.fast,
      source: RegisterSource.datasheet,
    ),
    6: const RegisterDefinition(
      address: 6,
      name: 'System Temp F Sign',
      description: '0=正，1=负',
      access: RegisterAccess.ro,
      type: RegisterType.enumKind,
      enumValues: {0: '正', 1: '负'},
      category: RegisterCategory.measurement,
      polling: RegisterPolling.fast,
      source: RegisterSource.datasheet,
    ),
    7: const RegisterDefinition(
      address: 7,
      name: 'System Temp F',
      description: '系统华氏温度数值',
      access: RegisterAccess.ro,
      type: RegisterType.int16,
      unit: '°F',
      category: RegisterCategory.measurement,
      polling: RegisterPolling.fast,
      source: RegisterSource.datasheet,
    ),
    8: const RegisterDefinition(
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
    9: const RegisterDefinition(
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
    10: const RegisterDefinition(
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
    11: const RegisterDefinition(
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
    12: const RegisterDefinition(
      address: 12,
      name: 'Output Power Hi',
      description: '输出功率高16位',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      category: RegisterCategory.measurement,
      polling: RegisterPolling.fast,
      source: RegisterSource.datasheet,
    ),
    13: const RegisterDefinition(
      address: 13,
      name: 'Output Power Lo',
      description: '输出功率低16位',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      category: RegisterCategory.measurement,
      polling: RegisterPolling.fast,
      source: RegisterSource.datasheet,
    ),
    14: const RegisterDefinition(
      address: 14,
      name: 'Input Voltage',
      description: '输入电压（读取值 ÷ 100 = 实际电压 V）',
      access: RegisterAccess.ro,
      type: RegisterType.uint16,
      scale: 1, // raw wire encoding (×100); /100 decoding in worker
      unit: 'V',
      category: RegisterCategory.measurement,
      dashboardField: 'inputVoltage',
      polling: RegisterPolling.fast,
      conflict: false,
      source: RegisterSource.inferred,
    ),
    15: const RegisterDefinition(
      address: 15,
      name: 'Key Lock',
      description: '0=未锁定，1=键盘锁定',
      access: RegisterAccess.rw,
      type: RegisterType.enumKind,
      enumValues: {0: '未锁定', 1: '键盘锁定'},
      category: RegisterCategory.system,
      polling: RegisterPolling.fast,
      writeRange: RegisterWriteRange(0, 1),
      source: RegisterSource.datasheet,
    ),
    16: const RegisterDefinition(
      address: 16,
      name: 'Protection Status',
      description: '0=正常，1=OVP，2=OCP，3=OTP',
      access: RegisterAccess.ro,
      type: RegisterType.enumKind,
      enumValues: {0: '正常', 1: 'OVP', 2: 'OCP', 3: 'OTP'},
      category: RegisterCategory.protection,
      polling: RegisterPolling.fast,
      source: RegisterSource.datasheet,
    ),
    17: const RegisterDefinition(
      address: 17,
      name: 'CC/CV Mode',
      description: '0=CV，1=CC',
      access: RegisterAccess.ro,
      type: RegisterType.enumKind,
      enumValues: {0: 'CV', 1: 'CC'},
      category: RegisterCategory.status,
      dashboardField: 'isConstantCurrent',
      polling: RegisterPolling.fast,
      source: RegisterSource.datasheet,
    ),
    18: const RegisterDefinition(
      address: 18,
      name: 'Output Enable',
      description: '0=关闭，1=打开',
      access: RegisterAccess.rw,
      type: RegisterType.enumKind,
      enumValues: {0: '关闭', 1: '打开'},
      category: RegisterCategory.status,
      dashboardField: 'outputEnabled',
      polling: RegisterPolling.fast,
      writeRange: RegisterWriteRange(0, 1),
      source: RegisterSource.datasheet,
    ),
    19: const RegisterDefinition(
      address: 19,
      name: 'Quick Preset',
      description: 'M0~M9',
      access: RegisterAccess.rw,
      type: RegisterType.enumKind,
      enumValues: {
        0: 'M0',
        1: 'M1',
        2: 'M2',
        3: 'M3',
        4: 'M4',
        5: 'M5',
        6: 'M6',
        7: 'M7',
        8: 'M8',
        9: 'M9',
      },
      category: RegisterCategory.status,
      polling: RegisterPolling.manual,
      writeRange: RegisterWriteRange(0, 9),
      source: RegisterSource.datasheet,
    ),

    // ── Memory slot M0: OVP / OCP（HR82/HR83）──────────────────
    // 与 M1..M9 的 _slotDef 等价；conflict 已在 Phase B.2 清除（读
    // 取路径 service 层守卫 + SLOT-sync 已实施，详见 register_conflicts
    // .dart address 82/83 [RESOLVED]）。写路径 setOCP/setOVP 仍指
    // 向 HR82/83，作为 active=0 前提下的等价地址使用，待后续是否
    // reroute 到 active slot 的决策。Active OVP/OCP = HR[80 +
    // HR[19]*4 + 2/3]（M0=82/83, M1=86/87, M2=90/91, …）。
    82: const RegisterDefinition(
      address: 82,
      name: 'M0 OVP',
      description: '预设 M0 的 OVP 值；active OVP 见 HR[80 + HR19*4 + 2]',
      access: RegisterAccess.rw,
      type: RegisterType.uint16,
      scale: 100,
      unit: 'V',
      category: RegisterCategory.protection,
      dashboardField: 'ovp',
      polling: RegisterPolling.fast,
      writeRange: RegisterWriteRange(0, 62),
      conflict: false,
      source: RegisterSource.codeConfirmed,
    ),
    83: const RegisterDefinition(
      address: 83,
      name: 'M0 OCP',
      description: '预设 M0 的 OCP 值；active OCP 见 HR[80 + HR19*4 + 3]',
      access: RegisterAccess.rw,
      type: RegisterType.uint16,
      scale: 1000,
      unit: 'A',
      category: RegisterCategory.protection,
      dashboardField: 'ocp',
      polling: RegisterPolling.fast,
      writeRange: RegisterWriteRange(0, 6.2),
      conflict: false,
      source: RegisterSource.codeConfirmed,
    ),

    // ── Cumulative counters / system (single-path inferred) ───────
    39: const RegisterDefinition(
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
    41: const RegisterDefinition(
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
    72: const RegisterDefinition(
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
    // 82/83 已在上方单独声明（conflict 已在 Phase B.2 清除）。
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
