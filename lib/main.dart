import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'providers/power_supply_provider.dart';
import 'services/serial_modbus_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure the desktop window.
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(1024, 640));
  await windowManager.setSize(const Size(1360, 800));
  await windowManager.setTitle('RIDEN Power Supply');
  await windowManager.center();
  await windowManager.show();

  // Real Modbus RTU connection to the RIDEN power supply.
  final modbusService = SerialModbusService();

  runApp(
    ChangeNotifierProvider(
      create: (_) => PowerSupplyProvider(modbusService),
      child: const PowerSupplyApp(),
    ),
  );
}
