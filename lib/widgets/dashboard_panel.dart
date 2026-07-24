import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/power_supply_provider.dart';
import '../theme/app_theme.dart';
import 'status_bar.dart';
import 'measurement_display.dart';
import 'setpoint_panel.dart';
import 'serial_panel.dart';
import 'recording_panel.dart';
import '../models/power_supply_data.dart';

class DashboardPanel extends StatelessWidget {
  const DashboardPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PowerSupplyProvider>(
      builder: (context, provider, _) {
        final data = provider.data;
        // Scrollable container — Phase E added RecordingPanel below
        // SerialPanel, pushing the total minimum height of the
        // fixed-size Column past the smallest supported window
        // (640px) and triggering a RenderFlex overflow.  Wrapping in
        // SingleChildScrollView lets the column grow naturally and
        // scroll when the host window is too short, while preserving
        // the top-aligned layout (mainAxisSize.min) that the old
        // Spacer() provided when content fit.  The bg color is kept
        // on the outer Container so the dark backdrop fills the
        // available height whether content is shorter or taller.
        return Container(
          color: AppTheme.bgDarkest,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Top info bar ──────────────────────────────────
                StatusBar(data: data, provider: provider),
                const SizedBox(height: 6),
                // ── Measurements (large V/A/W) ────────────────────
                MeasurementDisplay(data: data),
                const SizedBox(height: 6),
                // ── Output switch ────────────────────────────────
                _OutputCard(data: data, provider: provider),
                const SizedBox(height: 6),
                // ── Settings ──────────────────────────────────────
                SetpointPanel(data: data, provider: provider),
                const SizedBox(height: 6),
                // ── Serial connection ─────────────────────────────
                const SerialPanel(),
                const SizedBox(height: 6),
                // ── Recording (Phase E) ────────────────────────────
                const RecordingPanel(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Standalone output switch card.
class _OutputCard extends StatelessWidget {
  final PowerSupplyData data;
  final PowerSupplyProvider provider;
  const _OutputCard({required this.data, required this.provider});

  @override
  Widget build(BuildContext context) {
    final on = data.outputEnabled;
    final mode = data.modeLabel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text('OUTPUT', style: AppTheme.digitalLabel.copyWith(fontSize: 10, letterSpacing: 2)),
          const Spacer(),
          // Mode badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (on ? AppTheme.voltGreen : AppTheme.textDim).withAlpha(0x18),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(mode, style: AppTheme.digitalValue.copyWith(fontSize: 13,
                color: on ? AppTheme.voltGreen : AppTheme.textDim)),
          ),
          const SizedBox(width: 8),
          // Toggle
          GestureDetector(
            onTap: () => provider.setOutput(!on),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 44, height: 26,
              padding: EdgeInsets.only(left: on ? 20.0 : 2.0, right: on ? 2.0 : 20.0),
              decoration: BoxDecoration(
                color: on ? AppTheme.voltGreen : AppTheme.textDim,
                borderRadius: BorderRadius.circular(13),
              ),
              alignment: Alignment.center,
              child: Container(width: 22, height: 22,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
            ),
          ),
        ],
      ),
    );
  }
}
