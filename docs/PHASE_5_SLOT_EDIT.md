# Phase 5 — Memory Slot Data Group Edit Design Doc

> **Status**: APPLIED (v1.1.1 released 2026-07-26)
> **用户需求原始措辞**: "加入编辑 M1-M9 数据组值功能，入口在打开数据组的菜单里面"
> **铁律 override**: CLAUDE.md "不新增业务功能" 禁令（仅本次会话，用户明确请求）

## 1. 设计目标

允许用户在 UI 中直接编辑 M1-M9 任一数据组的 4 个存储值 (V Set / I Set / OVP / OCP)，无需先把当前活动预设切到目标 slot 再用 Settings panel 逐字段改 + `saveSlot` 落盘 — 后者冗长且容易误改 live Vset/Iset。

入口位置：现有预设选择 dialog (`SetpointPanel._showPresets`)，每行尾部加 EDIT icon → 弹出独立 4 字段编辑子 dialog → Save 写入设备 slot storage。

## 2. 入口位置审计

| 候选 | 选用? | 原因 |
|------|------|------|
| `SetpointPanel._showPresets` (dashboard) | ✓ | `dashboard_panel.dart:47` 实际渲染的入口；用户打开"数据组菜单"路径 |
| `BottomStatus._showPresetDialog` (孤立旧 widget) | ✗ | 不在 `dashboard_panel.dart` 出现（代码搜索确认仅自身定义），是 Phase B 之前遗留；改它不算接通入口 |
| `RegisterPage` raw register write | ✗ | 受众不同（调试用，非业务"数据组菜单"语义） |

`BottomStatus._presetButton` 仍保留 Phase B 之前的 `quickSwitch` 路径不变，未做改动以免破坏可能存在的回退路径。

## 3. Storage 寄存器布局

设备 slot storage 寄存器（datasheet 确认 — 见 `register_definition.dart:622-668`）：

| Slot | V Set | I Set | OVP | OCP |
|------|-------|-------|-----|-----|
| M0 | HR80 | HR81 | HR82 | HR83 |
| M1 | HR84 | HR85 | HR86 | HR87 |
| M2 | HR88 | HR89 | HR90 | HR91 |
| M3 | HR92 | HR93 | HR94 | HR95 |
| M4 | HR96 | HR97 | HR98 | HR99 |
| M5 | HR100 | HR101 | HR102 | HR103 |
| M6 | HR104 | HR105 | HR106 | HR107 |
| M7 | HR108 | HR109 | HR110 | HR111 |
| M8 | HR112 | HR113 | HR114 | HR115 |
| M9 | HR116 | HR117 | HR118 | HR119 |

通用公式：`HR[80 + slot*4 + field]`（field ∈ {0=VSet, 1=ISet, 2=OVP, 3=OCP}）。

scale 与 live 等价：V × 100 (uint16)，I × 1000 (uint16)。

## 4. Storage-only edit 语义（与 quickSwitch 的关键差异）

- `saveSlotValues` 写 slot storage **不动 HR8/HR9** live Vset/Iset
- `quickSwitch(slot)` 写 HR19 → 设备固件加载 slot preset 到 HR8/HR9 + active protection 到 HR[80+slot*4+2/3]
- OVP/OCP edit on active slot 会同时改 active protection register（因 Phase B.2 地址重叠，HR[80+activeSlot*4+2/3] 既是 slot storage 又是 active protection storage）— 这是物理地址重叠的副作用，不是 saveSlotValues 的设计意图
- V-Set/I-Set storage edits → 需要 `quickSwitch` round-trip 才能应用到 live Vset/Iset → UI 提示用户 "tap LOAD (quickSwitch) after EDIT to activate"

## 5. Authority routing

```
UI (_showEditSlotDialog) 
  → provider.saveSlotValues(index, v, i, ovp, ocp)
    → service.saveMemorySlot(index, v, i, ovp, ocp)   [existing, 3 ModbusService 实现已存在，未改]
      → writeRegister(80 + index*4 + 0, v * 100)
      → writeRegister(80 + index*4 + 1, i * 1000)
      → writeRegister(80 + index*4 + 2, ovp * 100)
      → writeRegister(80 + index*4 + 3, ocp * 1000)
    → _loadOneSlot(index)   [existing — refresh 缓存 + notifyListeners]
```

零通信层改动。`service.saveMemorySlot` 在三个 ModbusService 实现中早已存在（Phase B.1 之前已用于 `provider.saveSlot` 路径）：

