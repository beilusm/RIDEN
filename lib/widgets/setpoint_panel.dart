import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/power_supply_data.dart';
import '../providers/power_supply_provider.dart';
import '../theme/app_theme.dart';

/// Settings card: Vset, Iset, OVP, OCP.
class SetpointPanel extends StatelessWidget {
  final PowerSupplyData data;
  final PowerSupplyProvider provider;

  const SetpointPanel({super.key, required this.data, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader('SETTINGS'),
          const SizedBox(height: 6),
          _row(context, 'Voltage', '${data.setVoltage.toStringAsFixed(2)}V', AppTheme.setpointYellow,
              data.setVoltage, 0, 62, 0.01, 2, (v) => provider.setVoltage(v)),
          const SizedBox(height: 3),
          _row(context, 'Current', '${data.setCurrent.toStringAsFixed(3)}A', AppTheme.setpointYellow,
              data.setCurrent, 0, 6.2, 0.001, 3, (v) => provider.setCurrent(v)),
          const SizedBox(height: 8),
          _sectionHeader('PROTECTION'),
          const SizedBox(height: 6),
          _row(context, 'OVP', '${data.ovp.toStringAsFixed(2)}V', AppTheme.protectCyan,
              data.ovp, 0, 62, 0.01, 2, (v) => provider.setOVP(v)),
          const SizedBox(height: 3),
          _row(context, 'OCP', '${data.ocp.toStringAsFixed(3)}A', AppTheme.protectCyan,
              data.ocp, 0, 6.2, 0.001, 3, (v) => provider.setOCP(v)),
          const SizedBox(height: 8),
          // Preset selector
          _presetRow(context),
        ],
      ),
    );
  }

  Widget _sectionHeader(String t) {
    return Text(t, style: AppTheme.digitalLabel.copyWith(fontSize: 9, letterSpacing: 2));
  }

  Widget _row(BuildContext ctx, String label, String value, Color color,
      double cur, double min, double max, double step, int dec, ValueChanged<double> cb) {
    return InkWell(
      onTap: () => _editDialog(ctx, label, cur, '${value.endsWith('A') ? 'A' : 'V'}', min, max, step, dec, cb),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(width: 56, child: Text(label, style: AppTheme.bodyMono.copyWith(fontSize: 11))),
            const Spacer(),
            Text(value, style: AppTheme.digitalValue.copyWith(fontSize: 14, color: color)),
            const SizedBox(width: 4),
            const Icon(Icons.edit, size: 10, color: AppTheme.textDim),
          ],
        ),
      ),
    );
  }

  Widget _presetRow(BuildContext ctx) {
    return Row(
      children: [
        Text('PRESET', style: AppTheme.digitalLabel.copyWith(fontSize: 9, letterSpacing: 2)),
        const Spacer(),
        GestureDetector(
          onTap: () => _showPresets(ctx),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.setpointYellow.withAlpha(0x15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('M${provider.activeSlot}',
                style: AppTheme.digitalValue.copyWith(fontSize: 13, color: AppTheme.setpointYellow)),
          ),
        ),
      ],
    );
  }

  void _showPresets(BuildContext ctx) async {
    await provider.refreshAllSlots();
    if (!ctx.mounted) return;
    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Memory Presets', style: AppTheme.digitalValue.copyWith(fontSize: 16)),
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        content: SizedBox(
          width: 380,
          // Consumer rebuilds when saveSlotValues → _loadOneSlot →
          // notifyListeners fires after an in-place preset edit,
          // so the just-edited slot row's subtitle refreshes
          // without dismissing the preset dialog.
          child: Consumer<PowerSupplyProvider>(
            builder: (_, p, __) => ListView.builder(
              shrinkWrap: true,
              // M0 = 上电默认数据组，不可通过修改 0x13 切回；只展示 M1..M9。
              itemCount: 9,
              itemBuilder: (_, idx) {
                final i = idx + 1;
                final vals = p.slotValues(i);
                final isActive = i == p.activeSlot;
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text('M$i', style: AppTheme.digitalValue.copyWith(fontSize: 13,
                      color: isActive ? AppTheme.setpointYellow : AppTheme.textSecondary)),
                  subtitle: Text(
                    vals != null
                        ? '${vals[0].toStringAsFixed(2)}V / '
                          '${vals[1].toStringAsFixed(3)}A / '
                          '${vals[2].toStringAsFixed(2)}V / '
                          '${vals[3].toStringAsFixed(3)}A'
                        : '--',
                    style: AppTheme.bodyMono.copyWith(fontSize: 10),
                  ),
                  // Trailing EDIT entry — opens the 4-field edit
                  // dialog.  Storage-only edit (writes HR[80+i*4+0..3]
                  // on the device); tap the row to LOAD (quickSwitch)
                  // the freshly-edited preset onto the live output.
                  trailing: vals == null
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.edit, size: 16),
                          color: AppTheme.textDim,
                          tooltip: 'Edit M$i preset values',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                            maxWidth: 28,
                            maxHeight: 28,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: AppTheme.bgInput,
                          ),
                          onPressed: () => _showEditSlotDialog(ctx, i, vals),
                        ),
                  onTap: () { p.quickSwitch(i); Navigator.pop(c); },
                );
              },
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
  }

  /// Opens a 4-field edit dialog (V SET / I SET / OVP / OCP) for the
  /// M[index] slot, pre-filled with [current] (the cached
  /// `_slots[index]` values).  On Save, invokes
  /// [PowerSupplyProvider.saveSlotValues] which writes the slot's
  /// storage registers (HR[80 + index*4 + 0..3]) on the device and
  /// refreshes the local cache via [_loadOneSlot].  The preset
  /// dialog underneath rebuilds (Consumer-bound) so the new
  /// values show up immediately.
  ///
  /// Storage-only edit — does NOT touch the live active Vset/Iset
  /// (HR8/HR9).  An OVP/OCP edit on the *active* slot happens to
  /// land on the same physical register (HR[80+activeSlot*4+2/3] is
  /// also the active protection register per Phase B.2), but
  /// V-Set/I-Set storage edits require a [quickSwitch] round-trip
  /// to apply to the live Vset/Iset.  Use LOAD (tap the row) after
  /// EDIT to activate the freshly-edited preset.
  ///
  /// `current` layout matches [PowerSupplyProvider.slotValues]:
  /// `[vSet, iSet, ovp, ocp]`.
  void _showEditSlotDialog(BuildContext ctx, int index, List<double> current) {
    final vCtrl = TextEditingController(text: current[0].toStringAsFixed(2));
    final iCtrl = TextEditingController(text: current[1].toStringAsFixed(3));
    final ovpCtrl = TextEditingController(text: current[2].toStringAsFixed(2));
    final ocpCtrl = TextEditingController(text: current[3].toStringAsFixed(3));

    void notify(String msg, Color color) {
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ));
    }

    // commit returns true on success (caller closes the dialog), false
    // on validation failure (caller keeps the dialog open so the user
    // can fix the bad input).  Service write failure is caught + surfaced
    // via SnackBar (same pattern as recording_panel's start/stopRecording)
    // and the dialog stays open too — the user may try again.
    Future<void> commit() async {
      final v = double.tryParse(vCtrl.text);
      final i = double.tryParse(iCtrl.text);
      final ovp = double.tryParse(ovpCtrl.text);
      final ocp = double.tryParse(ocpCtrl.text);
      if (v == null || i == null || ovp == null || ocp == null) {
        notify('Invalid value — use a decimal number', AppTheme.errorRed);
        return;
      }
      try {
        await provider.saveSlotValues(
          index,
          v.clamp(0.0, 62.0),
          i.clamp(0.0, 6.2),
          ovp.clamp(0.0, 62.0),
          ocp.clamp(0.0, 6.2),
        );
        notify('M$index preset saved', AppTheme.voltGreen);
        if (ctx.mounted) Navigator.of(ctx).pop();
      } catch (e) {
        notify('Save M$index failed: $e', AppTheme.errorRed);
        // dialog stays open → user may retry
      }
    }

    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.edit, size: 18, color: AppTheme.setpointYellow),
            const SizedBox(width: 8),
            Text('Edit M$index',
                style: AppTheme.digitalValue.copyWith(fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _editField('V SET', vCtrl, 'V', 0.0, 62.0, 0.01, 2, AppTheme.voltGreen,
                  (_) => commit()),
              _editField('I SET', iCtrl, 'A', 0.0, 6.2, 0.001, 3, AppTheme.currentBlue,
                  (_) => commit()),
              _editField('OVP', ovpCtrl, 'V', 0.0, 62.0, 0.01, 2, AppTheme.protectCyan,
                  (_) => commit()),
              _editField('OCP', ocpCtrl, 'A', 0.0, 6.2, 0.001, 3, AppTheme.protectCyan,
                  (_) => commit()),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.voltGreen,
              foregroundColor: Colors.black,
            ),
            onPressed: commit,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// A labelled numeric row with a text field, unit suffix, and +/-
  /// spin buttons.  Used by [_showEditSlotDialog] for the 4 preset
  /// fields (V SET / I SET / OVP / OCP).  Mirrors the spinner widget
  /// in [_editDialog] but compact (font 14, button 22px) so all 4
  /// fields fit inside a 300-wide dialog.
  ///
  /// [onSubmitted] mirrors the live setpoint editor — pressing Enter
  /// on the soft / hard keyboard commits the edit dialog instead of
  /// being a no-op.  All 4 fields share the same commit callback so
  /// Enter on any field behaves the same.
  Widget _editField(
    String label,
    TextEditingController ctrl,
    String unit,
    double min,
    double max,
    double step,
    int dec,
    Color color,
    ValueChanged<String> onSubmitted,
  ) {
    void spin(bool up) {
      final v = (double.tryParse(ctrl.text) ?? min) + (up ? step : -step);
      ctrl.text = v.clamp(min, max).toStringAsFixed(dec);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label, style: AppTheme.bodyMono.copyWith(fontSize: 11)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: ctrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: AppTheme.digitalValue.copyWith(fontSize: 14, color: color),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              ),
              onSubmitted: onSubmitted,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 14,
            child: Text(unit,
                style: AppTheme.digitalValue.copyWith(fontSize: 12)),
          ),
          const SizedBox(width: 6),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.add, size: 14),
                onPressed: () => spin(true),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 22, minHeight: 22, maxWidth: 22, maxHeight: 22,
                ),
                style: IconButton.styleFrom(backgroundColor: AppTheme.bgInput),
              ),
              const SizedBox(height: 2),
              IconButton(
                icon: const Icon(Icons.remove, size: 14),
                onPressed: () => spin(false),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 22, minHeight: 22, maxWidth: 22, maxHeight: 22,
                ),
                style: IconButton.styleFrom(backgroundColor: AppTheme.bgInput),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _editDialog(BuildContext ctx, String label, double cur, String unit,
      double min, double max, double step, int dec, ValueChanged<double> cb) {
    final ctrl = TextEditingController(text: cur.toStringAsFixed(dec));

    void commit() {
      final v = double.tryParse(ctrl.text);
      if (v != null) cb(v.clamp(min, max));
      Navigator.pop(ctx);
    }

    void spin(bool up) {
      final v = (double.tryParse(ctrl.text) ?? cur) + (up ? step : -step);
      ctrl.text = v.clamp(min, max).toStringAsFixed(dec);
    }

    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Edit $label', style: AppTheme.digitalValue.copyWith(fontSize: 16)),
        content: SizedBox(
          width: 200,
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: ctrl, autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: AppTheme.digitalValue.copyWith(fontSize: 22, color: AppTheme.setpointYellow),
                decoration: const InputDecoration(isDense: false),
                onSubmitted: (_) => commit(),
              ),
            ),
            const SizedBox(width: 8),
            Text(unit, style: AppTheme.digitalValue.copyWith(fontSize: 16)),
            const SizedBox(width: 8),
            Column(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.add, size: 18), onPressed: () => spin(true),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24, maxWidth: 24, maxHeight: 24),
                  style: IconButton.styleFrom(backgroundColor: AppTheme.bgInput)),
              const SizedBox(height: 4),
              IconButton(icon: const Icon(Icons.remove, size: 18), onPressed: () => spin(false),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24, maxWidth: 24, maxHeight: 24),
                  style: IconButton.styleFrom(backgroundColor: AppTheme.bgInput)),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.voltGreen, foregroundColor: Colors.black),
            onPressed: commit,
            child: const Text('Set'),
          ),
        ],
      ),
    );
  }
}
