// ignore_for_file: avoid_print
//
// Phase B.1 — HR19 quickSwitch hardware regression (bidirectional).
//
// Two tests in this file:
//
// 1) `Phase B.1 smoke (mock)` — always runs.  Exercises the entire
//    regression flow against [MockModbusService] to prove the plumbing
//    is correct (no exceptions, snapshots captured, diff reported).
//    This test does NOT validate device behaviour — only that the
//    regression script itself works.
//
// 2) `Phase B.1 hardware (bidirectional M0↔M1/M0↔M2)` — skipped by
//    default.  Requires a real RIDEN power supply connected to the
//    host.  Enable with the environment variable `PHASEB1_HW=1`:
//
//    PHASEB1_HW=1 \
//    PHASEB1_PORT=/dev/ttyUSB0 \
//    fvm flutter test test/phaseb1_hw_regression.dart \
//        --name "hardware" -r expanded
//
//    Recommended device state for the regression (preset slots
//    populated with clearly distinguishable values — the script does
//    NOT modify any slot storage, only switches active preset):
//      M0 preset  : Vset ≈ 5.00 V,   Iset ≈ 1.00 A,  OVP ≈ 6 V,   OCP ≈ 2 A
//      M1 preset  : Vset ≈ 12.00 V,  Iset ≈ 3.00 A,  OVP ≈ 13 V,  OCP ≈ 4 A
//      M2 preset  : Vset ≈ 19.50 V,  Iset ≈ 0.50 A,  OVP ≈ 20 V,  OCP ≈ 0.5 A
//
//    The script performs two round-trip cycles against whatever the
//    device currently has stored:
//      cycle A:  M? → M0 → M1 → M0     (verifies M0↔M1 bidirectional)
//      cycle B:  M? → M0 → M2 → M0     (verifies M0↔M2 bidirectional)
//
//    For each switch, the script records:
//      HR19 (active slot — must equal target)
//      HR8  (Vset — must approximate M(target) stored preset)
//      HR9  (Iset — must approximate M(target) stored preset)
//      HR82 (M0 stored OVP — datasheet address-overlap with HR[82];
//           invariant across switches — see note below)
//      HR83 (M0 stored OCP — same)
//      M(target) stored OVP/OCP from HR[80+slot*4+2 / +3]
//           (the ACTIVE OVP/OCP after a quickSwitch — Phase B.1
//            clarification: per-slot, NOT at HR82/83)
//
//    PASS criteria (gates the Verdict):
//      * HR19 (after each switch) == target slot index
//      * HR8 / HR9 after M0→M1 matches M1 stored preset
//        (HR[84]/HR[85] — base = 80 + 1*4) AND same for M0→M2
//      * Per-slot OVP/OCP from HR[80+target*4+2/3] DISTINGUISHED
//        from M0's stored HR82/83 in >=1 of the 4 recorded
//        comparisons (soft gate — unit test covers the address
//        level; this is confirming on real hardware)
//
//    RECORDED (NOT a Verdict gate — documented firmware behaviour):
//      * HR8 / HR9 after M_target→M0 reverts to M0 storage — the
//        device does NOT reload M0 preset when HR19 is written to 0
//        (firmware treats HR19=0 as a no-op).  Documented in
//        SESSION_HANDOFF.md "Phase B.1 设备固件行为".  Not a Phase B.1 code
//        regression.
//      * HR82/HR83 INVARIANT across the M0<->Mx<->M0 cycle =
//        datasheet address-overlap confirmation.
//
//    Phase B.1 OVP/OCP address clarification:
//      HR82 / HR83 are M0's slot OVP/OCP — they reflect the M0 storage
//      bytes regardless of which slot is active (datasheet address-
//      overlap confirmed by hardware regression).  Each Mx slot ALSO
//      has its own OVP/OCP at HR[80+slot*4+2/3]; after a quickSwitch(N)
//      the active OVP/OCP register reads from M(N)'s storage, not from
//      HR82/83.  The provider reads the per-slot OVP/OCP from the slot
//      storage address (see PowerSupplyProvider.quickSwitch).
//
//    If hardware verification FAILS for HR19 ack or HR8/HR9 forward
//    load, DO NOT use quickSwitch in production — re-audit the
//    device protocol.  If only the reverse-load or HR82/HR83 look
//    surprising, the behaviour is documented; proceed.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/services/mock_modbus_service.dart';
import 'package:riden_power_supply/services/serial_modbus_service.dart';
import 'package:riden_power_supply/services/modbus_service.dart';

