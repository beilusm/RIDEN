import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/power_snapshot.dart';
import '../models/power_supply_data.dart';
import '../services/data_logger.dart';
import '../services/event_logger.dart';
import '../services/modbus_service.dart';
import '../services/snapshot_store.dart';

class PowerSupplyProvider extends ChangeNotifier {
  final ModbusService _service;
  StreamSubscription<PowerSupplyData>? _sub;

  static const int maxChartPoints = 300;

  // ── Phase E — recording pipeline ───────────────────────────────
  // SnapshotStore / DataLogger / EventLogger are owned by the
  // provider (UI isolate).  Logger is a pure consumer — it never
  // issues Modbus reads, never spawns a worker, never touches the
  // scheduler.  Recording is event-driven: [_onData] builds a
  // [PowerSnapshot] from the canonical merged [PowerSupplyData]
  // (post active-slot ovp/ocp sync), feeds it to [SnapshotStore]
  // (latest snapshot cache, retained for future consumers) AND to
  // [DataLogger.record] (one CSV row per waveform refresh).  No
  // sampling timer — CSV rows line up 1:1 with chart points.
  final SnapshotStore _store = SnapshotStore();
  late final DataLogger _logger = DataLogger();
  final EventLogger _eventLogger = EventLogger();

  /// Read-only access for UI / tests.  RecordingSession reflects
  /// start/stop state + sample count, refreshed by [startRecording]
  /// / [stopRecording].  The provider's [notifyListeners] is invoked
  /// after each lifecycle mutation so widgets rebuild with the new
  /// session fields.
  RecordingSession get recordingSession => _logger.session;

  PowerSupplyProvider(this._service);


  // ── Current snapshot (the RegisterCache) ───────────────────────
  PowerSupplyData _data = PowerSupplyData(timestamp: DateTime.now());
  PowerSupplyData get data => _data;

  // ── Rolling chart history ──────────────────────────────────────
  final List<PowerSupplyData> _chartData = [];
  List<PowerSupplyData> get chartData => List.unmodifiable(_chartData);

  // ── Connection state ───────────────────────────────────────────
  bool _connected = false;
  bool get connected => _connected;

  String? _connectedPort;
  String? get connectedPort => _connectedPort;
  int _baudRate = 115200;
  int get baudRate => _baudRate;
  int _address = 1;
  int get address => _address;
  bool _connecting = false;
  bool get connecting => _connecting;

  Future<List<String>> listPorts() => _service.listPorts();


  // ── Register view mode ────────────────────────────────────────
  bool _showRegisters = false;
  bool get showRegisters => _showRegisters;
  void toggleRegView() {
    _showRegisters = !_showRegisters;
    if (_showRegisters) {
      _service.pauseTieredPolling();
    } else {
      _service.resumeTieredPolling();
    }
    notifyListeners();
  }

  // ── Communication health ──────────────────────────────────────
  DateTime _lastPollOk = DateTime.now();
  Timer? _healthTimer;
  int _consecutiveFails = 0;
  static const int _timeoutThreshold = 3; // consecutive failures → timeout
  static const int _errorThreshold = 6; // consecutive failures → error

  // ── Memory slots ───────────────────────────────────────────────
  int _activeSlot = 0;
  int get activeSlot => _activeSlot;
  final Map<int, List<double>> _slots = {};
  List<double>? slotValues(int index) => _slots[index];

  Timer? _bgSlotTimer;
  bool _slotsLoaded = false;

  // ── HR[19] active-slot confirmation timer ──────────────────────
  //
  // Background timer that periodically reconciles `_activeSlot`
  // against the device's actual HR[19] value.  Without this, the
  // optimistic cache set by `quickSwitch()` would drift silently
  // whenever the user switches preset via the hardware front-panel
  // (the firmware writes HR[19]; the UI never re-reads it).
  //
  // The timer issues ONE `TaskPriority.background` (base=50) single-
  // register read per tick via `ModbusService.readActiveSlot`.  That
  // runs in the `user` scheduler group with a stable dedup key
  // `'hr19_confirm'`, so it neither contends with FAST poll
  // (`dedup='fast'`, budget 150ms) nor with SLOW slot scan
  // (`dedup='slot_M0'..'slot_M9'`, budget 1000ms); scheduler aging
  // ensures low priority cannot starve it indefinitely while the
  // connection stays healthy.
  //
  // Tick cadence = 1s, aligned with SLOW poll.  On mismatch the
  // optimistic `_activeSlot` is overwritten in place (preserving
  // UI smoothness, no flash) and the new active slot's stored
  // OVP/OCP is re-synced from the `_slots` cache (same pattern as
  // the SLOT-sync branch of `_onData`).  notifyListeners fires so
  // widgets reading `provider.activeSlot` rebuild with the new
  // label (bottom_status chip, setpoint_panel PRESET row, preset
  // dialog ACTIVE highlight).
  Timer? _activeSlotConfirmTimer;

