import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/power_snapshot.dart';

/// Phase E — recording session metadata exposed to the UI.
///
/// An immutable snapshot of the recording state at a point in
/// time.  Mutated only by [DataLogger] internally; the UI reads
/// fields via the [DataLogger.session] getter and rebuilds when the
/// provider notifies listeners.
class RecordingSession {
  /// Wall-clock time when recording started (set by [DataLogger.start]).
  /// `null` if no recording is active or has ever been active.
  final DateTime? startTime;

  /// Wall-clock time when recording stopped (set by [DataLogger.stop]).
  /// `null` during an active recording; Reset to `null` by a
  /// subsequent [DataLogger.start] call.
  final DateTime? stopTime;

  /// Absolute path of the CSV file being written to.  `null` until a
  /// recording has been started at least once.
  final String? filePath;

  /// Number of CSV data rows written since [startTime].  Header row
  /// is not counted.  Reset to 0 by each [DataLogger.start] call.
  final int sampleCount;

  /// `true` between [DataLogger.start] and [DataLogger.stop].  The
  /// 1Hz writer timer is active iff this is `true`.
  final bool isRecording;

  const RecordingSession({
    this.startTime,
    this.stopTime,
    this.filePath,
    this.sampleCount = 0,
    this.isRecording = false,
  });

  /// Elapsed recording time, or `Duration.zero` if not recording.
  Duration get elapsed =>
      isRecording && startTime != null
          ? DateTime.now().difference(startTime!)
          : Duration.zero;

  RecordingSession copyWith({
    DateTime? startTime,
    DateTime? stopTime,
    String? filePath,
    int? sampleCount,
    bool? isRecording,
  }) =>
      RecordingSession(
        startTime: startTime ?? this.startTime,
        stopTime: stopTime ?? this.stopTime,
        filePath: filePath ?? this.filePath,
        sampleCount: sampleCount ?? this.sampleCount,
        isRecording: isRecording ?? this.isRecording,
      );
}

/// Phase E — CSV recorder consuming [SnapshotStore] at 1Hz cadence.
///
/// Architecture (per Phase E design doc):
///
/// ```
/// Modbus response → RegisterParser → PowerSnapshot
///                                            │
///                                            +--> UI notify
///                                            │
///                                            +--> SnapshotStore
///                                                        │
///                                                        v
///                                                     DataLogger
/// ```
///
/// **Logger is a consumer, not a communication task.**  This class
/// never reads Modbus, never spawns a worker, never touches the
/// scheduler.  Recording is event-driven: the provider calls
/// [record] on every `_onData` (each waveform refresh, FAST ~150ms +
/// SLOW ~1000ms), appending one CSV row per call.  [IOSink] buffers
/// the writes internally so calling [record] at FAST poll cadence
/// does NOT cause 6-7 disk syncs per second — bytes accumulate in
/// the in-memory chunk and flush when the buffer fills or on [stop].
///
/// This ties CSV rows 1:1 with chart points (no missed samples
/// between periodic ticks, no separate sampling timer to keep in
/// sync with the poll loop) while keeping actual disk I/O amortised.
///
/// The CSV column order and row format match the Phase E design
/// doc exactly (see [PowerSnapshot.toCsvRow]).
///
/// Usage:
///   * Construct with no required arguments (no I/O happens).
///   * Call [start] to open a CSV file in the platform's
///     "application support" directory and write the header row.
///   * Call [record] on every waveform refresh while recording.
///   * Call [stop] to flush + close the file.
///   * [dispose] is defensive — closes sink if still open.  Safe to
///     call multiple times.
class DataLogger {
  /// Construct a DataLogger.
  ///
  /// [recordingDirFactory] — optional injection point for tests.
  /// Production leaves it `null` to use the platform's "application
  /// support" directory via `path_provider`.  Tests inject a factory
  /// returning a temporary directory under the system temp so file
  /// I/O is exercised against an actual filesystem without
  /// touching platform channels.
  DataLogger({this._recordingDirFactory});

  final Future<Directory> Function()? _recordingDirFactory;
  IOSink? _sink;
  RecordingSession _session = const RecordingSession();

  /// Current session state.  Read-only — UI rebuilds on provider
  /// notifyListeners, which the provider invokes after [start] /
  /// [stop] / each [record] tick (the logger itself doesn't notify).
  RecordingSession get session => _session;

