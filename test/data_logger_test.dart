// ignore_for_file: directives_ordering
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riden_power_supply/models/power_snapshot.dart';
import 'package:riden_power_supply/services/data_logger.dart';

/// Phase E — unit tests for [DataLogger] + [RecordingSession].
///
/// The DataLogger is a pure consumer of [PowerSnapshot] events: it
/// issues no Modbus reads, spawns no worker, touches no scheduler,
/// owns no timer.  Rows are written event-driven via [DataLogger.record]
/// — the provider calls it once per `_onData` (every waveform refresh,
/// FAST ~150ms + SLOW ~1000ms).  [IOSink] buffers writes internally,
/// so FAST cadence does not translate to per-call disk syncs.
///
/// Test strategy:
///   * Real filesystem, injected via [DataLogger.recordingDirFactory]
///     pointing at a temp directory created in setUp — avoids the
///     path_provider platform channel (unavailable in `flutter_test`
///     without `PathProviderFoundation` host setup).
///   * Fully synchronous [record] calls — no `Timer.periodic`, so no
///     wall-clock waits.  File content is asserted after [stop], which
///     `await sink.flush()` then `await sink.close()` — by the time
///     stop() resolves, bytes are on disk and `File.readAsString`
///     returns the canonical content.  The whole file runs in well
///     under a second.
///   * The "record armed before device connects" user scenario
///     (start() called while no device is streaming) is exercised by
///     starting the logger and calling [stop] without any [record]
///     calls in between — the file must contain only the header.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('riden_logger_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DataLogger — initial session state', () {
    test('a fresh logger reports an idle RecordingSession', () {
      final logger = DataLogger();
      final s = logger.session;
      expect(s.isRecording, isFalse);
      expect(s.startTime, isNull);
      expect(s.stopTime, isNull);
      expect(s.filePath, isNull);
      expect(s.sampleCount, 0);
    });
  });

  group('DataLogger.start', () {
    test('flips isRecording + stamps startTime + opens file under injected dir',
        () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      final before = DateTime.now();
      final session = await logger.start();
      expect(session.isRecording, isTrue);
      expect(session.sampleCount, 0,
          reason: 'sampleCount is 0 until the first record() call');
      expect(session.startTime, isNotNull);
      expect(session.startTime!.isAfter(before), isTrue);
      expect(session.filePath, isNotNull);
      expect(session.filePath!, startsWith(tempDir.path),
          reason: 'file is opened under the injected recording dir so '
              'tests never touch the platform\'s application support '
              'directory');
      expect(session.filePath!, contains('riden_recording_'));
      expect(session.filePath!, endsWith('.csv'));
      await logger.stop();
    });

    test('writes the CSV header as the first line of the file', () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      await logger.start();
      await logger.stop();
      final content = await File(logger.session.filePath!).readAsString();
      // First line (before any newline) must be the header.
      expect(content.split('\n').first, _csvHeader,
          reason: 'start writes the header before any record() call; '
              'stop flushes it to disk so it\'s visible via readAsString.');
    });

    test('start while recording is a no-op (returns the same session)',
        () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      final first = await logger.start();
      final second = await logger.start();
      expect(identical(second, first), isTrue,
          reason: 'second start() must short-circuit and return the '
              'in-progress session — no duplicate file is opened');
      await logger.stop();
    });
  });

  group('DataLogger.start({filePath}) — user-selected Save path', () {
    test('honours an explicit filePath (does not consult recordingDirFactory)',
        () async {
      // The Save dialog path: the user picks an absolute path, the
      // panel forwards it to the provider which forwards it here.
      // start() must openWrite() at exactly that path and not call
      // _recordingDirFactory at all — if it did, the recordingDirFactory
      // here would throw and the test would fail loudly.
      final userDir =
          await Directory.systemTemp.createTemp('riden_user_picked');
      final userPath =
          '${userDir.path}${Platform.pathSeparator}my_session.csv';
      // Pass an explicit recordingDirFactory that ALWAYS throws so we
      // can prove start({filePath}) bypasses it.  (Production passes
      // no factory at all, but proving the bypass requires the guard
      // to actually not invoke the factory.)
      Future<Directory> throwingFactory() =>
          Future.error(StateError('recordingDirFactory must NOT be '
              'consulted when filePath is provided'));
      final logger = DataLogger(recordingDirFactory: throwingFactory);
      final session = await logger.start(filePath: userPath);
      expect(session.filePath, userPath,
          reason: 'session.filePath must be the exact path the user '
              'picked; recorder does NOT rename or relocate the file');
      expect(session.isRecording, isTrue);
      logger.record(_snap(slot: 7));
      await logger.stop();
      // The file exists at the user-picked path with header + 1 row.
      expect(File(userPath).existsSync(), isTrue);
      final lines = (await File(userPath).readAsString()).trim().split('\n');
      expect(lines.length, 2);
      expect(lines.first, _csvHeader);
      expect(lines.last.split(',').last, '7');
      await userDir.delete(recursive: true);
    });

    test('creates missing parent directory of the user path (recursive)',
        () async {
      // The Save dialog on most platforms refuses non-existent parents,
      // so this is defensive — but a user can type an arbitrary path
      // (e.g. an exported SMB mount freshly mounted under ~/mnt/share)
      // and the recorder must not crash on a missing parent dir.
      final userDir =
          await Directory.systemTemp.createTemp('riden_user_nested');
      final userPath =
          '${userDir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}'
          'grand${Platform.pathSeparator}deep_session.csv';
      final logger = DataLogger();
      final session = await logger.start(filePath: userPath);
      expect(session.filePath, userPath);
      await logger.stop();
      expect(File(userPath).existsSync(), isTrue);
      await userDir.delete(recursive: true);
    });
  });

  group('DataLogger.record (event-driven row writer)', () {
    test('record() before start is a no-op (sampleCount stays 0)', () {
      final logger = DataLogger();
      logger.record(_snap(slot: 0));
      expect(logger.session.sampleCount, 0,
          reason: 'record() guards on _sink != null; before start() '
              'the sink is null so the call short-circuits without '
              'bumping sampleCount.  Providers can wire record() '
              'unconditionally into _onData and let the sink guard '
              'own start/stop/dispose semantics.');
      expect(logger.session.isRecording, isFalse);
    });

    test('record() while recording appends a row + increments sampleCount',
        () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      await logger.start();
      expect(logger.session.sampleCount, 0);
      logger.record(_snap(slot: 3));
      expect(logger.session.sampleCount, 1,
          reason: 'one record() call = one CSV row + one sampleCount '
              'increment, synchronously — no timer to fire');
      await logger.stop();
    });

    test('record() N times writes N rows + sampleCount == N exactly',
        () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      await logger.start();
      for (var i = 0; i < 5; i++) {
        logger.record(_snap(slot: i));
      }
      expect(logger.session.sampleCount, 5,
          reason: 'event-driven recording gives an exact 1:1 mapping '
              'between record() calls and rows — no jitter, no missed '
              'or duplicated ticks.  This is the property the user '
              'asked for ("ui波形每刷新都伴随数据记录").');
      await logger.stop();

      final content = await File(logger.session.filePath!).readAsString();
      final lines = content.trim().split('\n');
      // header + 5 data rows.
      expect(lines.length, 6);
      expect(lines.first, _csvHeader);
      // Each per-slot snapshot serialised with its own activeSlot.
      for (var i = 0; i < 5; i++) {
        final cols = lines[i + 1].split(',');
        expect(cols.length, 9);
        expect(cols.last, '$i',
            reason: 'row $i was recorded from _snap(slot: i) so its '
                'trailing activeSlot column must equal "$i"');
      }
    });

    test('record() after stop is a no-op (sampleCount frozen)', () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      await logger.start();
      logger.record(_snap(slot: 1));
      logger.record(_snap(slot: 2));
      await logger.stop();
      final frozenCount = logger.session.sampleCount;
      expect(frozenCount, 2);
      logger.record(_snap(slot: 3)); // ignored — not recording
      expect(logger.session.sampleCount, frozenCount,
          reason: 'post-stop record() must be a no-op so the session '
              'sampleCount stays frozen at its stopped value');
    });

    test('start() with no record() calls leaves a header-only file '
        '(armed before device connects)', () async {
      // The user scenario: startRecording() is pressed while no
      // device is streaming _onData events.  No record() fires; the
      // file must contain only the header row until the first real
      // measurement arrives.
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      await logger.start();
      // Note: no await Future.delayed — event-driven recording needs
      // no timing gap to model "no events arrived"; the absence of
      // record() calls IS the condition.
      await logger.stop();
      final content = await File(logger.session.filePath!).readAsString();
      final lines = content.trim().split('\n');
      expect(lines.length, 1,
          reason: 'a recording armed with zero record() calls yields '
              'a header-only file — sampleCount == 0 and the file is '
              'still valid CSV (one-row header, no data).');
      expect(lines.single, _csvHeader);
      expect(logger.session.sampleCount, 0);
    });

    test('every recorded row matches the 9-column Phase E schema', () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      await logger.start();
      logger.record(_snap(slot: 7));
      await logger.stop();
      final content = await File(logger.session.filePath!).readAsString();
      final lines = content.trim().split('\n');
      expect(lines.length, 2, reason: 'header + one data row');
      final cols = lines.last.split(',');
      expect(cols.length, 9,
          reason: 'Phase E schema: time,voltage,current,power,'
              'inputVoltage,temperature,outputEnable,protectionState,'
              'activeSlot');
      expect(cols.last, '7', reason: 'activeSlot carried from _snap');
      // Trailing-newline note: [IOSink.writeln] appends a newline to
      // every row including the last, so the closed file ends with
      // '\n'.  That's expected CSV behaviour (POSIX text-file
      // convention) and not asserted against — the meaningful
      // invariants are column count and the per-row activeSlot value
      // verified above.
    });
  });

  group('DataLogger.stop', () {
    test('flips isRecording false + stamps stopTime, keeps startTime+filePath',
        () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      final startedAt = await logger.start();
      final beforeStop = DateTime.now();
      final session = await logger.stop();
      expect(session.isRecording, isFalse);
      expect(session.stopTime, isNotNull);
      expect(session.stopTime!.isAfter(beforeStop), isTrue);
      expect(session.startTime, startedAt.startTime,
          reason: 'stop() must not rewrite startTime');
      expect(session.filePath, startedAt.filePath,
          reason: 'stop() must not rewrite filePath');
    });

    test('stop while not recording is a no-op (does not stamp stopTime)',
        () async {
      final logger = DataLogger();
      final session = await logger.stop();
      expect(session.isRecording, isFalse);
      expect(session.stopTime, isNull,
          reason: 'a no-op stop must not stamp a stopTime; this is '
              'distinguishable from a real stop by the nullness of '
              'stopTime, which the UI uses to label "never recorded".');
      expect(session.startTime, isNull);
      expect(session.filePath, isNull);
    });

    test('flushes header + every recorded row to disk', () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      await logger.start();
      logger.record(_snap(slot: 3));
      logger.record(_snap(slot: 3));
      logger.record(_snap(slot: 3));
      await logger.stop();
      // Reopen and read — no locked-file race.
      final content = await File(logger.session.filePath!).readAsString();
      final lines = content.trim().split('\n');
      expect(lines.first, _csvHeader);
      expect(lines.length, 4, reason: 'header + 3 recorded rows');
      // Every data row has the 9-column schema; trailing column is "3".
      for (final line in lines.skip(1)) {
        expect(line.split(',').length, 9);
        expect(line.split(',').last, '3');
      }
    });
  });

  group('DataLogger.dispose', () {
    test('dispose on an idle logger is a no-op and idempotent', () {
      final logger = DataLogger();
      logger.dispose();
      logger.dispose(); // idempotent — second call is a no-op
    });

    test('dispose mid-recording drops the sink without further writes',
        () async {
      final logger = DataLogger(
          recordingDirFactory: () => Future.value(tempDir));
      await logger.start();
      logger.record(_snap(slot: 0));
      logger.record(_snap(slot: 0));
      expect(logger.session.sampleCount, 2);
      // Synchronous close — dispose does NOT await sink.close() so the
      // OS-level flush happens on the next microtask.  We assert the
      // observable state (isRecording still reflects the pre-dispose
      // state; sink is dropped) without waiting on flushes.
      logger.dispose();
      final countAfterDispose = logger.session.sampleCount;
      expect(countAfterDispose, 2,
          reason: 'dispose is a sync close — it must not bump '
              'sampleCount; the two pre-dispose record() calls are '
              'the only counted writes.');
      // record() against the disposed sink is a no-op: _sink is null
      // after dispose, so the guard short-circuits before writeln or
      // the sampleCount increment — preserving the frozen-count
      // invariant without hitting a closed sink.
      logger.record(_snap(slot: 0));
      expect(logger.session.sampleCount, countAfterDispose);
    });
  });

  group('RecordingSession', () {
    test('elapsed is Duration.zero when isRecording is false', () {
      final s = RecordingSession(
        startTime: DateTime.now(),
        isRecording: false,
      );
      expect(s.elapsed, Duration.zero,
          reason: 'elapsed returns zero unless isRecording is true, '
              'even when startTime is non-null');
    });

    test('elapsed is Duration.zero when startTime is null', () {
      const s = RecordingSession(isRecording: true);
      expect(s.elapsed, Duration.zero,
          reason: 'elapsed guards startTime == null to Duration.zero');
    });

    test('elapsed grows with wall-clock when recording', () async {
      final start = DateTime.now();
      final s = RecordingSession(startTime: start, isRecording: true);
      // Drain ~100ms of wall clock — well within CI tolerance.
      await Future.delayed(const Duration(milliseconds: 120));
      expect(s.elapsed.inMilliseconds, greaterThanOrEqualTo(50),
          reason: 'a recording session reports elapsed > ~50ms after '
              '120ms of real time has passed');
    });

    test('copyWith preserves unset fields and overrides only the requested ones',
        () {
      const base = RecordingSession(
        startTime: null,
        stopTime: null,
        filePath: null,
        sampleCount: 0,
        isRecording: false,
      );
      final s1 = base.copyWith(isRecording: true);
      expect(s1.isRecording, isTrue);
      expect(s1.sampleCount, 0,
          reason: 'copyWith leaves sampleCount untouched when not '
              'specified — null-coalescing semantics');

      final s2 = s1.copyWith(sampleCount: 7, filePath: '/tmp/a.csv');
      expect(s2.isRecording, isTrue, reason: 's1.isRecording carries over');
      expect(s2.sampleCount, 7);
      expect(s2.filePath, '/tmp/a.csv');
    });

    test('copyWith default-constructs a RecordingSession with sampleCount=0',
        () {
      // Validate the const default: sampleCount=0, isRecording=false.
      const s = RecordingSession();
      expect(s.sampleCount, 0);
      expect(s.isRecording, isFalse);
    });
  });
}

PowerSnapshot _snap({required int slot}) => PowerSnapshot(
      timestamp: DateTime(2026, 7, 24, 20, 30, 1),
      voltage: 12.01,
      current: 2.53,
      power: 12.01 * 2.53,
      inputVoltage: 24.1,
      temperature: 35.0,
      outputEnable: true,
      protectionState: 0,
      activeSlot: slot,
    );

const String _csvHeader =
    'time,voltage,current,power,inputVoltage,temperature,outputEnable,'
    'protectionState,activeSlot';