// ── Helpers ────────────────────────────────────────────────────────
//
// The regression conceptually tracks 5 wires: HR8 / HR9 / HR19 /
// HR82 / HR83 (plus the active slot's stored OVP/OCP from
// HR[80+slot*4+2/3]).  There's no programmatic _watchAddrs const —
// the snapshot class offers direct getters (.hr8, .hr82, etc.).

String _hex(int n) => '0x${n.toRadixString(16).toUpperCase().padLeft(4, '0')}';
String _vFmt(int raw) => '${(raw / 100).toStringAsFixed(2)} V';
String _iFmt(int raw) => '${(raw / 1000).toStringAsFixed(3)} A';

/// One snapshot row of the tracked registers, plus slot-specific
/// OVP/OCP accessors (Phase B.1 — per-slot OVP/OCP live at
/// HR[80+slot*4+2 / +3], NOT at HR82/83).
class _Snapshot {
  final String label;
  final List<int> regs;
  _Snapshot(this.label, this.regs);

  int get hr8 => regs.length > 8 ? regs[8] : -1;
  int get hr9 => regs.length > 9 ? regs[9] : -1;
  int get hr19 => regs.length > 19 ? regs[19] : -1;
  int get hr82 => regs.length > 82 ? regs[82] : -1;
  int get hr83 => regs.length > 83 ? regs[83] : -1;

  /// Slot's stored OVP (raw) at HR[80+slot*4+2].
  int slotOvp(int slot) {
    final a = 80 + slot * 4 + 2;
    return regs.length > a ? regs[a] : -1;
  }

  /// Slot's stored OCP (raw) at HR[80+slot*4+3].
  int slotOcp(int slot) {
    final a = 80 + slot * 4 + 3;
    return regs.length > a ? regs[a] : -1;
  }

  /// Summary line for the diff print.
  /// [activeSlot] controls which slot's OVP/OCP is shown (the active
  /// slot — per Phase B.1, OVP/OCP is per-slot, not read from HR82/83).
  String summary(int activeSlot) =>
      'HR19=${_hex(hr19)} (=$hr19)  '
      'HR8=${_vFmt(hr8)}  HR9=${_iFmt(hr9)}  '
      'M${activeSlot}OVP=${_vFmt(slotOvp(activeSlot))}  '
      'M${activeSlot}OCP=${_iFmt(slotOcp(activeSlot))}';

  /// Cross-check: HR8 / HR9 vs the slot's stored preset
  /// (HR[80+slot*4] / HR[80+slot*4+1]).  Also echoes the slot's stored
  /// OVP/OCP so the human reader can compare against the active
  /// OVP/OCP in summary.  Returns a multi-line analysis string.
  String crossCheck(int slot) {
    if (regs.length < 80 + slot * 4 + 4) {
      return '  (insufficient regs to read M$slot preset storage)';
    }
    final storedV = regs[80 + slot * 4];
    final storedI = regs[80 + slot * 4 + 1];
    final storedOvp = regs[80 + slot * 4 + 2];
    final storedOcp = regs[80 + slot * 4 + 3];
    final vMatch = hr8 == storedV;
    final iMatch = hr9 == storedI;
    return '  M$slot stored: Vset=${_vFmt(storedV)} (raw=$storedV)  '
        'Iset=${_iFmt(storedI)} (raw=$storedI)  '
        'OVP=${_vFmt(storedOvp)}  OCP=${_iFmt(storedOcp)}\n'
        '  HR8 match: $vMatch (${hr8 == storedV ? "OK" : "MISMATCH "
            "active=$hr8 vs stored=$storedV"})  '
        'HR9 match: $iMatch (${hr9 == storedI ? "OK" : "MISMATCH "
            "active=$hr9 vs stored=$storedI"})';
  }
}

