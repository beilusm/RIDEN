import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/power_supply_provider.dart';
import '../theme/app_theme.dart';

/// Serial connection settings card: port / baud rate / Modbus address,
/// plus a Connect / Disconnect button.
///
/// Stylistically mirrors [SetpointPanel]: same section header style,
/// same row layout, same dialog edit pattern.
class SerialPanel extends StatefulWidget {
  const SerialPanel({super.key});

  @override
  State<SerialPanel> createState() => _SerialPanelState();
}

class _SerialPanelState extends State<SerialPanel> {
  String? _port;
  int _baudRate = 115200;
  int _address = 1;
  List<String> _ports = const [];
  bool _portsLoaded = false;

  static const List<int> _baudOptions = [
    9600,
    19200,
    38400,
    57600,
    115200,
    230400,
    460800,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshPorts());
  }

  Future<void> _refreshPorts() async {
    final ports = await context.read<PowerSupplyProvider>().listPorts();
    if (!mounted) return;
    setState(() {
      _ports = ports;
      _portsLoaded = true;
      if (_port == null && ports.isNotEmpty) _port = ports.first;
    });
  }

  // ── Pickers ────────────────────────────────────────────────────────

  Future<void> _choosePort() async {
    await _refreshPorts();
    if (!mounted || _ports.isEmpty) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Select Port',
            style: AppTheme.digitalValue.copyWith(fontSize: 16)),
        content: SizedBox(
          width: 320,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _ports.length,
            itemBuilder: (_, i) {
              final p = _ports[i];
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text(p,
                    style: AppTheme.digitalValue.copyWith(
                        fontSize: 13,
                        color: p == _port
                            ? AppTheme.setpointYellow
                            : AppTheme.textSecondary)),
                onTap: () => Navigator.pop(c, p),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, null),
              child: const Text('Cancel')),
        ],
      ),
    );
    if (picked != null) setState(() => _port = picked);
  }

  Future<void> _chooseBaud() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Baud Rate',
            style: AppTheme.digitalValue.copyWith(fontSize: 16)),
        content: SizedBox(
          width: 240,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _baudOptions.length,
            itemBuilder: (_, i) {
              final b = _baudOptions[i];
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('$b',
                    style: AppTheme.digitalValue.copyWith(
                        fontSize: 13,
                        color: b == _baudRate
                            ? AppTheme.setpointYellow
                            : AppTheme.textSecondary)),
                onTap: () => Navigator.pop(c, b),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, null),
              child: const Text('Cancel')),
        ],
      ),
    );
    if (picked != null) setState(() => _baudRate = picked);
  }

  void _editAddress(int cur) {
    final ctrl = TextEditingController(text: '$cur');
    void commit() {
      final v = int.tryParse(ctrl.text);
      if (v != null) setState(() => _address = v.clamp(1, 247));
      Navigator.pop(context);
    }

    void spin(bool up) {
      final v = (int.tryParse(ctrl.text) ?? cur) + (up ? 1 : -1);
      ctrl.text = v.clamp(1, 247).toString();
    }

    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Edit Address',
            style: AppTheme.digitalValue.copyWith(fontSize: 16)),
        content: SizedBox(
          width: 200,
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                style: AppTheme.digitalValue.copyWith(
                    fontSize: 22, color: AppTheme.setpointYellow),
                onSubmitted: (_) => commit(),
              ),
            ),
            const SizedBox(width: 8),
            Column(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                onPressed: () => spin(true),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 24, minHeight: 24,
                    maxWidth: 24, maxHeight: 24),
                style: IconButton.styleFrom(backgroundColor: AppTheme.bgInput),
              ),
              const SizedBox(height: 4),
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                onPressed: () => spin(false),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 24, minHeight: 24,
                    maxWidth: 24, maxHeight: 24),
                style: IconButton.styleFrom(backgroundColor: AppTheme.bgInput),
              ),
            ]),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.voltGreen,
                foregroundColor: Colors.black),
            onPressed: commit,
            child: const Text('Set'),
          ),
        ],
      ),
    );
  }

  // ── Connect action ──────────────────────────────────────────────────

  Future<void> _doConnect(PowerSupplyProvider p) async {
    try {
      await p.connect(port: _port, baudRate: _baudRate, address: _address);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Connect failed: $e'),
        backgroundColor: AppTheme.errorRed,
        duration: const Duration(seconds: 3),
      ));
    }
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Consumer<PowerSupplyProvider>(
      builder: (context, p, _) {
        final connected = p.connected;
        final connecting = p.connecting;
        final activePort = connected ? (p.connectedPort ?? _port) : _port;
        final activeBaud = connected ? p.baudRate : _baudRate;
        final activeAddr = connected ? p.address : _address;

        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _sectionHeader('SERIAL'),
              const SizedBox(height: 6),
              _row(
                context,
                'Port',
                activePort ?? (!_portsLoaded ? '—' : '(none)'),
                connected ? null : _choosePort,
                AppTheme.currentBlue,
              ),
              const SizedBox(height: 3),
              _row(
                context,
                'Baud',
                '$activeBaud',
                connected ? null : _chooseBaud,
                AppTheme.currentBlue,
              ),
              const SizedBox(height: 3),
              _row(
                context,
                'Addr',
                activeAddr.toString().padLeft(2, '0'),
                connected ? null : () => _editAddress(activeAddr),
                AppTheme.currentBlue,
              ),
              const SizedBox(height: 8),
              _connectButton(p, connected, connecting),
            ],
          ),
        );
      },
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  Widget _sectionHeader(String t) {
    return Text(t,
        style: AppTheme.digitalLabel.copyWith(fontSize: 9, letterSpacing: 2));
  }

  Widget _row(BuildContext ctx, String label, String value,
      VoidCallback? onTap, Color color) {
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
                width: 56,
                child: Text(label,
                    style: AppTheme.bodyMono.copyWith(fontSize: 11))),
            const Spacer(),
            Text(value,
                style: AppTheme.digitalValue.copyWith(
                    fontSize: 14,
                    color: disabled ? AppTheme.textDim : color)),
            const SizedBox(width: 4),
            Icon(Icons.edit,
                size: 10,
                color: AppTheme.textDim
                    .withAlpha(disabled ? 0x44 : 0xFF)),
          ],
        ),
      ),
    );
  }

  Widget _connectButton(
      PowerSupplyProvider p, bool connected, bool connecting) {
    final color = connected ? AppTheme.errorRed : AppTheme.voltGreen;
    final label =
        connecting ? 'CONNECTING…' : (connected ? 'DISCONNECT' : 'CONNECT');
    return GestureDetector(
      onTap: connecting
          ? null
          : () async {
              if (connected) {
                await p.disconnect();
              } else {
                await _doConnect(p);
              }
            },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: color.withAlpha(connected ? 0x18 : 0x22),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withAlpha(0x88), width: 1.2),
        ),
        alignment: Alignment.center,
        child: connecting
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: color))
            : Text(label,
                style: AppTheme.digitalValue.copyWith(
                    fontSize: 13,
                    color: color,
                    letterSpacing: 2)),
      ),
    );
  }
}