  // ── USB watcher timer (Phase D) ────────────────────────────────
  // Polls [_service.scanCh340] at [_usbWatchInterval] cadence.  The
  // scan is a one-shot isolate USB enumeration (`sp_get_port_usb_vid_pid`)
  // and does NOT touch the device's serial port — no Modbus RTU traffic
  // is generated by the watcher itself.  Only when a CH340 is observed
  // does the watcher invoke [connect], which spawns the worker /
  // starts polling.
  //
  // Tick guards:
  //   * _connecting path: skip — the in-flight connect attempt will
  //     flip state shortly and the next tick re-evaluates.
  //   * _connected + CH340 still present: no-op (keep polling).
  //   * _connected + CH340 disappeared: proactively call
  //     disconnect(stopWatcher: false) — tear down the worker BEFORE
  //     the in-flight Modbus READ times out (saves up to ~250ms of
  //     futile `_accumulateRead` against a dead port).  The watcher
  //     keeps running so the next tick can reconnect when the CH340
  //     comes back.
  //   * not _connected + CH340 present: invoke connect() — connect's
  //     own scanner factory re-confirms and spawns the worker.
  //   * not _connected + no CH340: no-op (app stays cold — exactly
  //     what the user asked for, the device's serial port is left
  //     alone while the cable is unplugged).
  //
  // Watcher lifecycle:
  //   * app boot (app.dart initState) → startUsbWatch
  //   * user disconnect() → stopUsbWatch (DEFAULT param keeps the
  //     explicit disconnect honoured — the user pulled the plug on
  //     purpose, don't relight)
  //   * worker crash (P1-2 _handleWorkerError) → watcher stays
  //     alive → next tick sees `_connected == false` AND
  //     scanCh340().found → invokes connect() → automatic recovery
  //     without user intervention
  //   * watcher observed unplug → disconnect(userInitiated: false)
  //     tears down worker but keeps the watcher armed →
  //     automatic reconnect when the CH340 is plugged back in
  //   * dispose() → stopUsbWatch (defensive cleanup)
  //
  // Phase D follow-up — manual disconnect no longer stops the watcher.
  // Previously, `disconnect()` cancelled the timer so a subsequent
  // unplug + replug had no observer → the app got stuck "disconnected"
  // forever.  Now the user's explicit DISCONNECT is honoured via a
  // [_userDisconnected] flag that suppresses auto-reconnect while the
  // CH340 is *still plugged*.  When the watcher observes the CH340
  // physically unplug, the flag clears — so a fresh plug-in event
  // reconnects automatically.  This matches the user's mental model:
  // "I unplugged from the app, but if I physically re-seat the USB
  // that's a new session — auto-recover."
  Timer? _usbWatchTimer;
  static const Duration _usbWatchInterval = Duration(seconds: 1);

  /// Phase D follow-up — set by an explicit [disconnect] call so the
  /// watcher's subsequent 1s ticks do NOT immediately undo the user's
  /// decision (CH340 is still present → tick would otherwise
  /// auto-connect).  Cleared by the watcher when the CH340 is
  /// physically unplugged (observed via `scanCh340().found == false`),
  /// so the next plug-in event reconnects automatically.
  ///
  /// State transitions:
  ///   * user disconnect() → _userDisconnected = true
  ///   * watcher tick sees no CH340 + flag set → clear flag
  ///     (physical unplug observed — user's "disconnect" intent is
  ///     moot now that the cable is actually out)
  ///   * watcher tick sees CH340 present + flag set → no-op
  ///     (respect the user's disconnect while the device stays plugged)
  ///   * watcher tick sees CH340 present + flag cleared → connect()
  ///     (normal auto-reconnect — flag was previously cleared by an
  ///     unplug event, so this plug-in is a fresh user intent)
  bool _userDisconnected = false;

  /// Whether the USB watcher timer is currently armed.  Exposed for
  /// UI / tests so consumers can assert "the app is in USB-watch
  /// mode" without reaching into private state.  Read-only.
  bool get isUsbWatching => _usbWatchTimer?.isActive ?? false;

  /// Begin polling [_service.scanCh340] every [_usbWatchInterval]
  /// until the provider is disposed or [stopUsbWatch] is called.
  ///
  /// Idempotent — calling twice with an active timer is a no-op.
  /// First tick fires synchronously so the user sees a connect
  /// attempt immediately on app boot without waiting 1s.
  ///
  /// See [_usbWatchTimer]'s field doc for the full state-machine.
  void startUsbWatch() {
    if (_usbWatchTimer != null) return; // already armed
    // Fire the first tick synchronously so app boot starts the scan
    // immediately rather than waiting 1s for the first tick.
    _usbWatchTick();
    _usbWatchTimer = Timer.periodic(_usbWatchInterval, (_) {
      _usbWatchTick();
    });
  }

  /// Stop the USB watcher.  Called by [disconnect] so an explicit
  /// user DISCONNECT is honoured (the watcher won't immediately
  /// re-fire connect).  The watcher's own proactive disconnect
  /// path uses disconnect(stopWatcher: false) and so skips this.
  void stopUsbWatch() {
    _usbWatchTimer?.cancel();
    _usbWatchTimer = null;
  }

