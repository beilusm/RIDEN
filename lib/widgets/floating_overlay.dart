import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../models/power_supply_data.dart';
import '../providers/power_supply_provider.dart';
import '../services/floating_window_controller.dart';
import '../theme/app_theme.dart';

/// Minimal transparent HUD shown while floating mode is active.
///
/// There is deliberately no card or opaque page background here. Drag the
/// empty area to move the window; the compact controls remain visible in the
/// upper-right corner so the HUD never becomes a dead end.
class FloatingOverlay extends StatelessWidget {
  const FloatingOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<PowerSupplyProvider, FloatingWindowController>(
      builder: (context, provider, floating, _) {
        final data = provider.data;
        final visibleMetrics = <Widget>[
          if (floating.showVoltage)
            _Metric(
              label: 'VOLTAGE',
              value: data.outputVoltage.toStringAsFixed(2),
              unit: 'V',
              color: AppTheme.voltGreen,
            ),
          if (floating.showCurrent)
            _Metric(
              label: 'CURRENT',
              value: data.outputCurrent.toStringAsFixed(3),
              unit: 'A',
              color: AppTheme.currentBlue,
            ),
          if (floating.showPower)
            _Metric(
              label: 'POWER',
              value: data.outputPower.toStringAsFixed(2),
              unit: 'W',
              color: AppTheme.powerPurple,
            ),
        ];

        final hud = GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: floating.locked
              ? null
              : (_) => windowManager.startDragging(),
          onDoubleTap: floating.exit,
          onSecondaryTapUp: (details) =>
              _showHudMenu(context, details.globalPosition),
          onLongPress: () => _showHudMenu(context, Offset.zero),
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    _HudControls(
                      locked: floating.locked,
                      onToggleLock: floating.toggleLocked,
                      onSettings: () => _showFloatingSettings(context),
                      onRestore: floating.exit,
                    ),
                    const SizedBox(height: 4),
                    if (visibleMetrics.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.max,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < visibleMetrics.length; i++) ...[
                            Expanded(child: visibleMetrics[i]),
                            if (i != visibleMetrics.length - 1)
                              const SizedBox(width: 18),
                          ],
                        ],
                      ),
                    if (floating.showChart) ...[
                      const SizedBox(height: 10),
                      Expanded(
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: _FloatingChartPainter(
                            provider.chartData,
                            showVoltage: floating.showVoltage,
                            showCurrent: floating.showCurrent,
                            showPower: floating.showPower,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );

        if (floating.locked) return hud;
        return DragToResizeArea(
          resizeEdgeSize: 10,
          resizeEdgeColor: Colors.transparent,
          child: hud,
        );
      },
    );
  }
}

class _HudControls extends StatelessWidget {
  final bool locked;
  final VoidCallback onToggleLock;
  final VoidCallback onSettings;
  final VoidCallback onRestore;

  const _HudControls({
    required this.locked,
    required this.onToggleLock,
    required this.onSettings,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    const buttonSize = 26.0;
    final iconColor = Colors.white.withAlpha(0xB8);

    return SizedBox(
      height: buttonSize,
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HudIconButton(
              tooltip: locked ? 'Unlock HUD' : 'Lock HUD',
              icon: locked ? Icons.lock_rounded : Icons.lock_open_rounded,
              color: locked ? AppTheme.setpointYellow : iconColor,
              onPressed: onToggleLock,
            ),
            _HudIconButton(
              tooltip: 'HUD settings',
              icon: Icons.tune_rounded,
              color: iconColor,
              onPressed: onSettings,
            ),
            _HudIconButton(
              tooltip: 'Restore main window',
              icon: Icons.open_in_full_rounded,
              color: iconColor,
              onPressed: onRestore,
            ),
          ],
        ),
      ),
    );
  }
}

class _HudIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  const _HudIconButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 450),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        color: color,
        padding: EdgeInsets.zero,
        splashRadius: 13,
        constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      ),
    );
  }
}