- `MockModbusService.saveMemorySlot` — `mock_modbus_service.dart:176`，写 `_slots[index]` 数字孪生
- `SerialModbusService.saveMemorySlot` — `serial_modbus_service.dart:464`，Desktop 4 次 writeRegister 走 worker isolate
- `DirectAndroidModbusService.saveMemorySlot` — `direct_android_modbus_service.dart:560`，Android 4 次 writeRegister 走 UI isolate usb_serial

## 6. UI 实现

### 6.1 预设 dialog 改造 (setpoint_panel.dart `_showPresets`)

- 整个 ListView 用 `Consumer<PowerSupplyProvider>` 包裹 — 编辑后 `notifyListeners` 触发 rebuild，subtitle 自动刷新
- subtitle 显示从 `slotValues(i)?.map((v) => v.toStringAsFixed(2)).join(' / ')` 拓宽为 4 字段独立精度显示 (`V / A / V / A`)，便于用户区分 V SET 与 OVP
- 每行 `trailing:` 加 `IconButton(Icons.edit, size: 16)`，`onPressed: () => _showEditSlotDialog(ctx, i, vals)`
- IconButton 约束 28×28 dp（默认 ≥48 太大抢行宽；22×22 触屏 target 不达 Material 推荐 48dp — v1.1.2+ 可调到 32×32 + padding）

### 6.2 编辑子 dialog (setpoint_panel.dart `_showEditSlotDialog`)

```
┌─────────────────────────────────┐
│ ✎ Edit M3                       │  ← title + 图标
├─────────────────────────────────┤
│ V SET [12.00] V  [+] [-]        │  ← _editField Item 1
│ I SET [3.000] A  [+] [-]        │  ← _editField Item 2
│ OVP   [13.00] V  [+] [-]        │  ← _editField Item 3
│ OCP   [4.000] A  [+] [-]        │  ← _editField Item 4
├─────────────────────────────────┤
│              [Cancel]  [Save]    │
└─────────────────────────────────┘
```

- 4 个 `TextEditingController` 预填 `current[i].toStringAsFixed(dec)` (2 / 3 / 2 / 3)
- `commit()` async + try/catch（详见 §7 #1）
- 4 个 `_editField` 通过 `onSubmitted: (_) => commit()` 共享 commit 回调（详见 §7 #3）
- `Navigator.pop` 只在 service 写入成功路径后执行（详见 §7 #2）
- Save 按钮 `FilledButton` 用 `AppTheme.voltGreen`（与现有 `_editDialog` Save 一致）

### 6.3 _editField 子组件

label (W56) + Expanded TextField (font 14) + unit (W14) + Column[+/- spin IconButton]

- IconButton 22×22 dp（紧凑放一行；触屏 target 缺陷见 §8 #5）
- spin step (V: 0.01 / I: 0.001 / OVP: 0.01 / OCP: 0.001) 与 `_editDialog` 一致
- `onSubmitted` 回调让回车键直接 commit

## 7. 鲁棒性修复 (4 个)

### #1 try/catch + SnackBar 友好提示

`commit()` 包 try/catch + `ScaffoldMessenger.showSnackBar`：
- 成功 → 绿色 `AppTheme.voltGreen` SnackBar `M$index preset saved`
- 失败 → 红色 `AppTheme.errorRed` SnackBar `Save M$index failed: $e`
- 失败时 dialog **不关**，用户可重试

沿用 Phase E `recording_panel.dart` 的 SnackBar 模式。

### #2 无效输入 SnackBar 而非静默吞

4 字段任一 `double.tryParse(ctrl.text)` 返回 null 时：
- 弹红色 SnackBar `Invalid value — use a decimal number`
- **不关闭** dialog — 让用户能修正输入
- `Navigator.pop` 只在所有 4 个字段都有效 + `saveSlotValues` 成功路径后执行

旧路径 (`if (v == null || ...) return;`) 是静默吞 — 用户输错点 Save 什么都不发生。

### #3 onSubmitted commit (回车确认)

`_editField` 加 `ValueChanged<String> onSubmitted` 参数；`_showEditSlotDialog` 中 4 字段共用 `(_) => commit()` 回调。与 `_editDialog` 一致：`onSubmitted: (_) => commit()`。

### #10 [SLOT_EDIT] debugPrint