  /// Watcher's periodic tick — see [_usbWatchTimer] field doc for
  /// the full state-machine.
  void _usbWatchTick() {
    // A connect attempt is in-flight — let it finish flipping
    // state rather than double-spawn a worker on this tick.
    if (_connecting) return;

    // Lightweight USB probe — does NOT touch the device's serial
    // port (no Modbus I/O, no _accumulateRead, no worker traffic).
    // This is the key for the user's "don't consume the device's
    // response capacity" requirement: while the CH340 is absent
    // the device stays cold (no polling requests flow at all).
    _service.scanCh340().then((result) {
      if (!result.found) {
        if (_connected) {
          // CH340 vanished mid-session — proactively tear down the
          // worker BEFORE the pending Modbus READ cycle times out.
          // Saves up to ~250ms of futile `_accumulateRead` against
          // a dead port.  userInitiated: false keeps the watcher
          // armed and does NOT set the _userDisconnected flag —
          // this is a watcher-observed unplug, not a user intent.
          // Also clear any stale _userDisconnected flag here: if
          // the user had manually disconnected while the CH340 was
          // still plugged, the physical unplug moots that intent
          // and a fresh plug-in should auto-reconnect.
          debugPrint('[WATCH] CH340 disappeared — proactive '
              'disconnect(userInitiated: false)');
          _userDisconnected = false;
          disconnect(userInitiated: false);
        } else if (_userDisconnected) {
          // User had manually disconnected while the CH340 was
          // still plugged — now they (or someone) physically
          // yanked the USB cable.  This is the Phase D follow-up
          // fix for "manual disconnect → unplug → replug → no
          // auto-reconnect": clear the flag so the next plug-in
          // event reconnects automatically.
          debugPrint('[WATCH] CH340 absent + user had disconnected — '
              'clearing _userDisconnected so next plug-in '
              'auto-reconnects');
          _userDisconnected = false;
        }
        // not connected + no CH340 → no-op, device stays cold
        return;
      }
      // CH340 is present.  If the user explicitly disconnected,
      // respect that decision while the cable stays put — don't
      // auto-reconnect until the user either calls connect() or
      // physically unplugs (which clears _userDisconnected above).
      if (_userDisconnected) return;
      // If already connected, the worker is doing its own polling —
      // leave it alone (the polling architecture handles its own
      // keep-alive / error escalation).
      if (_connected) return;
      // Not connected + CH340 present → invoke connect().  connect's
      // own scanner factory re-runs the USB probe synchronously
      // (same isolate cost as the watcher just paid) and spawns /
      // handshakes the worker on success.
      //
      // connect() rethrows on failure — catchError swallows it so
      // the timer's then-callback doesn't surface an unhandled
      // Future error.  connect()'s catch block already debugPrints
      // the cause.
      connect().catchError((Object _) {});
    });
  }

  // ── Lifecycle ──────────────────────────────────────────────────

  Future<void> connect({String? port, int baudRate = 115200, int address = 1}) async {
    if (_connected || _connecting) return;
    _connecting = true;
    // Phase D follow-up — a manual connect call (or a watcher
    // auto-reconnect) supersedes any prior user-disconnect intent.
    // Clear the flag here so a successful connect doesn't get
    // immediately undone by a future disconnect-watcher-tick.
    _userDisconnected = false;
    notifyListeners();
    try {
      _baudRate = baudRate;
      _address = address;
      await _service.connect(port: port, baudRate: baudRate, address: address);
      // Phase D fix — prefer the service's resolved port name when
      // the caller passed `port: null` (auto-scan path).  The
      // service's scanner resolved a real CH340 port
      // (e.g. /dev/ttyUSB0); surface that to the UI rather than the
      // caller's null.  Falls back to the caller-supplied port for
      // the explicit manual-connect path (SerialPanel passes a
      // chosen port name, service honours it as-is and reports it
      // back through [currentPort]).
      _connectedPort = _service.currentPort ?? port;
      _connected = true;
      _lastPollOk = DateTime.now();
      _consecutiveFails = 0;
      _sub = _service.dataStream.listen(_onData);
      _data = _data.copyWith(commStatus: CommStatus.online);
      _startBgSlotRefresh();
      _startHealthCheck();
      _startActiveSlotConfirm();
    } catch (e) {
      debugPrint('[PROVIDER] connect failed: $e');
      rethrow;
    } finally {
      _connecting = false;
      // Phase D fix — re-arm the USB watcher after EVERY connect
      // attempt, regardless of success or failure.  This fixes the
      // reported bug "手动点击几次 connect 和 disconnect 自动连接
      // 和自动识别会出问题":
      //
      //   user manual disconnect → stopUsbWatch cancels the timer
      //   user manual connect    → previously did NOT re-arm the
      //                            watcher → subsequent unplug /
      //                            worker crash had no auto-recovery
      //                            → app stuck "disconnected"
      //
      // Now: any connect call (manual or watcher-driven) leaves the
      // watcher armed.  Success path: next tick sees `_connected`
      // and no-ops.  Failure path: next tick retries scanCh340 +
      // connect() automatically.  Manual disconnect still stops
      // the watcher (stopWatcher: true default) so the user's
      // explicit DISCONNECT is honoured — but the very next
      // manual CONNECT re-arms it.
      //
      // startUsbWatch is idempotent: if the watcher is already
      // armed (e.g. this connect was itself watcher-driven), this
      // is a no-op.
      startUsbWatch();
      notifyListeners();
    }
  }

