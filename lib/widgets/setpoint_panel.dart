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
          width: 360,
          child: Consumer<PowerSupplyProvider>(
            builder: (_, p, __) => ListView.builder(
              shrinkWrap: true,
              itemCount: 10,
              itemBuilder: (_, i) => ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('M$i', style: AppTheme.digitalValue.copyWith(fontSize: 13,
                    color: i == p.activeSlot ? AppTheme.setpointYellow : AppTheme.textSecondary)),
                subtitle: Text(
                  p.slotValues(i)?.map((v) => v.toStringAsFixed(2)).join(' / ') ?? '--',
                  style: AppTheme.bodyMono.copyWith(fontSize: 10),
                ),
                onTap: () { p.quickSwitch(i); Navigator.pop(c); },
              ),
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
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
