import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'providers/power_supply_provider.dart';
import 'services/direct_android_modbus_service.dart';
import 'services/modbus_service.dart';
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
    // Phase 4 fix — 用户期望状态栏彻底隐藏（沉浸模式），不是
    // edgeToEdge 的透明覆盖。`immersiveSticky` 让状态栏 / 导航栏
    // 默认隐藏；用户从屏幕边缘向内滑会临时显示（"sticky" 部分），
    // 短暂停留后再次自动隐藏。
    // 之前的 edgeToEdge 模式只让状态栏透明覆盖在 chart 上，状态栏
    // 图标（时间 / 电池）仍然一直可见，违反用户期望。
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
    );
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
  }

  // Real Modbus RTU connection to the RIDEN power supply.
  //
  // Phase 4 — Android path uses [DirectAndroidModbusService]:
  // usb_serial platform channels can't route replies to a worker
  // isolate (Flutter 3.44 BackgroundIsolateBinaryMessenger + usb_serial
  // FATAL `did_send`); the async platform channel awaits don't block
  // the UI isolate, so the worker-isolate invariant is not violated
  // (the invariant targets synchronous FFI like libserialport, not
  // async channels).
  //
  // Desktop path keeps [SerialModbusService] with worker isolate +
  // libserialport FFI (as before).
  final ModbusService modbusService = Platform.isAndroid
      ? DirectAndroidModbusService()
      : SerialModbusService();

  runApp(
    ChangeNotifierProvider(
      create: (_) => PowerSupplyProvider(modbusService),
      child: const PowerSupplyApp(),
    ),
  );
}