  /// Begin recording.  Opens a fresh CSV file in the platform's
  /// application support directory under a `recordings/` subfolder
  /// and writes the header row.  No timer is armed — rows are written
  /// by [record], which the provider calls once per `_onData` (every
  /// waveform refresh, FAST ~150ms + SLOW ~1000ms).  [IOSink] buffers
  /// writes internally, so calling [record] at FAST poll cadence does
  /// NOT cause 6-7 disk syncs per second — bytes accumulate in the
  /// sink and flush when the buffer fills or [stop] closes the sink.
  /// This ties CSV rows 1:1 with chart points (no missed samples
  /// between 1Hz ticks) without hitting disk at poll frequency.
  ///
  /// File naming: `riden_recording_<yyyyMMdd_HHmmss>.csv`.  A new
  /// file is created on every [start] call — no overwrite of
  /// previous recordings.
  ///
  /// [filePath] — optional explicit path.  Production passes the
  /// user-selected path from a native Save dialog (see the recording
  /// panel's [FilePicker.platform.saveFile] call).  When `null`,
  /// [start] falls back to the [_recordingDirFactory] / application
  /// support directory and synthesises a timestamped name — the path
  /// exercised by tests.
  ///
  /// Idempotency: calling [start] while [isRecording] is `true` is a
  /// no-op (returns the current [session]).  Calling [start] after
  /// a previous [stop] opens a fresh file and resets [sampleCount]
  /// to 0.
  ///
  /// Returns the updated [RecordingSession].  Throws on filesystem
  /// errors (directory creation / file open) — caller (provider) is
  /// expected to surface those via SnackBar.
  Future<RecordingSession> start({String? filePath}) async {
    if (_session.isRecording) return _session;

    final now = DateTime.now();
    final File file;
    if (filePath != null) {
      file = File(filePath);
      // Ensure the parent directory exists so the user can save to a
      // freshly-created folder without an openWrite() failure.  We
      // only create the immediate parent, not recursive — the Save
      // dialog itself refuses non-existent parents on most platforms,
      // so this is a defensive belt-and-braces against path-canonical
      // edge cases (e.g. Windows \\?\ UNC prefix with intermediate
      // missing segment).
      final parent = file.parent;
      if (!parent.existsSync()) {
        await parent.create(recursive: true);
      }
    } else {
      final dir = await _resolveRecordingDir();
      final stamp = _formatStamp(now);
      file = File('${dir.path}${Platform.pathSeparator}'
          'riden_recording_$stamp.csv');
    }
    _sink = file.openWrite(mode: FileMode.write);
    _writeHeader();
    _session = RecordingSession(
      startTime: now,
      filePath: file.path,
      sampleCount: 0,
      isRecording: true,
    );
    return _session;
  }

  /// Append one measurement row to the CSV, sourced from [snap].
  /// Called by the provider on every `_onData` (each waveform refresh)
  /// while a recording is in progress, so the CSV matches the chart
  /// point-for-point.  Synchronous — [IOSink.writeln] buffers the
  /// write into an in-memory chunk and returns a [Future] the caller
  /// may ignore; actual disk I/O happens when the sink flushes (on
  /// buffer-fill or [stop]).  Idempotent when not actively writing:
  /// the guard is `sink != null`, which holds only between [start]
  /// (which sets the sink) and [stop] / [dispose] (which both clear
  /// the sink).  Using sink-presence rather than [isRecording] as the
  /// gate is intentional — [dispose] tears the sink down without
  /// flipping [RecordingSession.isRecording] (it's a sync close, not
  /// a state-changing stop), so post-dispose [record] must still
  /// short-circuit without bumping [sampleCount].  The provider can
  /// therefore wire [record] unconditionally into `_onData` and let
  /// the sink guard own the on/off semantics across start/stop/
  /// dispose.
  void record(PowerSnapshot snap) {
    final sink = _sink;
    if (sink == null) return; // not started, stopped, or disposed
    sink.writeln(snap.toCsvRow());
    _session = _session.copyWith(sampleCount: _session.sampleCount + 1);
  }

  /// Stop recording.  Flushes and closes the sink, and stamps
  /// `stopTime`.  Idempotent: calling [stop] when not recording is a
  /// no-op.  No timer to cancel — recording cadence was driven by
  /// [record] calls from the provider, not an internal timer.
  ///
  /// Returns the updated [RecordingSession] (with `stopTime` set,
  /// `isRecording == false`).
  Future<RecordingSession> stop() async {
    if (!_session.isRecording) return _session;
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (e) {
        debugPrint('[LOGGER] stop sink flush/close error: $e');
      }
    }
    _session = _session.copyWith(
      stopTime: DateTime.now(),
      isRecording: false,
    );
    return _session;
  }

  /// Defensive cleanup — equivalent to [stop] but synchronous and
  /// never throws.  Safe to call multiple times.  Use from the
  /// provider's [dispose] path.
  void dispose() {
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        // Synchronous close — sink.close() returns a Future but we
        // intentionally don't await it here (dispose is sync); the
        // OS-level file close happens on the next microtask.  If
        // the process is shutting down there's a tiny risk of losing
        // the last in-flight write, but Phase E's first version
        // prefers "never blocks shutdown" over "flush everything".
        sink.close();
      } catch (e) {
        debugPrint('[LOGGER] dispose sync-close error: $e');
      }
    }
  }

  // ── Internals ────────────────────────────────────────────────────

  /// Resolve (creating if necessary) the recording output directory
  /// under the platform's application support path:
  ///   * Linux: `$XDG_DATA_HOME/riden_power_supply/recordings/`
  ///           (fallback `~/.local/share/...`)
  ///   * Windows: `%APPDATA%\beilusm.riden_power_supply\recordings\`
  /// Testability: tests inject a [DataLogger] with a [_store] and
  /// exercise [stop]/[dispose] without ever calling [start]; this
  /// method is only invoked by [start].
  Future<Directory> _resolveRecordingDir() async {
    // Local promotion — final-field promotion does apply to private
    // final fields in modern Dart, but assigning to a local is the
    // universally-safe idiom that keeps the analyzer quiet and the
    // invariant self-evident to readers.
    final factory = _recordingDirFactory;
    if (factory != null) return factory();
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}recordings');
    if (!dir.existsSync()) {
      // recursive — supports nested platform paths.
      await dir.create(recursive: true);
    }
    return dir;
  }

  void _writeHeader() {
    _sink?.writeln(_header);
  }

  static const String _header =
      'time,voltage,current,power,inputVoltage,temperature,outputEnable,'
      'protectionState,activeSlot';

  /// Format a [DateTime] as `yyyyMMdd_HHmmss` for use in the CSV
  /// filename.  Local time, not UTC — recordings are user-facing
  /// artifacts and the filename should match the user's wall clock.
  static String _formatStamp(DateTime t) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${p(t.month)}${p(t.day)}'
        '_${p(t.hour)}${p(t.minute)}${p(t.second)}';
  }
}
