import 'package:flutter/material.dart';
import '../models/power_supply_data.dart';
import '../theme/app_theme.dart';

/// Large-format measurements card: V / A / W — each on its own row.
class MeasurementDisplay extends StatelessWidget {
  final PowerSupplyData data;
  const MeasurementDisplay({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final vSize = w < 240 ? 40.0 : 54.0;
          final uSize = w < 240 ? 14.0 : 18.0;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _row('${data.outputVoltage.toStringAsFixed(2)}', 'V', AppTheme.voltGreen, vSize, uSize),
              const SizedBox(height: 8),
              _row('${data.outputCurrent.toStringAsFixed(3)}', 'A', AppTheme.currentBlue, vSize, uSize),
              const SizedBox(height: 8),
              _row('${data.outputPower.toStringAsFixed(2)}', 'W', AppTheme.powerPurple, vSize, uSize),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String v, String u, Color c, double vs, double us) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(v, style: AppTheme.digitalValue.copyWith(fontSize: vs, color: c,
              shadows: [Shadow(color: c.withAlpha(0x55), blurRadius: 8)])),
        ),
        const SizedBox(width: 4),
        Text(u, style: AppTheme.digitalValue.copyWith(fontSize: us, color: c.withAlpha(0xBB))),
      ],
    );
  }
}