Future<void> _showHudMenu(BuildContext context, Offset position) async {
  final floating = context.read<FloatingWindowController>();
  final screenSize = MediaQuery.sizeOf(context);
  final anchor = position == Offset.zero
      ? Offset(screenSize.width / 2, screenSize.height / 2)
      : position;
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(anchor.dx, anchor.dy, anchor.dx, anchor.dy),
    items: [
      PopupMenuItem<String>(
        value: 'lock',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            floating.locked
                ? Icons.lock_open_rounded
                : Icons.lock_outline_rounded,
            size: 18,
          ),
          title: Text(floating.locked ? 'Unlock HUD' : 'Lock HUD'),
        ),
      ),
      const PopupMenuItem<String>(
        value: 'settings',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.tune_rounded, size: 18),
          title: Text('HUD settings'),
        ),
      ),
      const PopupMenuItem<String>(
        value: 'restore',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.open_in_full_rounded, size: 18),
          title: Text('Restore main window'),
        ),
      ),
    ],
  );
  if (action == 'lock') {
    await floating.toggleLocked();
  }
  if (action == 'settings' && context.mounted) {
    await _showFloatingSettings(context);
  }
  if (action == 'restore') {
    await floating.exit();
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;
  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTheme.digitalLabel.copyWith(
            fontSize: 8,
            letterSpacing: 1.2,
            color: Colors.white.withAlpha(0x80),
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: AppTheme.digitalValue.copyWith(
                  fontSize: 25,
                  color: color,
                  shadows: [
                    Shadow(color: color.withAlpha(0x66), blurRadius: 9),
                  ],
                ),
              ),
              const SizedBox(width: 3),
              Text(
                unit,
                style: AppTheme.digitalValue.copyWith(
                  fontSize: 11,
                  color: color.withAlpha(0xBB),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FloatingChartPainter extends CustomPainter {
  final List<PowerSupplyData> data;
  final bool showVoltage;
  final bool showCurrent;
  final bool showPower;

  _FloatingChartPainter(
    this.data, {
    required this.showVoltage,
    required this.showCurrent,
    required this.showPower,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) {
      return;
    }

    final visible = <({Color color, double Function(PowerSupplyData) value})>[
      if (showVoltage)
        (color: AppTheme.voltGreen, value: (d) => d.outputVoltage),
      if (showCurrent)
        (color: AppTheme.currentBlue, value: (d) => d.outputCurrent),
      if (showPower) (color: AppTheme.powerPurple, value: (d) => d.outputPower),
    ];
    for (final line in visible) {
      final values = data.map(line.value).toList(growable: false);
      var minValue = values.reduce(math.min);
      var maxValue = values.reduce(math.max);
      final range = maxValue - minValue;
      if (range < 0.001) {
        final pad = math.max(maxValue.abs() * 0.08, 0.1);
        minValue -= pad;
        maxValue += pad;
      } else {
        final pad = range * 0.12;
        minValue -= pad;
        maxValue += pad;
      }
      final path = Path();
      for (var i = 0; i < values.length; i++) {
        final x = size.width * i / (values.length - 1);
        final normalized = (values[i] - minValue) / (maxValue - minValue);
        final point = Offset(x, size.height - normalized * size.height);
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      final glow = Paint()
        ..color = line.color.withAlpha(0x35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(path, glow);
      final stroke = Paint()
        ..color = line.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(path, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _FloatingChartPainter oldDelegate) =>
      oldDelegate.data.length != data.length ||
      (data.isNotEmpty &&
          oldDelegate.data.last.timestamp != data.last.timestamp) ||
      oldDelegate.showVoltage != showVoltage ||
      oldDelegate.showCurrent != showCurrent ||
      oldDelegate.showPower != showPower;
}

Future<void> _showFloatingSettings(BuildContext context) async {
  final floating = context.read<FloatingWindowController>();
  await showDialog<void>(
    context: context,
    builder: (_) => _FloatingSettingsDialog(controller: floating),
  );
}

class _FloatingSettingsDialog extends StatefulWidget {
  final FloatingWindowController controller;
  const _FloatingSettingsDialog({required this.controller});

  @override
  State<_FloatingSettingsDialog> createState() =>
      _FloatingSettingsDialogState();
}

class _FloatingSettingsDialogState extends State<_FloatingSettingsDialog> {
  late bool _voltage = widget.controller.showVoltage;
  late bool _current = widget.controller.showCurrent;
  late bool _power = widget.controller.showPower;
  late bool _chart = widget.controller.showChart;
  late double _opacity = widget.controller.opacity;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bgPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withAlpha(0x22)),
      ),
      title: Row(
        children: [
          const Icon(
            Icons.tune_rounded,
            size: 19,
            color: AppTheme.setpointYellow,
          ),
          const SizedBox(width: 8),
          Text(
            'Floating window',
            style: AppTheme.digitalValue.copyWith(fontSize: 16),
          ),
        ],
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _switchRow(
              'Voltage',
              _voltage,
              (v) => setState(() => _voltage = v),
            ),
            _switchRow(
              'Current',
              _current,
              (v) => setState(() => _current = v),
            ),
            _switchRow('Power', _power, (v) => setState(() => _power = v)),
            _switchRow(
              'Trend chart',
              _chart,
              (v) => setState(() => _chart = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  'Opacity',
                  style: AppTheme.bodyMono.copyWith(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _opacity,
                    min: 0.55,
                    max: 1.0,
                    divisions: 9,
                    label: '${(_opacity * 100).round()}%',
                    onChanged: (v) => setState(() => _opacity = v),
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(_opacity * 100).round()}%',
                    style: AppTheme.bodyMono.copyWith(
                      fontSize: 11,
                      color: AppTheme.setpointYellow,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.voltGreen,
            foregroundColor: Colors.black,
          ),
          onPressed: () async {
            await widget.controller.applySettings(
              voltage: _voltage,
              current: _current,
              power: _power,
              chart: _chart,
              windowOpacity: _opacity,
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile.adaptive(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        label,
        style: AppTheme.bodyMono.copyWith(
          fontSize: 12,
          color: AppTheme.textSecondary,
        ),
      ),
      value: value,
      onChanged: onChanged,
      activeThumbColor: AppTheme.voltGreen,
    );
  }
}