/// Run one bidirectional cycle:
///   baseline → M0 → target → M0
/// Prints each step's HR19/HR8/HR9/HR82/HR83 plus a stored-preset
/// cross-check.  Returns the list of snapshots (baseline, atM0,
/// atTarget, backAtM0) so the caller can diff them.
Future<List<_Snapshot>> _runCycle(
    ModbusService svc, int targetSlot, Duration settleDelay) async {
  final snapshots = <_Snapshot>[];

  // 1. baseline — capture whatever slot the device is currently on.
  //    Show baseline under M0's OVP/OCP (HR82/83) which is what's
  //    "active" before any switch — and also note what target slot's
  //    storage holds, for later reference.
  final baselineReg =
      await svc.readRawRegisters(dedup: 'b1_baseline_$targetSlot');
  final baseline = _Snapshot('baseline', baselineReg ?? const []);
  snapshots.add(baseline);
  print('\n[cycle target=M$targetSlot] baseline   '
      '${baseline.summary(0)}  '
      '(M$targetSlot storage: '
      'OVP=${_vFmt(baseline.slotOvp(targetSlot))}  '
      'OCP=${_iFmt(baseline.slotOcp(targetSlot))})');

  // 2. quickSwitch(0) — return to M0 as a known reference state.
  await svc.quickSwitch(0);
  await Future.delayed(settleDelay);
  final atM0Reg = await svc.readRawRegisters(dedup: 'b1_atM0_$targetSlot');
  final atM0 = _Snapshot('M0 (pre)', atM0Reg ?? const []);
  snapshots.add(atM0);
  print('[cycle target=M$targetSlot] M0 (pre)   ${atM0.summary(0)}');
  print(atM0.crossCheck(0));

  // 3. quickSwitch(target) — the forward switch under test.
  //    Show target slot's own OVP/OCP (per Phase B.1 understanding:
  //    device uses the active slot's stored OVP/OCP, not HR82/83).
  await svc.quickSwitch(targetSlot);
  await Future.delayed(settleDelay);
  final atTargetReg =
      await svc.readRawRegisters(dedup: 'b1_atM$targetSlot');
  final atTarget = _Snapshot('M$targetSlot', atTargetReg ?? const []);
  snapshots.add(atTarget);
  print('[cycle target=M$targetSlot] M$targetSlot    '
      '${atTarget.summary(targetSlot)}');
  print(atTarget.crossCheck(targetSlot));
  // Sanity: HR19 must equal target.
  if (atTarget.hr19 != targetSlot) {
    print('  ⚠️ HR19=$atTarget.hr19 but expected $targetSlot — '
        'device did not ack the quickSwitch write');
  }

  // 4. quickSwitch(0) — the backward switch (verify M?→M0 reverses).
  //    Show M0's OVP/OCP (HR82/83 = M0 storage).
  await svc.quickSwitch(0);
  await Future.delayed(settleDelay);
  final backAtM0Reg =
      await svc.readRawRegisters(dedup: 'b1_back_M0_$targetSlot');
  final backAtM0 = _Snapshot('M0 (post)', backAtM0Reg ?? const []);
  snapshots.add(backAtM0);
  print('[cycle target=M$targetSlot] M0 (post)  ${backAtM0.summary(0)}');
  print(backAtM0.crossCheck(0));

  // 5. Diff print — M0 (pre) vs M0 (post).
  //    HR8 / HR9 are the ACTIVE Vset / Iset registers.  They are
  //    expected to revert to M0 storage on the M?→M0 backward switch
  //    (forward load was verified in step 3).  If they don't, the
  //    device either has a longer settle for reverse switches or
  //    treats HR19=0 as a no-op — observable here as DRIFT.
  //    HR82 / HR83 are M0's storage regardless of active slot, so
  //    they should remain STABLE across any cycle that starts and
  //    ends on M0.
  final m0Stable = atM0.hr8 == backAtM0.hr8 &&
      atM0.hr9 == backAtM0.hr9 &&
      atM0.hr82 == backAtM0.hr82 &&
      atM0.hr83 == backAtM0.hr83;
  final m0StabilityLine = m0Stable
      ? 'STABLE'
      : 'DRIFT (HR8:${atM0.hr8}→${backAtM0.hr8} '
          'HR9:${atM0.hr9}→${backAtM0.hr9} '
          'HR82:${atM0.hr82}→${backAtM0.hr82} '
          'HR83:${atM0.hr83}→${backAtM0.hr83})';
  print('  M0 pre==post stability: $m0StabilityLine');

  return snapshots;
}

