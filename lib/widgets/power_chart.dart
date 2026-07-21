import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/power_supply_data.dart';
import '../providers/power_supply_provider.dart';
import '../theme/app_theme.dart';

class PowerChart extends StatefulWidget {
  const PowerChart({super.key});

  @override
  State<PowerChart> createState() => _PowerChartState();
}

class _PowerChartState extends State<PowerChart> {
  double _vMin = 0, _vMax = 5;
  double _cMin = 0, _cMax = 2;
  int _vShrinkTicks = 0, _cShrinkTicks = 0;
  static const int _shrinkDelay = 20;

  @override
  Widget build(BuildContext context) {
    return Consumer<PowerSupplyProvider>(
      builder: (context, provider, _) {
        final series = provider.chartData;
        return Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 2, 4),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: _buildChart(series),
          ),
        );
      },
    );
  }

  // ── Chart ──────────────────────────────────────────────────────

  Widget _buildChart(List<PowerSupplyData> series) {
    if (series.isEmpty) {
      return Center(child: Text('Waiting for data…', style: AppTheme.bodyMono));
    }

    final n = series.length;
    final vRaw = <double>[], cRaw = <double>[];
    double vDataMin = double.infinity, vDataMax = double.negativeInfinity;
    double cDataMin = double.infinity, cDataMax = double.negativeInfinity;

    for (int i = 0; i < n; i++) {
      final v = series[i].outputVoltage, c = series[i].outputCurrent;
      vRaw.add(v); cRaw.add(c);
      if (v < vDataMin) vDataMin = v; if (v > vDataMax) vDataMax = v;
      if (c < cDataMin) cDataMin = c; if (c > cDataMax) cDataMax = c;
    }

    _updateRange(vDataMin, vDataMax, _vMin, _vMax, _vShrinkTicks,
        (v) => _vMin = v, (v) => _vMax = v, (v) => _vShrinkTicks = v);
    _updateRange(cDataMin, cDataMax, _cMin, _cMax, _cShrinkTicks,
        (v) => _cMin = v, (v) => _cMax = v, (v) => _cShrinkTicks = v);

    final vMin = _snapDown(_vMin - 0.3);
    final vMax = _snapUp(_vMax + 0.3);
    final vRange = vMax - vMin;
    final cMin = _snapDown(_cMin - 0.02.clamp(0, double.infinity));
    final cMax = _snapUp(_cMax + 0.02);
    final cRange = (cMax - cMin) > 0 ? (cMax - cMin) : 0.1;

    const double dt = 0.25;
    final voltSpots = <FlSpot>[], currSpots = <FlSpot>[];
    for (int i = 0; i < n; i++) {
      final x = (i - n + 1) * dt;
      voltSpots.add(FlSpot(x, vRaw[i]));
      currSpots.add(FlSpot(x, vMin + (cRaw[i] - cMin) / cRange * vRange));
    }

    final vInterval = _niceInterval(vRange);

    // Fixed 60 s window — scale never changes.
    const double windowSecs = 60;
    const double xMin = -windowSecs;
    const double xMax = 0;
    const double tInterval = 10;

    return LineChart(
      LineChartData(
        minX: xMin,
        maxX: xMax,
        minY: vMin,
        maxY: vMax,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawHorizontalLine: true,
          drawVerticalLine: true,
          horizontalInterval: vInterval,
          verticalInterval: 10,
          getDrawingHorizontalLine: (value) => FlLine(
            color: AppTheme.textDim.withAlpha(0x88),
            strokeWidth: 0.5,
          ),
          getDrawingVerticalLine: (value) => FlLine(
            color: AppTheme.textDim.withAlpha(0x66),
            strokeWidth: 0.5,
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: AppTheme.textDim.withAlpha(0xAA), width: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            axisNameWidget: Text('Time (s)', style: AppTheme.bodyMono.copyWith(fontSize: 9, color: AppTheme.textSecondary)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 16,
              interval: tInterval,
              getTitlesWidget: (value, meta) =>
                  Text('${value.toInt()}',
                      style: AppTheme.bodyMono.copyWith(fontSize: 9, color: AppTheme.textSecondary)),
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: Text('V',
                style: AppTheme.bodyMono.copyWith(fontSize: 10, color: AppTheme.voltGreen)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: vInterval,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(1),
                style:
                    AppTheme.bodyMono.copyWith(fontSize: 10, color: AppTheme.voltGreen),
              ),
            ),
          ),
          rightTitles: AxisTitles(
            axisNameWidget: Text('A',
                style: AppTheme.bodyMono.copyWith(fontSize: 10, color: AppTheme.currentBlue)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: vInterval,
              getTitlesWidget: (value, meta) => Text(
                (cMin + (value - vMin) / vRange * cRange).toStringAsFixed(2),
                style: AppTheme.bodyMono.copyWith(
                    fontSize: 10, color: AppTheme.currentBlue),
              ),
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppTheme.bgCard.withAlpha(0xEE),
            getTooltipItems: (touched) {
              return touched.map((t) {
                if (t.barIndex == 0) {
                  return LineTooltipItem(
                    '${t.y.toStringAsFixed(2)} V',
                    const TextStyle(
                        color: AppTheme.voltGreen, fontSize: 14, fontWeight: FontWeight.w700),
                  );
                } else {
                  final cVal = cMin + (t.y - vMin) / vRange * cRange;
                  return LineTooltipItem(
                    '${cVal.toStringAsFixed(3)} A',
                    const TextStyle(
                        color: AppTheme.currentBlue, fontSize: 14, fontWeight: FontWeight.w700),
                  );
                }
              }).toList();
            },
          ),
        ),
        lineBarsData: [
          _makeLine(voltSpots, AppTheme.voltGreen),
          _makeLine(currSpots, AppTheme.currentBlue),
        ],
      ),
      duration: Duration.zero,
    );
  }

  // ── Range hysteresis ───────────────────────────────────────────

  void _updateRange(
    double dMin, double dMax,
    double curMin, double curMax, int ticks,
    ValueSetter<double> setMin, ValueSetter<double> setMax, ValueSetter<int> setTicks,
  ) {
    bool changed = false;
    if (dMin < curMin) { setMin(dMin); setTicks(0); changed = true; }
    if (dMax > curMax) { setMax(dMax); setTicks(0); changed = true; }
    if (!changed) {
      if (ticks >= _shrinkDelay) { setMin(dMin); setMax(dMax); setTicks(0); }
      else { setTicks(ticks + 1); }
    }
  }

  double _snapDown(double v) {
    if (v <= 0) return 0;
    final mag = pow(10, (log(v) / ln10).ceil()).toDouble();
    return (v / (mag / 10)).floorToDouble() * (mag / 10);
  }

  double _snapUp(double v) {
    if (v <= 0) return 0.1;
    final mag = pow(10, (log(v) / ln10).ceil()).toDouble();
    return (v / (mag / 10)).ceilToDouble() * (mag / 10);
  }

  // ── Line ───────────────────────────────────────────────────────

  LineChartBarData _makeLine(List<FlSpot> spots, Color color) {
    return LineChartBarData(
      spots: spots,
      isCurved: true,
      curveSmoothness: 0.15,
      preventCurveOverShooting: true,
      color: color,
      barWidth: 2.0,
      isStrokeCapRound: true,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withAlpha(0x55), color.withAlpha(0x08)],
        ),
      ),
    );
  }

  double _niceInterval(double range) {
    if (range <= 0) return 1;
    final rough = range / 4;
    final magnitude = pow(10, (log(rough) / ln10).floor()).toDouble();
    final residual = rough / magnitude;
    return residual <= 1.5 ? 1.0 : residual <= 3 ? 2.0 : residual <= 7 ? 5.0 : 10.0;
  }
}
