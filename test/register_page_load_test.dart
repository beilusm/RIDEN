import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:riden_power_supply/providers/power_supply_provider.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';
import 'package:riden_power_supply/widgets/register_page.dart';
import 'package:riden_power_supply/models/register_definition.dart';

/// Smoke test: RegisterPage builds and renders the full register
/// table (121 rows) without exceptions, driven by MockModbusService.
void main() {
  testWidgets('RegisterPage renders 121 rows with 0xXXXX addresses',
      (tester) async {
    final service = MockModbusService();
    await service.connect();

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => PowerSupplyProvider(service),
        child: const MaterialApp(home: Scaffold(body: RegisterPage())),
      ),
    );

    // Let the first _poll() future + timers flush.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Header should be present.
    expect(find.text('REGISTER VIEWER'), findsOneWidget);

    // First row address rendered as 0x0000 (HR0 = Model ID).
    expect(find.text('0x0000'), findsOneWidget);

    // A datasheet-confirmed entry name should be visible.
    expect(find.text('Model ID'), findsOneWidget);

    // Scroll down to confirm later confirmed rows render too.
    await tester.drag(
        find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();

    // Total register definitions still 121.
    expect(RegisterTable.all.length, 121);

    await service.disconnect();
  });
}