  /// Disconnect from the device.  Tears down polling, cancels the
  /// data stream subscription, and force-kills the worker isolate.
  ///
  /// [userInitiated] controls the USB watcher's auto-reconnect
  /// behaviour after this call returns (Phase D follow-up):
  ///   * `true` (default — user pressed DISCONNECT button, or
  ///     `reconnect()` / `dispose()`) — sets the [_userDisconnected]
  ///     flag but does NOT stop the watcher.  The flag suppresses
  ///     auto-reconnect while the CH340 is still plugged (respect
  ///     the user's decision).  When the watcher observes the CH340
  ///     physically unplug, the flag clears → next plug-in
  ///     auto-reconnects.
  ///   * `false` — watcher-observed unplug path: the device is
  ///     already gone, no user intent to honour, leave the flag
  ///     alone (in fact the watcher clears it at the same call site
  ///     so a subsequent plug-in reconnects immediately).
  ///
  /// Why the flag vs the old stop-the-watcher approach: the old
  /// approach made the user's manual disconnect a *permanent*
  /// disconnect — even after physically re-seating the USB, the
  /// app stayed "disconnected" because the watcher was dead.
  /// Users reported "manual disconnect + unplug + replug → no
  /// auto-reconnect".  The flag-based approach distinguishes "user
  /// clicked disconnect" (transient intent — cleared by physical
  /// unplug) from "watcher saw unplug" (permanent tee — already
  /// torn down).
  Future<void> disconnect({bool userInitiated = true}) async {
    // Phase D follow-up — no longer stopUsbWatch here.  The watcher
    // stays armed so subsequent USB state changes (unplug + replug)
    // are observed.  Set the user-intent flag so the next tick
    // doesn't immediately undo this disconnect when the CH340 is
    // still plugged; the flag clears automatically once the watcher
    // sees the CH340 physically unplug.
    if (userInitiated) _userDisconnected = true;
    _healthTimer?.cancel();
    _bgSlotTimer?.cancel();
    _bgSlotTimer = null;
    _activeSlotConfirmTimer?.cancel();
    _activeSlotConfirmTimer = null;
    _sub?.cancel();
    _sub = null;
    // Phase E — drop the cached snapshot so a stale reading
    // doesn't bleed across sessions.  RecordingSession and the
    // DataLogger's open CSV file stay alive (the user may unplug +
    // replug mid-recording and expect the file to keep
    // accumulating once the worker reconnects).  SnapshotStore
    // re-fills on the next successful _onData after reconnect.
    _store.clear();
    await _service.disconnect();
    _connected = false;
    _connectedPort = null;
    _chartData.clear();
    _data = _data.copyWith(commStatus: CommStatus.offline);
    notifyListeners();
  }

  /// Disconnect, then reconnect with new parameters (or the cached ones).
  Future<void> reconnect({String? port, int? baudRate, int? address}) async {
    if (_connected || _connecting) {
      await disconnect();
    }
    await connect(
      port: port ?? _connectedPort,
      baudRate: baudRate ?? _baudRate,
      address: address ?? _address,
    );
  }

  @override
  void dispose() {
    stopUsbWatch();
    _healthTimer?.cancel();
    _bgSlotTimer?.cancel();
    _activeSlotConfirmTimer?.cancel();
    _activeSlotConfirmTimer = null;
    _sub?.cancel();
    _logger.dispose(); // Phase E — flush + close any open CSV file
    _service.disconnect();
    super.dispose();
  }

  // ── Phase E — recording control ─────────────────────────────────
  //
  // The DataLogger is a pure consumer — it never issues Modbus
  // reads, never spawns a worker, never touches the scheduler.  Rows
  // are written event-driven from [_onData] via [DataLogger.record],
  // so each waveform refresh (FAST ~150ms + SLOW ~1000ms) lands one
  // CSV row.  The provider exposes start/stop methods that the UI
  // invokes directly from the recording panel; both methods invoke
  // notifyListeners so widgets rebuild with the updated session
  // state (file path, sample count, timestamps).
  //
  // Lifecycle:
  //   * startRecording while disconnected — allowed; no _onData is
  //     firing so [DataLogger.record] is never called and the file
  //     contains only the header until the first real measurement
  //     arrives.  User can pre-arm recording before plugging in the
  //     device.
  //   * startRecording while already recording — no-op (logger's
  //     own guard).
  //   * stopRecording while not recording — no-op.
  //   * disconnect mid-recording — the open CSV file stays open; no
  //     _onData fires while disconnected, so [record] is never
  //     called and the file simply stops growing until reconnect.
  //     User reconnect resumes writing to the same file (same
  //     session); SnapshotStore is cleared so its `latest()` does
  //     not leak a stale snapshot across sessions.
  //   * dispose — defensive teardown via _logger.dispose() (sync
  //     sink close, never blocks shutdown).

  /// Begin recording.  [filePath] is the user-selected path from the
  /// native Save dialog (invoked by the recording panel).  When
  /// `null`, the logger falls back to a timestamped file under the
  /// platform's application support directory — the path used by
  /// tests.
  Future<void> startRecording({String? filePath}) async {
    try {
      await _logger.start(filePath: filePath);
      _eventLogger.log('recording_start',
          {'file': _logger.session.filePath});
    } catch (e) {
      debugPrint('[PROVIDER] startRecording failed: $e');
      rethrow; // surface to UI as SnackBar
    }
    notifyListeners();
  }

  Future<void> stopRecording() async {
    try {
      await _logger.stop();
      _eventLogger.log('recording_stop',
          {'samples': _logger.session.sampleCount});
    } catch (e) {
      debugPrint('[PROVIDER] stopRecording failed: $e');
      rethrow;
    }
    notifyListeners();
  }


