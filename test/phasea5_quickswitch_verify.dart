// ignore_for_file: avoid_print
//
// Phase A.5 — HR19 hardware data-group switch verification.
//
// Two tests in this file:
//
// 1) `Phase A.5 smoke (mock)` — always runs.  Exercises the entire
//    verification flow against [MockModbusService] to prove the
//    plumbing is correct (no exceptions, before/after snapshots
//    captured, diff reported).  This test does NOT validate device
//    behaviour — only that the verification script itself works.
//
// 2) `Phase A.5 hardware (HR19 quickSwitch)` — skipped by default.
//    Requires a real RIDEN power supply connected to the host.
//    Enable with the environment variable `PHASEA5_HW=1`:
//
//    PHASEA5_HW=1 \
//    PHASEA5_PORT=/dev/ttyUSB0 \
//    PHASEA5_SLOT=1 \
//    fvm flutter test test/phasea5_quickswitch_verify.dart \
//        --name "hardware" -r expanded
//
//    Recommended device state for PHASEA5_SLOT=1:
//      M0 preset  : Vset ≈ 5.00 V,  Iset ≈ 1.00 A,  OVP ≈ 6 V,  OCP ≈ 2 A
//      M1 preset  : Vset ≈ 12.00 V, Iset ≈ 3.00 A,  OVP ≈ 13 V, OCP ≈ 4 A
//    (or any pair of clearly distinguishable values)
//
//    The test will:
//      a) read current snapshot (HR0..HR120) — BEFORE
//      b) record current HR19 (active slot)
//      c) call quickSwitch(target slot)
//      d) wait ~600 ms for device to load slot registers
//      e) read fresh snapshot — AFTER
//      f) print a diff table of the key registers
//      g) restore quickSwitch(originalSlot) before disconnecting
//
//    Verification success criteria (user judgement from the printed
//    diff table):
//      * HR19 (after) == target slot index
//      * HR8  (after) approx == M<target> V-Set stored in HR[80+target*4]
//      * HR9  (after) approx == M<target> I-Set stored in HR[80+target*4+1]
//      * HR16 protectionStatus reflects the device's safety status
//
//    If the verification passes run-time on hardware, the next step
//    is to @Deprecate `loadMemorySlot` (NOT in this phase — Phase B).
//
//    If the verification fails on real hardware: do NOT modify UI
//    or remove loadMemorySlot.  Re-audit the device protocol instead.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';
import 'package:riden_power_supply/services/serial_modbus_service.dart';
import 'package:riden_power_supply/services/modbus_service.dart';

// ── Helpers ────────────────────────────────────────────────────────

/// Addresses we care about for the diff report.
const _watchAddrs = [
  8,  // Vset
  9,  // Iset
  15, // KeyLock
  16, // ProtectionStatus
  17, // CC/CV Mode
  18, // Output Enable
  19, // Quick Preset (the one we are testing)
  // M0..M9 presets (HR[80..119], groups of 4)
  80, 81, 82, 83,
  84, 85, 86, 87,
  88, 89, 90, 91,
  92, 93, 94, 95,
  96, 97, 98, 99,
  100, 101, 102, 103,
  104, 105, 106, 107,
  108, 109, 110, 111,
  112, 113, 114, 115,
  116, 117, 118, 119,
];

String _hex(int n) => '0x${n.toRadixString(16).toUpperCase().padLeft(4, '0')}';

String _vsetR(int raw) => '${(raw / 100).toStringAsFixed(2)} V';
String _isetR(int raw) => '${(raw / 1000).toStringAsFixed(3)} A';

