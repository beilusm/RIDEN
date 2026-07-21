import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/register_conflicts.dart';
import '../models/register_definition.dart';
import '../providers/power_supply_provider.dart';
import '../theme/app_theme.dart';

/// Full-page register viewer.
///
/// Renders a self-describing table of all 121 holding registers
/// (HR[0..120]) using [RegisterTable].  Polls via
/// [PowerSupplyProvider.fullPollRaw] at user priority — does not
/// interfere with the FAST/SLOW polling loops in the worker isolate.
///
/// Confirmed writable rows expose an edit action that opens a small
/// dialog and commits through [PowerSupplyProvider.writeRawRegister].
/// Registers flagged with [RegisterDefinition.conflict] draw a
/// warning badge and refuse to write until the conflict is resolved
/// against the device datasheet (see [RegisterConflicts]).
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  List<int>? _data;
  List<int>? _prev;
  Timer? _timer;
  bool _autoRefresh = true;
  bool _busy = false;

  static const int _pollIntervalMs = 500;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(
      const Duration(milliseconds: _pollIntervalMs),
      (_) {
        if (_autoRefresh && !_busy) _poll();
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_busy) return;
    _busy = true;
    try {
      // dedupKey + expire prevent the scheduler queue from accumulating
      // reads when the device responds slower than [_pollIntervalMs].
      final raw = await context
          .read<PowerSupplyProvider>()
          .fullPollRaw(dedup: 'reg_full', expireMs: 400);
      if (raw != null && mounted) {
        setState(() {
          _prev = _data;
          _data = raw;
        });
      }
    } catch (e) {
      // Defensive: worker converts TaskCancelled/TaskExpired into null
      // results, so reads should never throw here.  Catch anything else
      // (worker death, isolate shutdown) to keep the refresh loop alive.
      debugPrint('[REG页] _poll failed: $e');
    } finally {
      _busy = false;
    }
  }

  void _toggleAutoRefresh() {
    setState(() => _autoRefresh = !_autoRefresh);
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.bgDarkest,
      child: Column(
        children: [
          _header(),
          _columnHeader(),
          Expanded(
            child: _data == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: RegisterTable.all.length,
                    itemBuilder: (_, i) {
                      // Always pull the definition from
                      // [RegisterTable.get]; never synthesise HRxxx
                      // from the address in this widget.  For
                      // in-range addresses [get] always returns a
                      // definition (placeholder when unconfirmed).
                      final def = RegisterTable.get(i);
                      if (def == null) return const SizedBox.shrink();
                      final raw =
                          (i < _data!.length) ? _data![i] : null;
                      final prev = (_prev != null && i < _prev!.length)
                          ? _prev![i]
                          : null;
                      final changed = raw != null && prev != null && raw != prev;
                      return _row(def, raw, changed);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────

  Widget _header() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: AppTheme.bgPanel,
      child: Row(
        children: [
          Text('REGISTER VIEWER',
              style: AppTheme.digitalValue
                  .copyWith(fontSize: 15, letterSpacing: 1.5)),
          if (_data != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('${_data!.length} regs',
                  style: AppTheme.bodyMono.copyWith(fontSize: 11)),
            ),
          const Spacer(),
          _hdrChip(
            icon: _autoRefresh ? Icons.autorenew : Icons.pause_circle_outline,
            label: _autoRefresh ? 'Auto 500ms' : 'Paused',
            color: _autoRefresh ? AppTheme.voltGreen : AppTheme.textDim,
            onTap: _toggleAutoRefresh,
          ),
          const SizedBox(width: 8),
          _hdrChip(
            icon: Icons.refresh,
            label: 'Refresh',
            color: AppTheme.currentBlue,
            onTap: _poll,
          ),
          const SizedBox(width: 8),
          _hdrChip(
            icon: Icons.dashboard,
            label: 'Dashboard',
            color: AppTheme.textSecondary,
            onTap: () =>
                context.read<PowerSupplyProvider>().toggleRegView(),
          ),
        ],
      ),
    );
  }

  Widget _hdrChip(
      {required IconData icon,
      required String label,
      required Color color,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: AppTheme.bodyMono.copyWith(fontSize: 11, color: color)),
        ],
      ),
    );
  }

  // ── Column header ─────────────────────────────────────────────────

  static const _hdrStyle = TextStyle(
    fontFamily: 'Noto Sans CJK SC',
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 1,
    color: AppTheme.textDim,
  );

  Widget _columnHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: AppTheme.bgCard,
      child: const Row(
        children: [
          SizedBox(width: 60, child: Text('ADDR', style: _hdrStyle)),
          SizedBox(width: 120, child: Text('NAME', style: _hdrStyle)),
          SizedBox(width: 110, child: Text('VALUE', style: _hdrStyle)),
          SizedBox(width: 56, child: Text('TYPE', style: _hdrStyle)),
          SizedBox(width: 70, child: Text('ACC', style: _hdrStyle)),
          Expanded(child: Text('NOTE', style: _hdrStyle)),
          SizedBox(width: 50, child: Text('OP', style: _hdrStyle)),
        ],
      ),
    );
  }

  // ── Row ───────────────────────────────────────────────────────────

  Widget _row(RegisterDefinition def, int? raw, bool changed) {
    final isUnknown = def.access == RegisterAccess.unknown &&
        def.type == RegisterType.unknown &&
        def.source == RegisterSource.placeholder;
    final isConflict = def.conflict;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: changed
            ? AppTheme.setpointYellow.withAlpha(0x14)
            : (isConflict
                ? AppTheme.warningOrange.withAlpha(0x08)
                : null),
        border: Border(
          bottom: BorderSide(color: AppTheme.borderSubtle.withAlpha(0x33)),
        ),
      ),
      child: Row(
        children: [
          // ADDR
          SizedBox(
            width: 60,
            child: Text(
              'HR${def.address.toString().padLeft(3, '0')}',
              style: AppTheme.bodyMono.copyWith(
                fontSize: 10,
                color: changed
                    ? AppTheme.setpointYellow
                    : AppTheme.textDim,
              ),
            ),
          ),
          // NAME
          SizedBox(
            width: 120,
            child: Text(
              def.name,
              style: AppTheme.digitalValue.copyWith(
                fontSize: 12,
                color: isUnknown
                    ? AppTheme.textDim
                    : (isConflict
                        ? AppTheme.warningOrange
                        : (def.access == RegisterAccess.rw
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary)),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // VALUE
          SizedBox(
            width: 110,
            child: raw == null
                ? const Text('—',
                    style: TextStyle(
                        fontFamily: 'JetBrainsMono Nerd Font Mono',
                        fontSize: 12,
                        color: AppTheme.textDim))
                : _valueCell(def, raw, changed),
          ),
          // TYPE
          SizedBox(
            width: 56,
            child: Text(
              _typeLabel(def.type),
              style: AppTheme.bodyMono.copyWith(
                  fontSize: 10,
                  color: def.type == RegisterType.unknown
                      ? AppTheme.textDim
                      : AppTheme.textSecondary),
            ),
          ),
          // ACCESS + conflict marker
          SizedBox(
            width: 70,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _accessBadge(def.access),
                if (isConflict) ...[
                  const SizedBox(width: 3),
                  Tooltip(
                    message: 'Conflict — see register_conflicts.dart',
                    child: Icon(Icons.warning_amber,
                        size: 12, color: AppTheme.warningOrange),
                  ),
                ],
              ],
            ),
          ),
          // NOTE
          Expanded(
            child: Text(
              def.description,
              style: AppTheme.bodyMono.copyWith(
                  fontSize: 10,
                  color: isUnknown
                      ? AppTheme.textDim
                      : (isConflict
                          ? AppTheme.warningOrange.withAlpha(0xCC)
                          : AppTheme.textDim)),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          // OP — only confirmed writable rows (no conflict) get an
          // edit action.
          SizedBox(
            width: 50,
            child: def.isWritable
                ? GestureDetector(
                    onTap: () => _editRegister(def, raw ?? 0),
                    child: const Icon(Icons.edit,
                        size: 14, color: AppTheme.setpointYellow),
                  )
                : const Text('—',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: 'JetBrainsMono Nerd Font Mono',
                        fontSize: 12,
                        color: AppTheme.textDim)),
          ),
        ],
      ),
    );
  }

  Widget _valueCell(RegisterDefinition def, int raw, bool changed) {
    final rawColor =
        changed ? AppTheme.setpointYellow : AppTheme.textPrimary;
    if (!def.isScaled) {
      return Text('$raw',
          style: AppTheme.digitalValue
              .copyWith(fontSize: 12, color: rawColor));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$raw',
            style: AppTheme.digitalValue
                .copyWith(fontSize: 12, color: rawColor)),
        Text(def.format(raw),
            style: AppTheme.bodyMono.copyWith(
                fontSize: 9, color: rawColor.withAlpha(0xBB))),
      ],
    );
  }

  static String _typeLabel(RegisterType t) => switch (t) {
        RegisterType.uint16 => 'u16',
        RegisterType.int16 => 'i16',
        RegisterType.bitmap => 'bmp',
        RegisterType.boolean => 'bool',
        RegisterType.enumKind => 'enum',
        RegisterType.unknown => '?',
      };

  Widget _accessBadge(RegisterAccess a) {
    final (label, color) = switch (a) {
      RegisterAccess.rw => ('RW', AppTheme.warningOrange),
      RegisterAccess.ro => ('RO', AppTheme.currentBlue),
      RegisterAccess.unknown => ('?', AppTheme.textDim),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(0x18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(0x66), width: 0.8),
      ),
      child: Text(
        label,
        style: AppTheme.digitalValue.copyWith(
            fontSize: 10, color: color, letterSpacing: 1),
      ),
    );
  }

  // ── Edit dialog ───────────────────────────────────────────────────

  void _editRegister(RegisterDefinition def, int currentRaw) {
    final scaled = def.isScaled;
    final dec = def.decimals;
    final init = scaled
        ? (currentRaw / def.scale).toStringAsFixed(dec)
        : currentRaw.toString();
    final ctrl = TextEditingController(text: init);

    int? parseToRaw(String text) {
      if (scaled) {
        final v = double.tryParse(text);
        if (v == null) return null;
        return (v * def.scale).round().clamp(0, 65535);
      }
      final v = int.tryParse(text);
      if (v == null) return null;
      if (v < 0 || v > 65535) return null;
      return v;
    }

    void commit(BuildContext dialogCtx) {
      final raw = parseToRaw(ctrl.text);
      if (raw != null) {
        context.read<PowerSupplyProvider>().writeRawRegister(
              def.address,
              raw,
            );
      }
      Navigator.pop(dialogCtx);
    }

    void spin(bool up) {
      if (scaled) {
        final cur = double.tryParse(ctrl.text) ?? 0;
        final step = 1.0 / def.scale;
        final next = cur + (up ? step : -step);
        final maxRaw = 65535 / def.scale;
        ctrl.text =
            next.clamp(0, maxRaw).toStringAsFixed(dec);
      } else {
        final cur = int.tryParse(ctrl.text) ?? 0;
        final next = cur + (up ? 1 : -1);
        ctrl.text = next.clamp(0, 65535).toString();
      }
    }

    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit HR${def.address.toString().padLeft(3, '0')}',
              style: AppTheme.digitalValue.copyWith(fontSize: 16),
            ),
            const SizedBox(height: 2),
            Text(def.name,
                style: AppTheme.bodyMono.copyWith(
                    fontSize: 11, color: AppTheme.textSecondary)),
          ],
        ),
        content: SizedBox(
          width: 260,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  style: AppTheme.digitalValue.copyWith(
                      fontSize: 22, color: AppTheme.setpointYellow),
                  onSubmitted: (_) => commit(c),
                ),
              ),
              const SizedBox(width: 6),
              if (def.unit.isNotEmpty)
                Text(def.unit,
                    style: AppTheme.digitalValue.copyWith(fontSize: 16)),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.add, size: 18),
                    onPressed: () => spin(true),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                        maxWidth: 24,
                        maxHeight: 24),
                    style: IconButton.styleFrom(
                        backgroundColor: AppTheme.bgInput),
                  ),
                  const SizedBox(height: 4),
                  IconButton(
                    icon: const Icon(Icons.remove, size: 18),
                    onPressed: () => spin(false),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                        maxWidth: 24,
                        maxHeight: 24),
                    style: IconButton.styleFrom(
                        backgroundColor: AppTheme.bgInput),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.voltGreen,
                foregroundColor: Colors.black),
            onPressed: () => commit(c),
            child: const Text('Write'),
          ),
        ],
      ),
    );
  }
}