  // ── Health check timer ─────────────────────────────────────────

  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_connected) return;
      final since = DateTime.now().difference(_lastPollOk);
      if (since.inMilliseconds > 3000) {
        _updateCommStatus(CommStatus.timeout);
      }
    });
  }

  // ── HR[19] active-slot confirmation ────────────────────────────
  //
  // 1s tick that reads the device's currently-active preset register
  // and reconciles `_activeSlot` against it.  Background-tier Modbus
  // read — does not contend with FAST / SLOW polls.  See
  // [ModbusService.readActiveSlot] for scheduler details.
  void _startActiveSlotConfirm() {
    _activeSlotConfirmTimer?.cancel();
    _activeSlotConfirmTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _confirmActiveSlot());
  }

  Future<void> _confirmActiveSlot() async {
    if (!_connected) return;
    final hr19 = await _service.readActiveSlot();
    if (hr19 == null) return;
    if (hr19 == _activeSlot) return;

    // Mismatch — device and cache have diverged (most likely the
    // user switched preset via the hardware front-panel).  Overwrite
    // the optimistic cache in place so subsequent UI reads see the
    // device's truth, and re-sync active-slot OVP/OCP from the local
    // slot cache (mirrors the SLOT-sync branch of `_onData`).
    debugPrint('[PROVIDER] HR19 active-slot drift: '
        'cache=M$_activeSlot device=M$hr19 → overwriting cache');
    _activeSlot = hr19;
    final slot = _slots[hr19];
    if (slot != null && slot.length >= 4) {
      _data = _data.copyWith(ovp: slot[2], ocp: slot[3]);
    }
    notifyListeners();
    _service.incNotify();
  }

  void _updateCommStatus(CommStatus status) {
    if (_data.commStatus != status) {
      _data = _data.copyWith(commStatus: status);
      notifyListeners();
    }
  }

  // ── Internal data handler ──────────────────────────────────────

  void _onData(PowerSupplyData snapshot) {
    // P1-2: Worker-crash propagation.  SerialModbusService's
    // `_handleWorkerError` (wired into ModbusWorkerHandle.onError)
    // emits a single final snapshot with commStatus = error after
    // the worker isolate has died.  Treat that authoritative signal
    // differently from a normal poll snapshot:
    //   - flip `_connected = false` so the UI reconnect button lights
    //     up (matches explicit disconnect() behaviour)
    //   - do NOT reset `_lastPollOk` or `_consecutiveFails` — those
    //     still serve the health-check timer that's about to fire and
    //     escalate the timeout path
    //   - do NOT append to `_chartData` (a crash isn't a measurement)
    //
    // Scope note: only `CommStatus.error` is treated as the crash
    // signal.  `CommStatus.offline` is the worker's *default* poll
    // snapshot value (it never explicitly sets commStatus on FAST /
    // SLOW _replyData), and the existing merge path below already
    // honour the "was offline → promote to online" upgrade.  Using
    // both `offline` and `error` here would interpret every normal
    // FAST poll as a crash — the original mock-tick behaviour ticked
    // PowerSupplyData defaults to offline at every 250 ms interval.
    //
    // Explicit service-side `disconnect()` emits `CommStatus.offline`
    // too, but `provider.disconnect()` cancels its `_sub` BEFORE
    // calling `_service.disconnect()`, so that snapshot has no
    // listener and never reaches this method.
    if (snapshot.commStatus == CommStatus.error) {
      final wasConnected = _connected;
      if (wasConnected) {
        _connected = false;
        _connectedPort = null;
        _healthTimer?.cancel();
        _bgSlotTimer?.cancel();
        _bgSlotTimer = null;
        _activeSlotConfirmTimer?.cancel();
        _activeSlotConfirmTimer = null;
        _data = _data.copyWith(commStatus: CommStatus.error);
        notifyListeners();
        _service.incNotify();
      }
      return;
    }

    _lastPollOk = DateTime.now();
    _consecutiveFails = 0;

    // Keep comm status from the service snapshot, or compute our own
    final merged = snapshot.copyWith(
      commStatus: _data.commStatus == CommStatus.offline
          ? CommStatus.online
          : _data.commStatus,
      // Phase B.2 — never let snapshot.ovp/ocp overwrite _data's
      // active-slot protection.  Service's _current.ovp/ocp are now
      // frozen at PowerSupplyData defaults (see _sub.listen guard); a
      // raw merge would drag those defaults into _data and clobber the
      // value previously written by quickSwitch() or the SLOT-sync
      // branch below.  Preserve _data's current ovp/ocp across the
      // merge; the SLOT-sync block updates them from the active slot's
      // storage when SLOW poll brings fresh values.
      ovp: _data.ovp,
      ocp: _data.ocp,
    );

    _data = merged;
    _chartData.add(merged);
    while (_chartData.length > maxChartPoints) {
      _chartData.removeAt(0);
    }

    if (snapshot.memorySlots.isNotEmpty) {
      for (final s in snapshot.memorySlots) {
        _slots[s.index] = [s.vSet, s.iSet, s.ovp, s.ocp];
      }
      _slotsLoaded = true;
      _bgSlotTimer?.cancel();
      _bgSlotTimer = null;

      // Phase B.2 — sync the active slot's stored OVP/OCP into _data.
      // Each M0..M9 slot's protection values live at HR[80+slot*4+2/3]
      // (M0=82/83, M1=86/87, M2=90/91, …).  The active slot is HR[19].
      // The SLOW poll cycle fills snapshot.memorySlots (cumulatively
      // re-emitted by service via _mergeSlots) with the latest
      // device-side read of these per-slot storage values.  Find the
      // matching index and promote its ovp/ocp to _data, so the
      // Settings → PROTECTION panel renders the *active* slot's
      // protection (not M0's storage, which only coincides with the
      // active protection when activeSlot == 0).  quickSwitch() also
      // writes _data.ovp/ocp from the same formula; this branch keeps
      // them in sync when the user changes protections from the
      // device's front-panel without a quickSwitch round-trip.
      for (final s in snapshot.memorySlots) {
        if (s.index == _activeSlot) {
          _data = _data.copyWith(ovp: s.ovp, ocp: s.ocp);
          break;
        }
      }
    }

    _updateCommStatus(CommStatus.online);
    // Phase E — publish the canonical merged snapshot.  Build the
    // PowerSnapshot ONCE (post active-slot ovp/ocp sync above, so it
    // reflects the *active* slot's protection even when FAST poll
    // delivered M0 storage raw values), then push to both the
    // SnapshotStore (latest-snapshot cache, retained for future
    // consumers / debug overlay) and to DataLogger.record.  Recording
    // is event-driven: each _onData = one waveform refresh = one CSV
    // row, so the recorded file lines up 1:1 with the chart points
    // the user just saw — no 1Hz sampling timer to drift against the
    // poll loop, no missed samples between ticks.  _logger.record is
    // a buffered IOSink write, so FAST cadence (~6.7/sec) does NOT
    // cause disk syncs per call.
    final snap = PowerSnapshot.from(_data, activeSlot: _activeSlot);
    _store.update(snap);
    _logger.record(snap);
    _service.incNotify();
    notifyListeners();
  }

  // Fallback: called when a poll produces no data
  void _onPollMiss() {
    _consecutiveFails++;
    if (_consecutiveFails >= _errorThreshold) {
      _updateCommStatus(CommStatus.error);
    } else if (_consecutiveFails >= _timeoutThreshold) {
      _updateCommStatus(CommStatus.timeout);
    }
  }

  void _startBgSlotRefresh() {
    if (_slotsLoaded) return;
    // Phase B.1 — single bulk read (HR[80..119] = 40 registers in one
    // RTU round-trip).  Previously this used a 500ms Timer × 10 firing
    // 10 individual `readMemorySlot(i)` requests — worst-case ~2.5s
    // total.  Now one call completes in ~250ms.  Failure path falls
    // back to the worker's own SLOW poll, which already fills in
    // `memorySlots` via the dataStream listener in [_onData].
    refreshAllSlots();
  }

  Future<void> _loadOneSlot(int index) async {
    try {
      final raw = await _service.readMemorySlot(index);
      if (raw != null && raw.length >= 4) {
        _slots[index] = [raw[0] / 100.0, raw[1] / 1000.0, raw[2] / 100.0, raw[3] / 1000.0];
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[PROVIDER] _loadOneSlot($index) failed: $e');
    }
  }

  /// Bulk-refresh all 10 memory slots.  Phase B.1 — previously issued
  /// 10 sequential `readMemorySlot(i)` calls (one 4-register Modbus
  /// RTU each, ~250ms per request → up to ~2.5s total when the device
  /// was slow).  Now uses [ModbusService.readAllMemorySlots] — a
  /// single 40-register bulk read of HR[80..119], one RTU round-trip
  /// (~250ms typical, ~500ms worst-case on slow devices).
  Future<void> refreshAllSlots() async {
    try {
      final t = Stopwatch()..start();
      final slots = await _service.readAllMemorySlots();
      t.stop();
      debugPrint('[PROVIDER] refreshAllSlots bulk-read '
          '${slots.length}/10 slots in ${t.elapsedMilliseconds}ms');
      for (final s in slots) {
        _slots[s.index] = [s.vSet, s.iSet, s.ovp, s.ocp];
      }
      _slotsLoaded = true;
      _bgSlotTimer?.cancel();
      _bgSlotTimer = null;
      notifyListeners();
    } catch (e) {
      debugPrint('[PROVIDER] refreshAllSlots failed: $e');
    }
  }

  // ── Optimistic write helpers ───────────────────────────────────

  /// Apply an optimistic update, execute the write, rollback on failure.
  Future<void> _optimisticWrite(
    PowerSupplyData optimistic,
    Future<void> Function() write,
  ) async {
    final prev = _data;
    _data = optimistic;
    notifyListeners();

    try {
      await write();
      // Success — next poll confirms
    } catch (e) {
      debugPrint('[PROVIDER] write failed, rollback: $e');
      _data = prev;
      notifyListeners();
    }
  }

  // ── User actions ───────────────────────────────────────────────

  Future<void> setVoltage(double v) async {
    await _optimisticWrite(
      _data.copyWith(setVoltage: v),
      () => _service.setVoltage(v),
    );
  }

  Future<void> setCurrent(double a) async {
    await _optimisticWrite(
      _data.copyWith(setCurrent: a),
      () => _service.setCurrent(a),
    );
  }

  Future<void> setOutput(bool enable) async {
    await _optimisticWrite(
      _data.copyWith(outputEnabled: enable),
      () => _service.setOutput(enable),
    );
  }

  Future<void> setOVP(double v) async {
    await _optimisticWrite(
      _data.copyWith(ovp: v),
      () => _service.setOVP(v),
    );
  }

  Future<void> setOCP(double a) async {
    await _optimisticWrite(
      _data.copyWith(ocp: a),
      () => _service.setOCP(a),
    );
  }

  /// Phase B: hardware quick-switch to memory slot M0..M9.
  ///
  /// Writes HR[19] = [slotIndex] via the device protocol verified in
  /// Phase A.5.  After writing, waits briefly for the device firmware
  /// to load the slot's preset into the active registers, then issues
  /// a full 121-register read so the UI state reflects the device's
  /// actual post-switch state — not a software cache.
  ///
  /// Replaces the legacy [loadSlot] path that did 4 separate writes
  /// (setVoltage / setCurrent / setOVP / setOCP).  Kept for fallback
  /// only; UI now calls [quickSwitch].
  Future<void> quickSwitch(int slotIndex) async {
    if (slotIndex < 0 || slotIndex > 9) return;
    _activeSlot = slotIndex;
    notifyListeners();

    // Phase B.1 — OVP/OCP are per-slot (user clarification after
    // hardware regression).  The active OVP/OCP values live at the
    // slot's storage address HR[80+N*4+2 / 80+N*4+3], NOT at HR82/83
    // (which is M0's storage and only reflects M0's OVP/OCP per the
    // datasheet address-overlap note in register_definition.dart:546).
    // Switching to M1 → device uses M1's OVP from HR86/87; the UI
    // must read those same bytes, not HR82/83.
    final slotBase = 80 + slotIndex * 4;
    final slotOvpAddr = slotBase + 2;
    final slotOcpAddr = slotBase + 3;

    try {
      // Phase B.1 — capture BEFORE snapshot for debug log so
      // M0↔M1/M2 bidirectional switches can be diffed in the console.
      final before = await _service.readRawRegisters(
          dedup: 'qsw_pre', expireMs: 1500);
      if (before != null && before.length >= 84) {
        debugPrint('[QSW] before M$slotIndex  '
            'HR19=${_reg(before, 19)}  '
            'HR8=${_reg(before, 8) / 100.0}V  '
            'HR9=${_reg(before, 9) / 1000.0}A  '
            'M${slotIndex}OVP=${_reg(before, slotOvpAddr) / 100.0}V  '
            'M${slotIndex}OCP=${_reg(before, slotOcpAddr) / 1000.0}A');
      } else {
        debugPrint('[QSW] before M$slotIndex  '
            'read failed/null (len=${before?.length})');
      }

      await _service.quickSwitch(slotIndex);
      // Allow ~600ms for the device firmware to apply the slot preset.
      // 600ms is comfortably above the FAST poll interval (150ms × ~4
      // cycles) so the next read reflects a settled state.
      await Future.delayed(const Duration(milliseconds: 600));
      // Refresh UI state from the device (full read at user priority).
      final raw = await _service.readRawRegisters(
          dedup: 'quick_switch', expireMs: 1500);
      if (raw != null && raw.length >= 20) {
        _data = _data.copyWith(
          // Init-read fields: read once and retained.  quickSwitch
          // refresh can update them too since the full read covers
          // HR0..HR120.
          modelId: raw[0],
          firmwareVersion: raw[3],
          systemTempF: raw[7].toSigned(16).toDouble(),
          // Fast-poll fields.
          setVoltage: raw[8] / 100.0,
          setCurrent: raw[9] / 1000.0,
          keyLock: raw[15],
          protectionStatus: raw[16],
          isConstantCurrent: raw[17] == 1,
          outputEnabled: raw[18] == 1,
          // Phase B.1 — OVP/OCP for the ACTIVE slot.  Source = slot's
          // own storage at HR[80+slot*4+2/3].  Reading HR82/83 instead
          // would show M0's OVP/OCP regardless of active slot (that
          // was the pre-fix bug — UI kept showing M0 protection
          // values even after switching to M1/M2).
          ovp: raw.length > slotOvpAddr
              ? raw[slotOvpAddr] / 100.0
              : _data.ovp,
          ocp: raw.length > slotOcpAddr
              ? raw[slotOcpAddr] / 1000.0
              : _data.ocp,
        );
        notifyListeners();
        // Phase B.1 — AFTER snapshot.  Key: HR19 must match slotIndex
        // (device-side confirmation), HR8/HR9 should match the slot's
        // stored preset, OVP/OCP come from the slot's own storage.
        if (raw.length >= 84) {
          debugPrint('[QSW] after  M$slotIndex  '
              'HR19=${_reg(raw, 19)} (expect=$slotIndex)  '
              'HR8=${_reg(raw, 8) / 100.0}V  '
              'HR9=${_reg(raw, 9) / 1000.0}A  '
              'M${slotIndex}OVP=${_reg(raw, slotOvpAddr) / 100.0}V  '
              'M${slotIndex}OCP=${_reg(raw, slotOcpAddr) / 1000.0}A');
        }
      }
    } catch (e) {
      debugPrint('[PROVIDER] quickSwitch M$slotIndex FAILED: $e');
    }
  }

  /// Bounds-safe accessor used by [quickSwitch] debug logs.
  int _reg(List<int> regs, int addr) =>
      addr < regs.length ? regs[addr] : -1;

  @Deprecated('Use quickSwitch(slotIndex) instead — Phase B replaced '
      'this 4-write path with a single HR[19] quick-switch.  Kept '
      'for fallback / A/B comparison; no UI caller remains.')
  Future<void> loadSlot(int index) async {
    _activeSlot = index;
    final cached = _slots[index];

    if (cached != null && cached.length >= 4) {
      // Optimistic: update all 4 values at once, then write
      final prev = _data;
      _data = _data.copyWith(
        setVoltage: cached[0],
        setCurrent: cached[1],
        ovp: cached[2],
        ocp: cached[3],
      );
      notifyListeners();

      try {
        await _service.setVoltage(cached[0]);
        await _service.setCurrent(cached[1]);
        await _service.setOVP(cached[2]);
        await _service.setOCP(cached[3]);
      } catch (e) {
        debugPrint('[PROVIDER] loadSlot M$index FAILED: $e');
        _data = prev;
        notifyListeners();
        return;
      }
    } else {
      await _service.loadMemorySlot(index);
    }
    notifyListeners();
  }

  Future<void> fullPoll() async {
    final data = await _service.readAllRegisters();
    if (data != null) {
      _data = data;
      notifyListeners();
    }
  }

  Future<List<int>?> fullPollRaw({String? dedup, int? expireMs}) =>
      _service.readRawRegisters(dedup: dedup, expireMs: expireMs);

  void writeRawRegister(int address, int value) {
    _service.writeRegister(address, value).catchError((e) {
      debugPrint('[PROVIDER] writeRawRegister HR[$address] failed: $e');
    });
  }

  Future<void> saveSlot(int index) async {
    try {
      await _service.saveMemorySlot(
        index,
        _data.setVoltage,
        _data.setCurrent,
        _data.ovp,
        _data.ocp,
      );
      await _loadOneSlot(index);
    } catch (e) {
      debugPrint('[PROVIDER] saveSlot($index) failed: $e');
      rethrow;
    }
  }

  /// Edit M1..M9 preset storage: writes [vSet]/[iSet]/[ovp]/[ocp]
  /// into slot [index]'s storage registers HR[80 + index*4 + 0..3]
  /// via [ModbusService.saveMemorySlot], then re-reads the slot
  /// via [_loadOneSlot] to refresh the cached [_slots] entry and
  /// drive [notifyListeners].
  ///
  /// Storage-only edit semantics — does NOT touch the live active
  /// registers HR8/HR9 (Vset/Iset).  An OVP/OCP edit on a slot that
  /// happens to be the active one will land on the same physical
  /// register (HR[80 + activeSlot*4 + 2/3] is also the active
  /// protection register, see Phase B.2 / quickSwitch); the live
  /// Vset/Iset, however, only get the new preset after a
  /// [quickSwitch] round-trip.  Use LOAD (quickSwitch) after EDIT
  /// to activate a freshly edited preset on the live output.
  ///
  /// Range-guard: caller is responsible for clamping [vSet]/[ovp]
  /// into 0..62 V and [iSet]/[ocp] into 0..6.2 A; the service
  /// encoding (round() to int raw) silently wraps oversized
  /// values, so the UI dialog MUST clamp before invoking.
  Future<void> saveSlotValues(
      int index, double v, double i, double ovp, double ocp) async {
    if (index < 0 || index > 9) {
      debugPrint('[PROVIDER] saveSlotValues($index) ignored — out of '
          'range (must be 0..9)');
      return;
    }
    try {
      final before = _slots[index];
      final beforeStr = before != null
          ? '${before[0].toStringAsFixed(2)}V/'
              '${before[1].toStringAsFixed(3)}A/'
              '${before[2].toStringAsFixed(2)}V/'
              '${before[3].toStringAsFixed(3)}A'
          : 'null';
      debugPrint('[SLOT_EDIT] before M$index  $beforeStr  '
          '→  ${v.toStringAsFixed(2)}V/${i.toStringAsFixed(3)}A/'
          '${ovp.toStringAsFixed(2)}V/${ocp.toStringAsFixed(3)}A');
      await _service.saveMemorySlot(index, v, i, ovp, ocp);
      await _loadOneSlot(index);
      final after = _slots[index];
      final afterStr = after != null
          ? '${after[0].toStringAsFixed(2)}V/'
              '${after[1].toStringAsFixed(3)}A/'
              '${after[2].toStringAsFixed(2)}V/'
              '${after[3].toStringAsFixed(3)}A'
          : 'null';
      final unchanged = before != null
          && after != null
          && (after[0] - before[0]).abs() < 1e-6
          && (after[1] - before[1]).abs() < 1e-9
          && (after[2] - before[2]).abs() < 1e-6
          && (after[3] - before[3]).abs() < 1e-9;
      debugPrint('[SLOT_EDIT] after  M$index  $afterStr  '
          '${unchanged ? "(no change — write same as before)" : "(changed)"}');
    } catch (e) {
      debugPrint('[PROVIDER] saveSlotValues($index) failed: $e');
      rethrow;
    }
  }
}