/// Prints a before/after diff of the watched registers.
void _printDiff(String label, List<int>? before, List<int>? after) {
  print('\n=== $label ===');
  if (before == null || after == null) {
    print('  (snapshot null — before=${before == null}, after=${after == null})');
    return;
  }
  // Header.
  print('${'ADDR'.padRight(8)} ${'BEFORE'.padRight(10)} ${'AFTER'.padRight(10)} ${'DELTA'.padRight(10)} NOTE');
  for (final addr in _watchAddrs) {
    final b = addr < before.length ? before[addr] : -1;
    final a = addr < after.length ? after[addr] : -1;
    if (b == a && addr != 19) continue; // skip unchanged for brevity
    final delta = a - b;
    String note;
    switch (addr) {
      case 8:
        note = 'Vset  before=${_vsetR(b)} after=${_vsetR(a)}';
        break;
      case 9:
        note = 'Iset  before=${_isetR(b)} after=${_isetR(a)}';
        break;
      case 15:
        note = 'KeyLock {0=未锁定, 1=键盘锁定}';
        break;
      case 16:
        note = 'ProtectionStatus {0=正常, 1=OVP, 2=OCP, 3=OTP}';
        break;
      case 17:
        note = 'CV/CC {0=CV, 1=CC}';
        break;
      case 18:
        note = 'Output {0=关闭, 1=打开}';
        break;
      case 19:
        note = '← Quick Preset M0..M9 (wrote target here)';
        break;
      default:
        if (addr >= 80 && addr <= 119) {
          final slotIdx = (addr - 80) ~/ 4;
          final fieldIdx = (addr - 80) % 4;
          const fields = ['V-Set', 'I-Set', 'OVP', 'OCP'];
          final field = fields[fieldIdx];
          final String Function(int) fmt;
          if (fieldIdx == 0 || fieldIdx == 2) {
            fmt = _vsetR;
          } else {
            fmt = _isetR;
          }
          note = 'M$slotIdx $field  before=${fmt(b)} after=${fmt(a)}';
        } else {
          note = '';
        }
    }
    print('${_hex(addr).padRight(8)} '
        '${'$b'.padRight(10)} '
        '${'$a'.padRight(10)} '
        '${'$delta'.padRight(10)} $note');
  }
}

/// Run the full verification flow against the given service.
Future<void> _runVerification(ModbusService svc, int targetSlot,
    {required Duration settleDelay}) async {
  // 1. Read current snapshot — BEFORE.
  final before = await svc.readRawRegisters(dedup: 'phasea5_before');
  expect(before, isNotNull, reason: 'BEFORE readRawRegisters must return data');
  expect(before!.length, greaterThanOrEqualTo(20),
      reason: 'snapshot must cover at least HR0..HR19');

  final originalSlot = before[19];
  print('\n[Phase A.5] BEFORE quickSwitch($targetSlot): '
      'HR19=${_hex(originalSlot)} (=$originalSlot)  '
      'HR8(setV)=${_vsetR(before[8])}  '
      'HR9(setI)=${_isetR(before[9])}  '
      'HR16(protection)=${before[16]}');

  // Print M0..M9 stored values for reference.
  print('\nStored memory presets (from snapshot):');
  for (int s = 0; s < 10; s++) {
    final base = 80 + s * 4;
    if (base + 3 < before.length) {
      print('  M$s: Vset=${_vsetR(before[base])}  '
          'Iset=${_isetR(before[base + 1])}  '
          'OVP=${_vsetR(before[base + 2])}  '
          'OCP=${_isetR(before[base + 3])}');
    }
  }

  // 2. quickSwitch — write HR[19] = targetSlot.
  await svc.quickSwitch(targetSlot);
  print('\n[Phase A.5] quickSwitch($targetSlot) issued '
      '(writes HR19=${_hex(targetSlot)}=$targetSlot)');

  // 3. Wait for device firmware to load slot registers into the
  //    active setpoints.  600ms is comfortably above the FAST poll
  //    interval (150ms × ~4 cycles) so the next read reflects the
  //    device's settled state, not a mid-transition snapshot.
  await Future.delayed(settleDelay);

  // 4. Read fresh snapshot — AFTER.
  final after = await svc.readRawRegisters(dedup: 'phasea5_after');
  expect(after, isNotNull, reason: 'AFTER readRawRegisters must return data');
  expect(after!.length, greaterThanOrEqualTo(20));

  // 5. Diff report.
  _printDiff('Phase A.5 diff (target slot = $targetSlot)', before, after);

  // 6. Assertion: HR19 must reflect the written slot index in the
  //    AFTER snapshot.
  print('\n[Phase A.5] AFTER  HR19=${_hex(after[19])} (=${after[19]})  '
      'HR8(setV)=${_vsetR(after[8])}  '
      'HR9(setI)=${_isetR(after[9])}  '
      'HR16(protection)=${after[16]}');

  expect(after[19], targetSlot,
      reason: 'HR[19] (after quickSwitch) must equal the target slot index');

  // 7. Cross-check: HR8 should match the stored M<targetSlot> Vset.
  final targetBase = 80 + targetSlot * 4;
  if (targetBase + 1 < after.length) {
    final storedVset = before[targetBase];
    final storedIset = before[targetBase + 1];
    final actVset = after[8];
    final actIset = after[9];
    print('\n[Phase A.5] cross-check: '
        'M$targetSlot V-Set stored = $storedVset (${_vsetR(storedVset)})  '
        '| active HR8 after switch = $actVset (${_vsetR(actVset)})');
    print('[Phase A.5] cross-check: '
        'M$targetSlot I-Set stored = $storedIset (${_isetR(storedIset)})  '
        '| active HR9 after switch = $actIset (${_isetR(actIset)})');
    // We do NOT strict-assert V/I match because the device may apply
    // output-policy clamps (e.g. input voltage under-cut).  The user
    // must inspect the printed values to confirm the protocol.
  }

  // 8. Restore original slot so the device ends in its prior state.
  if (originalSlot != targetSlot) {
    print('\n[Phase A.5] restoring original slot: '
        'quickSwitch($originalSlot)');
    await svc.quickSwitch(originalSlot);
    await Future.delayed(settleDelay);
    final restored = await svc.readRawRegisters(dedup: 'phasea5_restored');
    if (restored != null) {
      print('[Phase A.5] RESTORED  '
          'HR19=${_hex(restored[19])}  '
          'HR8=${_vsetR(restored[8])}  '
          'HR9=${_isetR(restored[9])}');
    }
  }
}

