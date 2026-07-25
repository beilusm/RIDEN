import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'providers/power_supply_provider.dart';
import 'services/serial_modbus_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Phase 4 — Desktop-only window manager.  Android has no desktop
  // window API; calling windowManager would throw on the platform
  // channel.  Guard the call so the same main.dart compiles for
  // every target.  On Android we instead lock the orientation to
  // landscape (the chart + sidebar layout assumes ≥640 logical px
  // wide).
  if (!Platform.isAndroid) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(1024, 640));
    await windowManager.setSize(const Size(1360, 800));
    await windowManager.setTitle('RIDEN Power Supply');
    await windowManager.center();
    await windowManager.show();
  } else {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  // Real Modbus RTU connection to the RIDEN power supply.  On Android
  // the connection auto-resolves a CH340 via usb_serial instead of
  // libserialport — see `serial_backend.dart::_AndroidUsbBackend`.
  final modbusService = SerialModbusService();

  runApp(
    ChangeNotifierProvider(
      create: (_) => PowerSupplyProvider(modbusService),
      child: const PowerSupplyApp(),
    ),
  );
}
