/// **Register conflict ledger** — known ambiguities in the RIDEN
/// register map that have surfaced from code inspection.
///
/// This file is *documentation only*.  It does not fix anything.
/// Each entry records:
/// - the register address,
/// - a short description of the issue,
/// - the code paths that disagree,
/// - the side-effects (what the UI / Dashboard currently does),
/// - the resolution required (which datasheet entry to consult).
///
/// The [RegisterDefinition.conflict] flag on the corresponding
/// entry in [RegisterTable] mirrors the presence of an entry here.
/// Whenever a conflict is resolved against the datasheet, the flag
/// must be cleared both here and in [RegisterTable].
///
/// See the audit report (chat history) for the full code-path
/// citations behind each issue.
library;

/// One resolved-or-open conflict.
class RegisterConflict {
  final int address;
  final String title;
  final String issue;
  final List<String> codePaths;
  final String sideEffect;
  final String resolution;

  const RegisterConflict({
    required this.address,
    required this.title,
    required this.issue,
    required this.codePaths,
    required this.sideEffect,
    required this.resolution,
  });
}

/// All known conflicts, ordered by address.
class RegisterConflicts {
  RegisterConflicts._();

  static const List<RegisterConflict> all = [
    RegisterConflict(
      address: 14,
      title: '[RESOLVED] Input Voltage — /100 confirmed, /10 legacy path',
      issue:
          '同一个寄存器在代码中有两种 scale：'
          '/100（inputVoltage）和 /10（inputVoltageAlt）。'
          '没有 datasheet 无法决定哪个正确。',
      codePaths: [
        'lib/services/modbus_worker.dart:264  _fastPoll  r(9)/100.0 → inputVoltage',
        'lib/services/serial_modbus_service.dart:223 _parseAllRegs r(14)/100.0 → inputVoltage',
        'lib/services/serial_modbus_service.dart:231 _parseAllRegs r(14)/10.0  → inputVoltageAlt',
        'lib/models/power_supply_data.dart:12  // HR[2] ÷ 10   ← 注释且地址错误',
        'lib/models/power_supply_data.dart:18  // HR[14] ÷ 10',
      ],
      sideEffect:
          'Dashboard 顶部状态栏显示的输入电压值（15.x V）来自 /100 路径，'
          '而 PowerSupplyData.inputVoltageAlt 字段使用 /10 路径，二者差异 10×。'
          'RegisterTable 中 HR[14] 标记 conflict，scale=1 不缩放。',
      resolution:
          'RESOLVED (datasheet clarification, Phase B.2): /100 confirmed '
          'correct for HR[14] inputVoltage — value / 100 = 实际电压. /10 '
          '路径 (PowerSupplyData.inputVoltageAlt) 是历史遗留字段，Phase '
          'B.2 不在范围内清理，作为 code debt 保留. HR[2] 错误注释 '
          '(见 address 2 conflict) 同样作为历史注释 debt 保留，不影响运行。',
    ),
    RegisterConflict(
      address: 82,
      title: '[RESOLVED] HR[82] — M0 slot OVP storage, not active OVP',
      issue:
          'HR[82] 同时被当作"顶层 OVP 设定"（setOVP）'
          '和"M0 记忆槽的 OVP 字段"（saveMemorySlot(0, ...)）写入。'
          '物理上是同一个寄存器，但概念映射互相冲突。',
      codePaths: [
        'lib/services/serial_modbus_service.dart:175  setOVP(v) → writeRegister(82, v*100)',
        'lib/services/serial_modbus_service.dart:194  saveMemorySlot(0, ...) → writeRegister(82, ovp*100)',
        'lib/services/modbus_worker.dart:270           _fastPoll r(77)/100.0 → ovp  ← 顶层读取',
        'lib/services/modbus_worker.dart:283           _slowPoll idx=0 读 HR[80..83] ← M0 槽读取',
      ],
      sideEffect:
          '调用 setOVP 会同时改顶层 OVP 与 M0 槽 OVP。'
          'RegisterTable 中 HR[82] 标记 conflict；isWritable 返回 false，'
          'RegisterPage 编辑按钮被禁用，避免加重歧义。',
      resolution:
          'RESOLVED (datasheet clarification, Phase B.2): HR[82] = M0 '
          'Memory Slot 的 OVP storage，不是 active OVP。Active OVP '
          '由 HR[19] 当前 slot 决定，地址 = HR[80 + activeSlot*4 + 2] '
          '(M0=82, M1=86, M2=90, …)。设备不存在独立"顶层 OVP"寄存器；'
          '原 ① 不成立、② 成立。代码修复路径已在 Phase B.2 实施：'
          'worker FAST poll 仍读 HR[82] 但 service 层不再采纳 '
          'snap.ovp/ocp 作为 active 值（_sub.listen 守卫），provider '
          '从 quickSwitch fullPoll 和 SLOW poll slot-sync 解码 active '
          'slot storage。本 conflict 保留为历史审计，issue/codePaths 不删。',
    ),
    RegisterConflict(
      address: 83,
      title: '[RESOLVED] HR[83] — M0 slot OCP storage, not active OCP',
      issue:
          'HR[83] 同 HR[82]，顶层 OCP 与 M0 槽 OCP 字段地址重叠。',
      codePaths: [
        'lib/services/serial_modbus_service.dart:178  setOCP(a) → writeRegister(83, a*1000)',
        'lib/services/serial_modbus_service.dart:198  saveMemorySlot(0, ...) → writeRegister(83, ocp*1000)',
        'lib/services/modbus_worker.dart:271           _fastPoll r(78)/1000.0 → ocp  ← 顶层读取',
        'lib/services/modbus_worker.dart:283           _slowPoll idx=0 读 HR[80..83] ← M0 槽读取',
      ],
      sideEffect: '同 HR[82]。RegisterTable 中标记 conflict，禁止写入。',
      resolution:
          'RESOLVED (datasheet clarification, Phase B.2): HR[83] = M0 '
          'Memory Slot 的 OCP storage，不是 active OCP。Active OCP '
          '由 HR[19] 当前 slot 决定，地址 = HR[80 + activeSlot*4 + 3] '
          '(M0=83, M1=87, M2=91, …)。修复路径同 HR[82]，详见 '
          'HR[82] resolution。本 conflict 保留为历史审计。',
    ),
    RegisterConflict(
      address: 15,
      title: 'Status Flags — bit layout unconfirmed',
      issue:
          'HR[15] 在代码中以 int 整体读取存入 PowerSupplyData.statusFlags，'
          '没有做任何 bit 解码。原 register_view.dart 历史曾标 bitmap 是猜测，'
          '现已撤回。bit0..bit15 的具体含义仍未知。',
      codePaths: [
        'lib/services/modbus_worker.dart:265  _fastPoll r(10) → statusFlags（uint16 整体读）',
        'lib/services/serial_modbus_service.dart:232  _parseAllRegs r(15) → statusFlags',
        'lib/models/power_supply_data.dart:19  // HR[15]   （无 bit 注释）',
      ],
      sideEffect:
          'Dashboard 没有显示状态位含义，仅做整体传递。'
          'RegisterTable 中 HR[15] 标 bitmap + conflict，bitDefinitions 为空。',
      resolution:
          '查 datasheet 的 Status Flags 章节，列出 bit0..bit15 的名称与含义，'
          '按 BitDefinition 列表写入 RegisterTable[15].bitDefinitions。',
    ),
    RegisterConflict(
      address: 17,
      title: 'CC/CV Mode — boolean interpretation uncertain',
      issue:
          'HR[17] 在代码中用 ==1 判定为 bool（isConstantCurrent），'
          '但寄存器宽度是 16 bit，可能含其他 bit（如 CV/CR 模式指示、'
          '过温告警等），未被读取。',
      codePaths: [
        'lib/services/modbus_worker.dart:266  _fastPoll r(12) == 1 → isConstantCurrent',
        'lib/services/serial_modbus_service.dart:233  _parseAllRegs r(17) == 1 → isConstantCurrent',
        'lib/models/power_supply_data.dart:20  // HR[17] == 1',
      ],
      sideEffect:
          'Dashboard 顶部模式标签仅显示 CC/CV 两态。'
          '若 HR[17] 含其他 bit，对应状态当前不会显示。'
          'RegisterTable 中 HR[17] 标 boolean + conflict，isWritable=false。',
      resolution:
          '查 datasheet 确认 HR[17] 是 bool（仅 0/1）还是 bitmap/enum。'
          '若是 bitmap：改 type=bitmap 并填 bitDefinitions。'
          '若是 enum（如 0=CV 1=CC 2=CR）：改 type=enumKind 并填 enumValues。',
    ),
    RegisterConflict(
      address: 18,
      title: 'Output Enable — boolean interpretation uncertain',
      issue:
          'HR[18] 在代码中用 ==1 判定为 outputEnabled，'
          '但寄存器宽度是 16 bit，可能含其他 bit（如软启动状态、'
          '输出故障等），未被读取。',
      codePaths: [
        'lib/services/serial_modbus_service.dart:173  setOutput(e) → writeRegister(18, e ? 1 : 0)',
        'lib/services/modbus_worker.dart:267  _fastPoll r(13) == 1 → outputEnabled',
        'lib/services/serial_modbus_service.dart:234  _parseAllRegs r(18) == 1 → outputEnabled',
      ],
      sideEffect:
          'Dashboard 输出开关只读 0/1 两态。'
          'RegisterTable 中 HR[18] 标 boolean + conflict，'
          '虽然 access=rw，但因 conflict 标记 isWritable 暂时返回 false，'
          'RegisterPage 不允许直接写。Dashboard 的软开关仍通过 setOutput 写入。',
      resolution:
          '查 datasheet 确认 HR[18] 是 bool 还是 bitmap；'
          '若是 bool，清 conflict 标记；若是 bitmap，填 bitDefinitions。',
    ),
    RegisterConflict(
      address: 2,
      title: '[RESOLVED] HR[2] — stale comment, never read by any path',
      issue:
          'lib/models/power_supply_data.dart:12  注释 "// HR[2] ÷ 10" '
          '把 HR[2] 标为 inputVoltage，但代码里并无任何路径真正读取 HR[2] — '
          '所有 inputVoltage 读取路径都使用 HR[14]。注释直接错误。',
      codePaths: [
        'lib/models/power_supply_data.dart:12  // HR[2] ÷ 10  ← 仅注释，无代码',
        'lib/services/serial_modbus_service.dart:223 r(14)/100.0 → inputVoltage',
        'lib/services/modbus_worker.dart:264 r(9)/100.0 → inputVoltage  // regs[9]=HR[14]',
      ],
      sideEffect:
          '预算过项时容易误以为 HR[2] 已被使用。RegisterTable 中 HR[2] 仍是 placeholder。'
          '当前不是真正的寄存器冲突，但是一条会误导后续维护者的注释。',
      resolution:
          'RESOLVED (datasheet clarification, Phase B.2): HR[14] /100 '
          '编码已确认为 inputVoltage 正确路径（见 address 14 conflict），'
          'HR[2] 无任何代码路径读取，注释为历史遗留错误。Phase B.2 不在 '
          '范围内清理 power_supply_data.dart:12 注释，作为注释 debt 保留；'
          '不影响运行，仅影响可读性。本 conflict 保留为历史审计。',
    ),
    RegisterConflict(
      address: 72,
      title: 'HR[72] Backlight — RW inferred from legacy hard-coded set',
      issue:
          'lib/widgets/register_view.dart:166 历史 _isRW 集合把 72 列为可写，'
          '但项目代码里没有任何 setter 真正写过 HR[72]。RW 标签纯粹来自那个 '
          '硬编码集合，没有 datasheet 支撑也没有 setter 验证。',
      codePaths: [
        'lib/widgets/register_view.dart:166  _isRW contains 72  ← 推断来源',
        'lib/services/serial_modbus_service.dart  ← 无 setBacklight / 无 writeRegister(72, ...)',
        'lib/services/modbus_worker.dart        ← 同上',
      ],
      sideEffect:
          'RegisterTable 中 HR[72] 标 rw + inferred，但无 writeRange。'
          'RegisterPage 暂允许写入（inferred），任何写入都直接 Modbus 写到设备，'
          '效果未知，可能造成屏幕亮度异常。',
      resolution:
          '查 datasheet 确认 HR[72] 是否可写、合法值范围。'
          '若不可写，改 access=ro。若可写，补 writeRange 与 description。',
    ),
  ];

  /// Look up conflicts by address.  Returns null when no conflict is
  /// recorded for the given address.
  static RegisterConflict? at(int addr) {
    for (final c in all) {
      if (c.address == addr) return c;
    }
    return null;
  }
}
