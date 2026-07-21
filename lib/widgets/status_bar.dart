import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import '../models/power_supply_data.dart';
import '../providers/power_supply_provider.dart';
import '../theme/app_theme.dart';

/// Info bar: energy, input voltage, temperature, output state, comm status.
class StatusBar extends StatelessWidget {
  final PowerSupplyData data;
  final PowerSupplyProvider provider;

  const StatusBar({super.key, required this.data, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _chip(Icons.bolt, '${data.energyMwh}mWh', AppTheme.setpointYellow),
          const Spacer(),
          _chip(Icons.power_input, '${data.inputVoltage.toStringAsFixed(1)}V', AppTheme.textSecondary),
          const Spacer(),
          _chip(Icons.thermostat, '${data.temperature.toStringAsFixed(0)}°C', AppTheme.warningOrange),
          const Spacer(),
          // Comm status dot
          _commDot(data.commStatus),
          // Register mode button
          const SizedBox(width: 4),
          _regBtn(context),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 12, color: color.withAlpha(0xCC)),
      const SizedBox(width: 3),
      Text(label, style: AppTheme.bodyMono.copyWith(fontSize: 11, color: color)),
    ]);
  }

  Widget _commDot(CommStatus s) {
    final c = switch (s) {
      CommStatus.online => AppTheme.voltGreen,
      CommStatus.timeout => AppTheme.warningOrange,
      CommStatus.error || CommStatus.offline => AppTheme.errorRed,
      _ => AppTheme.textDim,
    };
    return Container(width: 8, height: 8,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: c.withAlpha(0x88), blurRadius: 4)]));
  }

  Widget _regBtn(BuildContext ctx) {
    return GestureDetector(
      onTap: () => ctx.read<PowerSupplyProvider>().toggleRegView(),
      child: const Icon(Icons.list_alt, size: 16, color: AppTheme.textDim),
    );
  }
}
