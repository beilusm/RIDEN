import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/power_supply_provider.dart';
import '../theme/app_theme.dart';

/// Full-page register table.  Continuously reads HR[0-120], shows
/// each register with edit button for writable ones.
class RegisterView extends StatefulWidget {
  const RegisterView({super.key});

  @override
  State<RegisterView> createState() => _RegisterViewState();
}

class _RegisterViewState extends State<RegisterView> {
  List<int>? _prev;
  List<int>? _data;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final raw = await context.read<PowerSupplyProvider>().fullPollRaw();
    if (raw != null && mounted) {
      setState(() {
        _prev = _data;
        _data = raw;
      });
    }
  }

  void _edit(int idx, int cur) {
    final ctrl = TextEditingController(text: '$cur');
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Write HR[$idx]', style: AppTheme.digitalValue.copyWith(fontSize: 16)),
        content: SizedBox(
          width: 200,
          child: TextField(
            controller: ctrl, autofocus: true,
            keyboardType: TextInputType.number,
            style: AppTheme.digitalValue.copyWith(fontSize: 20, color: AppTheme.setpointYellow),
            onSubmitted: (_) { _commit(idx, ctrl.text, c); },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.voltGreen, foregroundColor: Colors.black),
            onPressed: () => _commit(idx, ctrl.text, c),
            child: const Text('Write'),
          ),
        ],
      ),
    );
  }

  void _commit(int idx, String text, BuildContext ctx) {
    final v = int.tryParse(text);
    if (v != null && v >= 0 && v <= 65535) {
      context.read<PowerSupplyProvider>().writeRawRegister(idx, v);
    }
    Navigator.pop(ctx);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.bgDarkest,
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: AppTheme.bgPanel,
          child: Row(children: [
            Text('REGISTERS  HR[0-120]', style: AppTheme.digitalValue.copyWith(fontSize: 15)),
            if (_data != null)
              Text('  ${_data!.length} regs', style: AppTheme.bodyMono.copyWith(fontSize: 11)),
            const Spacer(),
            _hdrChip(Icons.refresh, 'Polling 500ms', AppTheme.voltGreen, () => _poll()),
            const SizedBox(width: 8),
            _hdrChip(Icons.dashboard, 'Dashboard', AppTheme.textSecondary,
                () => context.read<PowerSupplyProvider>().toggleRegView()),
          ]),
        ),
        // Column headers
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          color: AppTheme.bgCard,
          child: const Row(children: [
            SizedBox(width: 52, child: Text('Reg', style: _hdrStyle)),
            SizedBox(width: 42, child: Text('R/W', style: _hdrStyle)),
            Expanded(child: Text('Decimal', style: _hdrStyle)),
            SizedBox(width: 100, child: Text('Hex', style: _hdrStyle)),
            SizedBox(width: 120, child: Text('Note', style: _hdrStyle)),
            SizedBox(width: 40),
          ]),
        ),
        // Table body
        Expanded(
          child: _data == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: _data!.length,
                  itemBuilder: (_, i) => _row(i, _data![i]),
                ),
        ),
      ]),
    );
  }

  static const _hdrStyle = TextStyle(fontFamily: 'Noto Sans CJK SC', fontSize: 10, color: AppTheme.textDim);

  Widget _hdrChip(IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: AppTheme.bodyMono.copyWith(fontSize: 11, color: color)),
      ]),
    );
  }

  Widget _row(int idx, int val) {
    final changed = _prev != null && idx < _prev!.length && _prev![idx] != val;
    final rw = _isRW(idx);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: changed ? AppTheme.setpointYellow.withAlpha(0x14) : null,
        border: Border(bottom: BorderSide(color: AppTheme.borderSubtle.withAlpha(0x33))),
      ),
      child: Row(children: [
        SizedBox(width: 52, child: Text('HR[$idx]', style: AppTheme.bodyMono.copyWith(fontSize: 10, color: changed ? AppTheme.setpointYellow : AppTheme.textDim))),
        SizedBox(width: 42, child: Text(rw ? 'RW' : 'RO', style: AppTheme.bodyMono.copyWith(fontSize: 9, color: rw ? AppTheme.warningOrange : AppTheme.textDim))),
        Expanded(child: Text('$val', style: AppTheme.digitalValue.copyWith(fontSize: 12, color: changed ? AppTheme.setpointYellow : AppTheme.textPrimary))),
        SizedBox(width: 100, child: Text('0x${val.toRadixString(16).padLeft(4, '0').toUpperCase()}', style: AppTheme.bodyMono.copyWith(fontSize: 10, color: AppTheme.textSecondary))),
        SizedBox(width: 120, child: Text(_note(idx), style: AppTheme.bodyMono.copyWith(fontSize: 9, color: AppTheme.textDim), overflow: TextOverflow.ellipsis)),
        if (rw)
          SizedBox(width: 40, child: GestureDetector(
            onTap: () => _edit(idx, val),
            child: const Icon(Icons.edit, size: 14, color: AppTheme.textDim),
          )),
      ]),
    );
  }

  bool _isRW(int idx) {
    const rw = {8, 9, 18, 72, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119};
    return rw.contains(idx);
  }

  String _note(int idx) {
    const n = {
      0: 'Model ID', 5: 'Temp °C', 8: 'Vset×100', 9: 'Iset×1000',
      10: 'Vout×100', 11: 'Iout×1000', 14: 'InputV×100', 17: 'CC=1/CV=0',
      18: 'Out on/off', 39: 'mAh', 41: 'mWh', 72: 'Backlight',
      82: 'OVP×100', 83: 'OCP×1000',
    };
    if (idx >= 80 && idx <= 119) {
      final s = (idx - 80) ~/ 4;
      final f = ['Vset', 'Iset', 'OVP', 'OCP'][(idx - 80) % 4];
      return 'M$s $f';
    }
    return n[idx] ?? '';
  }
}
