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
      // App boot: arm the USB watcher so the app keeps probing the
      // host's USB port list for a CH340 at 1s cadence WITHOUT
      // spawning a worker or sending Modbus traffic.  When a CH340
      // is observed the watcher calls connect() (which itself
      // re-runs the USB probe synchronously then spawns the
      // worker); when absent the device's serial port stays cold.
      //
      // The watcher stays armed across:
      //   * connect success — tick becomes no-op (the polling
      //     architecture owns keep-alive while _connected).
      //   * worker crash (P1-2) — next tick sees _connected=false
      //     and CH340 present → relights connect.
      //   * user explicit disconnect() — stopUsbWatch() inside
      //     disconnect() cancels the timer so DISCONNECT is honoured.
      //   * watcher-observed unplug — disconnect(stopWatcher: false)
      //     keeps the timer armed so reconnect fires automatically.
      try {
        context.read<PowerSupplyProvider>().startUsbWatch();
      } catch (e) {
        debugPrint('startUsbWatch error: $e');
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