// ── Tests ──────────────────────────────────────────────────────────

void main() {
  /// Default-run smoke test using the mock service.  Validates that
  /// the verification flow itself works (no exceptions, snapshots
  /// captured, diff printed, quickSwitch observable via mock writeRegister).
  test('Phase A.5 smoke (mock)', () async {
    final svc = MockModbusService();
    await svc.connect();

    // Pre-load a distinguishing pair of presets in the mock so the
    // printed diff makes sense.
    await svc.saveMemorySlot(0, 5.00, 1.00, 6.0, 2.0);
    await svc.saveMemorySlot(1, 12.00, 3.00, 13.0, 4.0);
    await svc.saveMemorySlot(2, 19.50, 0.50, 20.0, 1.0);

    await _runVerification(svc, 1, settleDelay: const Duration(milliseconds: 50));

    await svc.disconnect();
  });

  /// Hardware verification — skipped unless PHASEA5_HW=1 is set.
  test('Phase A.5 hardware (HR19 quickSwitch)', () async {
    final env = Platform.environment;
    final hw = env['PHASEA5_HW'];
    if (hw == null || hw.isEmpty) {
      throw StateError(
          'Skipped: requires PHASEA5_HW=1 (plus PHASEA5_PORT and '
          'PHASEA5_SLOT) env vars and a connected RIDEN device. '
          'See file header for run instructions.');
    }

    final port = env['PHASEA5_PORT'] ?? '/dev/ttyUSB0';
    final slot = int.parse(env['PHASEA5_SLOT'] ?? '1');
    if (slot < 0 || slot > 9) {
      throw ArgumentError('PHASEA5_SLOT must be in 0..9, got $slot');
    }

    final svc = SerialModbusService();
    try {
      print('\n[Phase A.5 hardware] connecting on $port ...');
      await svc.connect(port: port, baudRate: 115200, address: 1);
      print('[Phase A.5 hardware] connected; running verification '
          'against slot $slot');

      await _runVerification(svc, slot,
          settleDelay: const Duration(milliseconds: 600));

      print('\n[Phase A.5 hardware] verification complete.  Inspect the '
          'diff table above:');
      print('  ✓ PASS if HR19 (after) == $slot AND HR8/HR9 (after) '
          'match M$slot stored preset.');
      print('  ✗ FAIL if HR19 != $slot OR HR8/HR9 unchanged — '
          'protocol may differ; do NOT deprecate loadMemorySlot.');
    } finally {
      await svc.disconnect();
    }
  }, skip: Platform.environment['PHASEA5_HW'] == null
      ? 'Requires PHASEA5_HW=1 env + connected RIDEN device'
      : false);
}