`provider.saveSlotValues` 成功路径写两行 debug 日志：
- `[SLOT_EDIT] before M$index <oldVals> → <newVals>` (用户意图)
- `[SLOT_EDIT] after M$index <refreshedVals> (changed|no change — write same as before)` (设备真实回值)

风格与 `[QSW]` (Phase B.1 quickSwitch 日志) 一致 — `before` 行展示用户输入，`after` 行展示设备回读结果，让真机调试时能一眼分辨"我写了什么"vs"设备实际接受了什么"。

实测日志样例：

```
[SLOT_EDIT] before M1  12.00V/3.000A/13.00V/4.000A  →  24.00V/5.000A/25.00V/5.500A
[SLOT_EDIT] after  M1  24.00V/5.000A/25.00V/5.500A  (changed)
```

`(no change — write same as before)`：用户 Save 一份与设备已有值完全相同的输入（容差 1e-6 V / 1e-9 A），日志显示 `no change` 让用户知道"写入了但没改动"。

## 8. 未做的鲁棒性修复（候选后续 v1.1.2+）

| # | 问题 | 影响 | 优先级 |
|---|------|------|--------|
| 4 | 无防双击 disable — 连点 Save 触发两次 saveSlotValues，8 个 register write + 2 个 read race 进 scheduler | 低 (无 dedup key，行为与 quickSwitch 一致) | 后续 |
| 5 | Android touch target 22×22 dp 远低于 Material 推荐 48 dp，触屏误触高 | 中 (Android 用户体验) | 后续 |
| 6 | provider 层无防御性 clamp — UI 调用方 clamp 0..62/0..6.2，但 provider 二次守卫缺失 | 低 (UI 已 clamp) | 后续 |
| 7 | `_loadOneSlot` 失败被其内部 try 吞 — write 成功 + read 回读失败时 UI cache 陈旧 | 低 (下次 refreshAllSlots 同步) | 后续 |
| 8 | 无 dedup key — 高频连续 edit 会排到 scheduler 后面跟 FAST poll 抢带宽 | 低 (一致 quickSwitch 行为) | 后续 |
| 9 | UI dialog 行为零覆盖 — 7 个测试全是 provider 层，无 widget test 验 SnackBar 失败提示 / 双击防抖 / 回车 commit / 小屏布局 | 后续 widget test 补 | 后续 |
| 11 | 没接 Phase E 的 EventLogger — `slot_edit` 类事件未触发 | 低 (Phase E 接口预留 `param_write`) | 后续 |

## 9. 测试

`test/save_slot_values_test.dart` — 7 个新测试：

1. `saveSlotValues updates the cached slotValues via service write` — 写 + 读回刷新缓存
2. `saveSlotValues overwrites a previously-seeded slot` — M1 (12.00, 3.00, 13.0, 4.0) → (24.00, 5.00, 25.0, 5.5)
3. `saveSlotValues fires notifyListeners after the read-back refresh` — listener 计数 ≥ 1，触发 UI Consumer rebuild
4. `saveSlotValues on out-of-range indices is a silent no-op` — index ∈ {-1, 10} 短路不写不通知
5. `saveSlotValues is a storage-only edit — live Vset/Iset untouched` — `quickSwitch(1)` 后 edit M2 不影响 `provider.data.setVoltage/setCurrent`
6. `saveSlotValues can edit M0 even though UI hides it from the dialog` — UI 隐藏 M0 但 provider ranged-valid 接受 index=0
7. `saveSlotValues propagates service failures (no silent swallow)` — `_ThrowingSaveMock` test double throws on saveMemorySlot，验证 rethrow

`_ThrowingSaveMock` implements `ModbusService`，只 override `saveMemorySlot` 抛错，其余方法 delegate 给 wrap 的 `MockModbusService`。

## 10. 铁律保持

未触碰：`ModbusScheduler` / `modbus_task.dart` / `modbus_service.dart` 接口 / `serial_modbus_service.dart` / `mock_modbus_service.dart` / `direct_android_modbus_service.dart` / `modbus_worker.dart` / `_accumulateRead` 250ms / FAST 150ms / SLOW 1000ms / `quickSwitch` / 数据模型 / `RegisterDefinition` / `register_conflicts` / `serial_port_scanner.dart` / `serial_port_enumerator.dart` / `serial_backend.dart`。Phase 5 全部在 UI isolate 新增方法 + UI dialog，复用 `service.saveMemorySlot` 既有写入路径，**零通信层改动**。
