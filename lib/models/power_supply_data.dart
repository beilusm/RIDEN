/// Communication health status.
enum CommStatus { online, updating, timeout, error, offline }

/// Holds a single snapshot of all power-supply registers plus a
/// timestamp so the chart can plot values over time.
class PowerSupplyData {
  final DateTime timestamp;
  final CommStatus commStatus; // updated by provider based on poll health

  // ── Real-time readouts (RO) ───────────────────────────────────
  final int modelId;
  final double inputVoltage; // HR[2] ÷ 10
  final double auxVoltage; // HR[3] ÷ 10
  final double temperature; // HR[5]
  final int internalState; // HR[7]
  final double outputVoltage; // HR[10] ÷ 100
  final double outputCurrent; // HR[11] ÷ 1000
  final double inputVoltageAlt; // HR[14] ÷ 10
  final int statusFlags; // HR[15]
  final bool isConstantCurrent; // HR[17] == 1
  final bool outputEnabled; // HR[18] == 1
  final int capacityMah; // HR[39]
  final int energyMwh; // HR[41]

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
    this.internalState = 0,
    this.outputVoltage = 0,
    this.outputCurrent = 0,
    this.inputVoltageAlt = 0,
    this.statusFlags = 0,
    this.isConstantCurrent = false,
    this.outputEnabled = false,
    this.capacityMah = 0,
    this.energyMwh = 0,
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
    int? internalState,
    double? outputVoltage,
    double? outputCurrent,
    double? inputVoltageAlt,
    int? statusFlags,
    bool? isConstantCurrent,
    bool? outputEnabled,
    int? capacityMah,
    int? energyMwh,
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
      internalState: internalState ?? this.internalState,
      outputVoltage: outputVoltage ?? this.outputVoltage,
      outputCurrent: outputCurrent ?? this.outputCurrent,
      inputVoltageAlt: inputVoltageAlt ?? this.inputVoltageAlt,
      statusFlags: statusFlags ?? this.statusFlags,
      isConstantCurrent: isConstantCurrent ?? this.isConstantCurrent,
      outputEnabled: outputEnabled ?? this.outputEnabled,
      capacityMah: capacityMah ?? this.capacityMah,
      energyMwh: energyMwh ?? this.energyMwh,
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
