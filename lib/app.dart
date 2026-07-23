import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/power_supply_provider.dart';
import 'theme/app_theme.dart';
import 'widgets/power_chart.dart';
import 'widgets/dashboard_panel.dart';
import 'widgets/register_page.dart';

class PowerSupplyApp extends StatelessWidget {
  const PowerSupplyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RIDEN Power Supply',
      debugShowCheckedModeBanner: false,
      navigatorKey: AppTheme.navigatorKey,
      theme: AppTheme.darkTheme,
      home: const PowerSupplyShell(),
    );
  }
}

class PowerSupplyShell extends StatefulWidget {
  const PowerSupplyShell({super.key});

  @override
  State<PowerSupplyShell> createState() => _PowerSupplyShellState();
}

class _PowerSupplyShellState extends State<PowerSupplyShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // App boot: arm the auto-scan timer so the app keeps probing
      // for a CH340 every ~400ms while no device is connected.
      // Tick guards (`_connected || _connecting`) make subsequent
      // ticks no-op once a real handshake lands.
      //
      // User-initiated disconnect() stops the timer entirely so the
      // user's explicit disconnect is honoured.  Worker crash (P1-2)
      // leaves the timer alive → next tick relights connect() → the
      // app auto-recovers from yanked-USB / device reboot without
      // requiring a manual button press.
      try {
        context.read<PowerSupplyProvider>().startAutoScan();
      } catch (e) {
        debugPrint('startAutoScan error: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final showReg = context.watch<PowerSupplyProvider>().showRegisters;
    if (showReg) return const Scaffold(body: RegisterPage());

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 900;
          if (isWide) {
            return Row(children: [
              const Expanded(flex: 80, child: PowerChart()),
              Container(width: 1, color: AppTheme.borderSubtle),
              const Expanded(flex: 20, child: DashboardPanel()),
            ]);
          } else {
            return Column(children: [
              const Expanded(flex: 60, child: PowerChart()),
              Container(height: 1, color: AppTheme.borderSubtle),
              const Expanded(flex: 40, child: DashboardPanel()),
            ]);
          }
        },
      ),
    );
  }
}
