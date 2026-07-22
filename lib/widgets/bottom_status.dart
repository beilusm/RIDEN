import 'package:flutter/material.dart';
import '../models/power_supply_data.dart';
import '../providers/power_supply_provider.dart';
import '../theme/app_theme.dart';

/// Bottom section: memory slot preset selector, CV/CC mode,
/// output switch, and cumulative energy readout.
class BottomStatus extends StatelessWidget {
  final PowerSupplyData data;
  final PowerSupplyProvider provider;

  const BottomStatus({super.key, required this.data, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        children: [
          // ── Preset selector ────────────────────────────────────
          _presetButton(context),
          const SizedBox(width: 8),

          // ── CV / CC mode ───────────────────────────────────────
          _modeBadge(),
          const SizedBox(width: 8),

          // ── Output enable switch ───────────────────────────────
          _outputSwitch(),
          const Spacer(),

          // ── Cumulative energy ──────────────────────────────────
          _energyDisplay(),
        ],
      ),
    );
  }

  // ── Preset button + dialog ─────────────────────────────────────

  Widget _presetButton(BuildContext context) {
    final slot = provider.slotValues(provider.activeSlot);
    final v = slot != null ? '${slot[0].toStringAsFixed(2)}V' : '--';
    final i = slot != null ? '${slot[1].toStringAsFixed(3)}A' : '--';

    return InkWell(
      onTap: () => _showPresetDialog(context),
      borderRadius: BorderRadius.circular(6),
      child: Tooltip(
        message: 'M${provider.activeSlot}  $v / $i\nTap to change preset',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.setpointYellow.withAlpha(0x88)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bookmark, size: 14, color: AppTheme.setpointYellow),
              const SizedBox(width: 4),
              Text(
                'M${provider.activeSlot}',
                style: AppTheme.digitalValue.copyWith(
                  fontSize: 13,
                  color: AppTheme.setpointYellow,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPresetDialog(BuildContext context) {
    // Trigger lazy slot load on first open
    provider.refreshAllSlots();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppTheme.borderSubtle),
        ),
        title: Row(
          children: [
            const Icon(Icons.bookmark, color: AppTheme.setpointYellow, size: 20),
            const SizedBox(width: 8),
            Text('Memory Presets', style: AppTheme.digitalValue.copyWith(fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: const Row(
                  children: [
                    const SizedBox(width: 36),
                    const Expanded(child: Text('V SET', style: _colStyle, textAlign: TextAlign.center)),
                    const Expanded(child: Text('I SET', style: _colStyle, textAlign: TextAlign.center)),
                    const Expanded(child: Text('OVP', style: _colStyle, textAlign: TextAlign.center)),
                    const Expanded(child: Text('OCP', style: _colStyle, textAlign: TextAlign.center)),
                    const SizedBox(width: 68),
                  ],
                ),
              ),
              const Divider(color: AppTheme.borderSubtle),
              // Slot rows
              for (int i = 0; i < 10; i++) _slotRow(ctx, i),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static const _colStyle = TextStyle(
    fontFamily: 'Noto Sans CJK SC',
    fontSize: 10,
    color: AppTheme.textDim,
  );

  Widget _slotRow(BuildContext ctx, int index) {
    final vals = provider.slotValues(index);
    final isActive = index == provider.activeSlot;

    return InkWell(
      onTap: vals != null
          ? () {
              provider.quickSwitch(index);
              Navigator.of(ctx).pop();
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        decoration: BoxDecoration(
          color: isActive ? AppTheme.setpointYellow.withAlpha(0x15) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            // Slot label
            SizedBox(
              width: 36,
              child: Text(
                'M$index',
                style: AppTheme.digitalValue.copyWith(
                  fontSize: 13,
                  color: isActive ? AppTheme.setpointYellow : AppTheme.textSecondary,
                ),
              ),
            ),
            // Values
            Expanded(child: Text(vals != null ? '${vals[0].toStringAsFixed(2)}V' : '--', style: _valStyle(AppTheme.voltGreen), textAlign: TextAlign.center)),
            Expanded(child: Text(vals != null ? '${vals[1].toStringAsFixed(3)}A' : '--', style: _valStyle(AppTheme.currentBlue), textAlign: TextAlign.center)),
            Expanded(child: Text(vals != null ? '${vals[2].toStringAsFixed(2)}V' : '--', style: _valStyle(AppTheme.protectCyan), textAlign: TextAlign.center)),
            Expanded(child: Text(vals != null ? '${vals[3].toStringAsFixed(3)}A' : '--', style: _valStyle(AppTheme.protectCyan), textAlign: TextAlign.center)),
            // Load button
            SizedBox(
              width: 68,
              child: vals == null
                  ? null
                  : TextButton(
                      onPressed: () {
                        provider.quickSwitch(index);
                        Navigator.of(ctx).pop();
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(isActive ? 'ACTIVE' : 'LOAD', style: AppTheme.bodyMono.copyWith(fontSize: 10, color: AppTheme.setpointYellow)),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _valStyle(Color c) => AppTheme.bodyMono.copyWith(fontSize: 11, color: c);

  // ── Mode badge ─────────────────────────────────────────────────

  Widget _modeBadge() {
    final isCC = data.isConstantCurrent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isCC ? AppTheme.currentBlue.withAlpha(0x22) : AppTheme.voltGreen.withAlpha(0x22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: (isCC ? AppTheme.currentBlue : AppTheme.voltGreen).withAlpha(0x66),
        ),
      ),
      child: Text(
        data.modeLabel,
        style: AppTheme.digitalValue.copyWith(
          fontSize: 13,
          color: isCC ? AppTheme.currentBlue : AppTheme.voltGreen,
        ),
      ),
    );
  }

  // ── Output switch ──────────────────────────────────────────────

  Widget _outputSwitch() {
    final on = data.outputEnabled;
    return InkWell(
      onTap: () => provider.setOutput(!on),
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: on ? AppTheme.voltGreen.withAlpha(0x22) : AppTheme.errorRed.withAlpha(0x18),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: on ? AppTheme.voltGreen : AppTheme.errorRed.withAlpha(0x66),
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.check_circle : Icons.power_settings_new,
              size: 16,
              color: on ? AppTheme.voltGreen : AppTheme.errorRed,
            ),
            const SizedBox(width: 6),
            Text(
              on ? 'ON' : 'OFF',
              style: AppTheme.digitalValue.copyWith(
                fontSize: 13,
                color: on ? AppTheme.voltGreen : AppTheme.errorRed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Energy ─────────────────────────────────────────────────────

  Widget _energyDisplay() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('ENERGY', style: AppTheme.digitalLabel.copyWith(fontSize: 8)),
        const SizedBox(height: 2),
        Text(
          '${data.energyMwh.toString().padLeft(3, '0')} mWh',
          style: AppTheme.digitalValue.copyWith(fontSize: 18, color: AppTheme.setpointYellow),
        ),
      ],
    );
  }
}