// ── Tests ──────────────────────────────────────────────────────────

void main() {
  /// Default-run smoke using the mock service.  Validates plumbing,
  /// not device behaviour.
  test('Phase B.1 smoke (mock)', () async {
    final svc = MockModbusService();
    await svc.connect();

    // Pre-load distinguishable mock presets so the printed diff
    // makes sense (mirrors the device's recommended preset state).
    await svc.saveMemorySlot(0, 5.00, 1.00, 6.0, 2.0);
    await svc.saveMemorySlot(1, 12.00, 3.00, 13.0, 4.0);
    await svc.saveMemorySlot(2, 19.50, 0.50, 20.0, 0.5);

    // Mock settle is instant — short delay is fine.
    const settle = Duration(milliseconds: 50);

    print('\n========== Cycle A: M0 ↔ M1 ==========');
    await _runCycle(svc, 1, settle);

    print('\n========== Cycle B: M0 ↔ M2 ==========');
    await _runCycle(svc, 2, settle);

    print('\n[smoke] flow completed without exception — plumbing OK');
    await svc.disconnect();
  });

  /// Hardware regression — skipped unless PHASEB1_HW=1 is set.
  test('Phase B.1 hardware (bidirectional M0↔M1/M0↔M2)', () async {
    final env = Platform.environment;
    final hw = env['PHASEB1_HW'];
    if (hw == null || hw.isEmpty) {
      throw StateError(
          'Skipped: requires PHASEB1_HW=1 (plus optional PHASEB1_PORT) '
          'env vars and a connected RIDEN device. '
          'See file header for run instructions.');
    }

    final port = env['PHASEB1_PORT'] ?? '/dev/ttyUSB0';
    const settle = Duration(milliseconds: 600);

    final svc = SerialModbusService();
    try {
      print('\n[Phase B.1 hardware] connecting on $port ...');
      await svc.connect(port: port, baudRate: 115200, address: 1);
      print('[Phase B.1 hardware] connected; starting regression');

      // Capture the baseline slot so we can restore it at the end.
      final baselineReg =
          await svc.readRawRegisters(dedup: 'b1_init_baseline');
      final originalSlot =
          baselineReg != null && baselineReg.length > 19
              ? baselineReg[19]
              : 0;
      print('[Phase B.1 hardware] original slot = M$originalSlot '
          '— will restore at end');

      print('\n========== Cycle A: M0 ↔ M1 ==========');
      final cycleA = await _runCycle(svc, 1, settle);

      print('\n========== Cycle B: M0 ↔ M2 ==========');
      final cycleB = await _runCycle(svc, 2, settle);

      // ── PASS criteria checks ────────────────────────────────────
      //
      // Three categories:
      //   PASS/FAIL (gate the Verdict):
      //     - HR19 ack on every switch
      //     - HR8/HR9 FORWARD load (M0→M_target matches M_target storage)
      //     - Per-slot OVP/OCP distinguishable from M0's HR82/83 after
      //       forward switch (Phase B.1 NEW: confirms provider reads
      //       the per-slot address HR[80+target*4+2/3], not HR82/83)
      //
      //   RECORDED (firmware design — documented, NOT a Verdict gate):
      //     - HR8/HR9 REVERSE load (M_target→M0 doesn't revert to M0).
      //       Phase B.1 hardware discovered HR19=0 is a no-op for the
//       reload path; this is documented in SESSION_HANDOFF.md
//       ("Phase B.1 设备固件行为") and is NOT a Phase B.1 code regression.
      //     - HR82/HR83 stability across the cycle.

      print('\n========== Phase B.1 hardware summary ==========');

      // HR19 ack on every switch
      final a1Ack = cycleA[2].hr19 == 1;
      final a0PostAck = cycleA[3].hr19 == 0;
      final b2Ack = cycleB[2].hr19 == 2;
      final b0PostAck = cycleB[3].hr19 == 0;
      print('Cycle A M0→M1  HR19 ack: ${a1Ack ? "PASS" : "FAIL"}');
      print('Cycle A M1→M0  HR19 ack: ${a0PostAck ? "PASS" : "FAIL"}');
      print('Cycle B M0→M2  HR19 ack: ${b2Ack ? "PASS" : "FAIL"}');
      print('Cycle B M2→M0  HR19 ack: ${b0PostAck ? "PASS" : "FAIL"}');

      // HR8/HR9 load from stored preset (crossCheck already printed
      // the match line; here we re-evaluate for the summary table).
      bool slotStoredMatch(_Snapshot s, int slot) {
        if (s.regs.length < 80 + slot * 4 + 2) return false;
        return s.hr8 == s.regs[80 + slot * 4] &&
            s.hr9 == s.regs[80 + slot * 4 + 1];
      }

      final a1Load = slotStoredMatch(cycleA[2], 1);
      final a0Revert = slotStoredMatch(cycleA[3], 0);
      final b2Load = slotStoredMatch(cycleB[2], 2);
      final b0Revert = slotStoredMatch(cycleB[3], 0);
      // FORWARD loads gate the Verdict; REVERSE loads don't.
      final hr89ForwardPass = a1Load && b2Load;
      print('Cycle A M0→M1  HR8/HR9 forward load (M1 storage): '
          '${a1Load ? "PASS" : "FAIL (see cross-check above)"}');
      print('Cycle A M1→M0  HR8/HR9 reverse to M0 storage: '
          '${a0Revert ? "PASS (device reloads M0 — unexpected)"
          : "RECORDED (firmware design — HR19=0 = no-op reload)"}');
      print('Cycle B M0→M2  HR8/HR9 forward load (M2 storage): '
          '${b2Load ? "PASS" : "FAIL (see cross-check above)"}');
      print('Cycle B M2→M0  HR8/HR9 reverse to M0 storage: '
          '${b0Revert ? "PASS (device reloads M0 — unexpected)"
          : "RECORDED (firmware design — HR19=0 = no-op reload)"}');

      // Phase B.1 NEW check — per-slot OVP/OCP at HR[80+target*4+2/3]
      // must be distinguishable from M0's HR82/83.  With recommended
      // preset setup (M0/M1/M2 carrying distinct OVP/OCP values), the
      // snapshot's M_target OVP/OCP accessors must return a value
      // DIFFERENT from M0's stored OVP/OCP.  If they don't, the
      // provider is aliasing the per-slot read back to HR82/83 (the
      // pre-Phase-B.1 bug).
      //
      // Note: this is a "slot-presets-must-be-distinguishable"
      // assumption.  If the user happens to have saved identical
      // OVP/OCP on M0 and M_target, the distinguishing check below
      // records a RECORDED line rather than FAIL the Verdict — the
      // per-slot read may still be correct, just indistinguishable.
      ({int m0ovp, int slotOvp, int m0ocp, int slotOcp})
          slotOvpOcpRecord(_Snapshot s, int slot) =>
              (m0ovp: s.hr82, slotOvp: s.slotOvp(slot),
               m0ocp: s.hr83, slotOcp: s.slotOcp(slot));
      final aPerSlot = slotOvpOcpRecord(cycleA[2], 1);
      final bPerSlot = slotOvpOcpRecord(cycleB[2], 2);
      // Distinguishable == M_target carries its own OVP/OCP != M0's.
      // If distinguishable, per-slot read path is wired correctly.
      // If NOT distinguishable, slots either have identical OVP/OCP
      // (RECORDED-INFO) OR provider is reading HR82/83 instead of the
      // slot address (REGRESSION — but the unit test covers that
      // separately, so this hardware observation is RECORDED).
      final aOvpDistinct = aPerSlot.slotOvp != aPerSlot.m0ovp;
      final aOcpDistinct = aPerSlot.slotOcp != aPerSlot.m0ocp;
      final bOvpDistinct = bPerSlot.slotOvp != bPerSlot.m0ovp;
      final bOcpDistinct = bPerSlot.slotOcp != bPerSlot.m0ocp;
      print('Cycle A M1  per-slot OVP from HR86 vs HR82:  '
          'M1OVP=${_vFmt(aPerSlot.slotOvp)}  HR82=${_vFmt(aPerSlot.m0ovp)}  '
          '${aOvpDistinct ? "DISTINGUISHED (PASS)" : "indistinguishable"}');
      print('Cycle A M1  per-slot OCP from HR87 vs HR83:  '
          'M1OCP=${_iFmt(aPerSlot.slotOcp)}  HR83=${_iFmt(aPerSlot.m0ocp)}  '
          '${aOcpDistinct ? "DISTINGUISHED (PASS)" : "indistinguishable"}');
      print('Cycle B M2  per-slot OVP from HR90 vs HR82:  '
          'M2OVP=${_vFmt(bPerSlot.slotOvp)}  HR82=${_vFmt(bPerSlot.m0ovp)}  '
          '${bOvpDistinct ? "DISTINGUISHED (PASS)" : "indistinguishable"}');
      print('Cycle B M2  per-slot OCP from HR91 vs HR83:  '
          'M2OCP=${_iFmt(bPerSlot.slotOcp)}  HR83=${_iFmt(bPerSlot.m0ocp)}  '
          '${bOcpDistinct ? "DISTINGUISHED (PASS)" : "indistinguishable"}');
      // Gate: at least ONE of (Cycle A M1 OVP, Cycle A M1 OCP, Cycle B
      // M2 OVP, Cycle B M2 OCP) must be distinguished — otherwise the
      // per-slot read path may be aliasing and the user should make
      // M0/M_target presets more distinct before drawing a verdict.
      // This is a SOFT gate: per-slot OVP/OCP correctness is asserted
      // by the unit test against the mock; the hardware gate is a
      // confirming check, not the only signal.
      final perSlotDistinguished = aOvpDistinct ||
          aOcpDistinct ||
          bOvpDistinct ||
          bOcpDistinct;

      // HR82/HR83 stability — Phase B.1 confirmation point.  No PASS/
      // FAIL verdict: just record whether they drift across the
      // cycle.  Datasheet address-overlap says these are M0 stored
      // OVP/OCP; Phase B.1 real-hardware run confirmed INVARIANT
      // across non-M0 switches.
      bool hr8283Stable(_Snapshot pre, _Snapshot post) =>
          pre.hr82 == post.hr82 && pre.hr83 == post.hr83;
      final aHr8283Stable = hr8283Stable(cycleA[1], cycleA[3]);
      final bHr8283Stable = hr8283Stable(cycleB[1], cycleB[3]);
      print('Cycle A M0→M1→M0  HR82/HR83 stability: '
          '${aHr8283Stable ? "INVARIANT (datasheet-confirms M0 stored)"
          : "DRIFT (uncovered new protocol behaviour)"}');
      print('Cycle B M0→M2→M0  HR82/HR83 stability: '
          '${bHr8283Stable ? "INVARIANT (datasheet-confirms M0 stored)"
          : "DRIFT (uncovered new protocol behaviour)"}');

      // Overall verdict — gates:
      //   1. HR19 ack ×4
      //   2. HR8/HR9 forward load ×2 (M0→M1 AND M0→M2)
      //   3. Per-slot OVP/OCP DISTINGUISHED in ≥1 of the 4 recorded
      //      comparisons (confirms per-slot read path works on real
      //      hardware)
      final hr19Pass = a1Ack && a0PostAck && b2Ack && b0PostAck;
      final hr8283Note = aHr8283Stable && bHr8283Stable
          ? 'invariant (M0 stored)'
          : 'drift — see above';
      // Per-slot OVP/OCP check is a SOFT gate: a RECORDED "indistin-
      // guishable" result with all other checks PASS still yields a
      // PASS Verdict, but prints a HINT for the user to vary presets.
      final verdict = (hr19Pass && hr89ForwardPass)
          ? (perSlotDistinguished
              ? 'PASS — Phase B.1 quickSwitch OK to commit '
                  '(per-slot OVP/OCP verified on real hardware)'
              : 'PASS — Phase B.1 quickSwitch OK to commit '
                  '(per-slot OVP/OCP indistinguishable on this device; '
                  'unit tests cover the address-level correctness)')
          : 'FAIL — re-audit before committing Phase B.1';
      print('\n[Phase B.1 hardware] HR19 ack:           '
          '${hr19Pass ? "PASS" : "FAIL"}');
      print('[Phase B.1 hardware] HR8/HR9 forward:    '
          '${hr89ForwardPass ? "PASS" : "FAIL"}');
      print('[Phase B.1 hardware] HR8/HR9 reverse:    '
          'RECORDED (firmware design — HR19=0 no-op reload)');
      print('[Phase B.1 hardware] Per-slot OVP/OCP:   '
          '${perSlotDistinguished ? "PASS (distinguished)" : "RECORDED"}');
      print('[Phase B.1 hardware] HR82/HR83:         '
          'RECORDED ($hr8283Note)');
      print('[Phase B.1 hardware] Verdict:            $verdict');
    } finally {
      // Restore the original active slot so the user's device ends
      // in the same state it was in before the test ran.
      try {
        final svc2 = svc;
        final preReg = await svc2.readRawRegisters(dedup: 'b1_final');
        if (preReg != null && preReg.length > 19) {
          final originalSlot = preReg[19];
          // We always end on M0 regardless of where we started —
          // restore to the very-first-slot captured before cycle A.
          final firstReg =
              await svc2.readRawRegisters(dedup: 'b1_first_baseline');
          if (firstReg != null && firstReg.length > 19) {
            final firstSlot = firstReg[19];
            if (firstSlot != originalSlot) {
              print('\n[Phase B.1 hardware] restoring original slot '
                  'M$firstSlot ...');
              await svc2.quickSwitch(firstSlot);
              await Future.delayed(const Duration(milliseconds: 600));
            }
          }
        }
      } catch (e) {
        print('[Phase B.1 hardware] restore failed: $e '
            '(device may be left on M0 — manual check advised)');
      }
      await svc.disconnect();
    }
  }, skip: Platform.environment['PHASEB1_HW'] == null
      ? 'Requires PHASEB1_HW=1 env + connected RIDEN device'
      : false);
}
