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
  // every target.
  //
  // Android UI mode: prefer portrait (matching the user's mental
  // model of "phone oscilloscope&display"), and use edge-to-edge so
  // the app draws under the translucent system bars — the status
  // bar's icons overlay the chart's top padding (Scaffold +
  // MediaQuery.padding already expose SafeArea so no content is
  // occluded).  Other orientations are NOT locked, so swivel-chair
  // users (e.g. phone clamped on a tilt stand) can rotate freely.
  if (!Platform.isAndroid) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(1024, 640));
    await windowManager.setSize(const Size(1360, 800));
    await windowManager.setTitle('RIDEN Power Supply');
    await windowManager.center();
    await windowManager.show();
  } else {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // 让内容延伸到状态栏 / 导航栏底层，应用占全屏；状态栏图标透明覆盖
    // 在 chart 上方，Scaffold + SafeArea 自动避开 occlusion。
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
    // 透明 status bar / navigation bar，让 Chart 渐变 / 背景色渗透：
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
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
