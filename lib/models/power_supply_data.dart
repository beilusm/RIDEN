/// Communication health status.
enum CommStatus { online, updating, timeout, error, offline }

/// Holds a single snapshot of all power-supply registers plus a
/// timestamp so the chart can plot values over time.
class PowerSupplyData {
  final DateTime timestamp;
  final CommStatus commStatus; // updated by provider based on poll health

  // ── Real-time readouts (RO) ───────────────────────────────────
  final int modelId;
  final double inputVoltage; // HR[14] ÷ 100
  /// No longer populated from any register.  Kept as a deprecated
  /// compatibility field — HR[3] is now decoded as [firmwareVersion]
  /// per the device datasheet (Phase A schema audit).
  @Deprecated('HR[3] is now firmwareVersion; auxVoltage is unused')
  final double auxVoltage;
  final double temperature; // HR[5] system temperature (°C)
  /// System temperature in Fahrenheit (HR[7], int16 signed).  Renamed
  /// from `internalState` after the Phase A schema audit confirmed the
  /// datasheet role.  Use [int.toSigned] when decoding the raw wire
  /// value so negative temperatures are handled correctly.
  final double systemTempF;
  final double outputVoltage; // HR[10] ÷ 100
  final double outputCurrent; // HR[11] ÷ 1000
  final double inputVoltageAlt; // HR[14] ÷ 10 (alt path, conflict)
  /// No longer populated.  Kept as a deprecated compatibility field —
  /// HR[15] is now decoded as [keyLock] (enum {0,1}) per the device
  /// datasheet (Phase A schema audit).
  @Deprecated('HR[15] is now keyLock; statusFlags is unused')
  final int statusFlags;
  /// Key Lock state (HR[15], enum R/W).  `0` = unlocked, `1` = locked.
  final int keyLock;
  /// Protection status (HR[16], enum RO).  `0` = normal, `1` = OVP,
  /// `2` = OCP, `3` = OTP.  Emitted by both the FAST poll loop and
  /// the full read path once registered in the datasheet schema.
  final int protectionStatus;
  final bool isConstantCurrent; // HR[17] == 1 (enum 0=CV 1=CC)
  final bool outputEnabled; // HR[18] == 1 (enum 0=关闭 1=打开)
  final int capacityMah; // HR[39]
  final int energyMwh; // HR[41]
  /// Firmware version (HR[3], uint16 RO).  No scaling; shown as raw.
  final int firmwareVersion;

  // ── Set-points (RW) ───────────────────────────────────────────
  final double setVoltage; // HR[8] ÷ 100
  final double setCurrent; // HR[9] ÷ 1000
  final double ovp; // HR[82] ÷ 100 — over-voltage protection
  final double ocp; // HR[83] ÷ 1000 — over-current protection

  // ── Memory slots ──────────────────────────────────────────────
  final List<MemorySlot> memorySlots;

  // ── Misc ──────────────────────────────────────────────────────
  final int screenBrightness; // HR[72]

  const PowerSupplyData({
    required this.timestamp,
    this.commStatus = CommStatus.offline,
    this.modelId = 60067,
    this.inputVoltage = 0,
    this.auxVoltage = 0,
    this.temperature = 30,
    this.systemTempF = 0,
    this.outputVoltage = 0,
    this.outputCurrent = 0,
    this.inputVoltageAlt = 0,
    this.statusFlags = 0,
    this.keyLock = 0,
    this.protectionStatus = 0,
    this.isConstantCurrent = false,
    this.outputEnabled = false,
    this.capacityMah = 0,
    this.energyMwh = 0,
    this.firmwareVersion = 0,
    this.setVoltage = 0,
    this.setCurrent = 0,
    this.ovp = 62,
    this.ocp = 6.2,
    this.memorySlots = const [],
    this.screenBrightness = 3,
  });

  /// Derived: output power in watts.
  double get outputPower => outputVoltage * outputCurrent;

  /// Derived: CV / CC mode label.
  String get modeLabel => isConstantCurrent ? 'CC' : 'CV';

  /// Copy-with for immutable updates.
  PowerSupplyData copyWith({
    DateTime? timestamp,
    CommStatus? commStatus,
    int? modelId,
    double? inputVoltage,
    double? auxVoltage,
    double? temperature,
    double? systemTempF,
    double? outputVoltage,
    double? outputCurrent,
    double? inputVoltageAlt,
    int? statusFlags,
    int? keyLock,
    int? protectionStatus,
    bool? isConstantCurrent,
    bool? outputEnabled,
    int? capacityMah,
    int? energyMwh,
    int? firmwareVersion,
    double? setVoltage,
    double? setCurrent,
    double? ovp,
    double? ocp,
    List<MemorySlot>? memorySlots,
    int? screenBrightness,
  }) {
    return PowerSupplyData(
      timestamp: timestamp ?? this.timestamp,
      commStatus: commStatus ?? this.commStatus,
      modelId: modelId ?? this.modelId,
      inputVoltage: inputVoltage ?? this.inputVoltage,
      auxVoltage: auxVoltage ?? this.auxVoltage,
      temperature: temperature ?? this.temperature,
      systemTempF: systemTempF ?? this.systemTempF,
      outputVoltage: outputVoltage ?? this.outputVoltage,
      outputCurrent: outputCurrent ?? this.outputCurrent,
      inputVoltageAlt: inputVoltageAlt ?? this.inputVoltageAlt,
      statusFlags: statusFlags ?? this.statusFlags,
      keyLock: keyLock ?? this.keyLock,
      protectionStatus: protectionStatus ?? this.protectionStatus,
      isConstantCurrent: isConstantCurrent ?? this.isConstantCurrent,
      outputEnabled: outputEnabled ?? this.outputEnabled,
      capacityMah: capacityMah ?? this.capacityMah,
      energyMwh: energyMwh ?? this.energyMwh,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      setVoltage: setVoltage ?? this.setVoltage,
      setCurrent: setCurrent ?? this.setCurrent,
      ovp: ovp ?? this.ovp,
      ocp: ocp ?? this.ocp,
      memorySlots: memorySlots ?? this.memorySlots,
      screenBrightness: screenBrightness ?? this.screenBrightness,
    );
  }
}

/// One memory slot: [Vset, Iset, OVP, OCP].
class MemorySlot {
  final int index; // M0 … M9
  final double vSet; // V
  final double iSet; // A
  final double ovp; // V
  final double ocp; // A

  const MemorySlot({
    required this.index,
    this.vSet = 0,
    this.iSet = 0,
    this.ovp = 62,
    this.ocp = 6.2,
  });

  MemorySlot copyWith({double? vSet, double? iSet, double? ovp, double? ocp}) {
    return MemorySlot(
      index: index,
      vSet: vSet ?? this.vSet,
      iSet: iSet ?? this.iSet,
      ovp: ovp ?? this.ovp,
      ocp: ocp ?? this.ocp,
    );
  }
}
