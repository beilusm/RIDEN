import '../models/power_snapshot.dart';

/// Phase E — in-memory store of the latest device state snapshot,
/// populated from the UI isolate's `dataStream` merge path.
///
/// Strict contract (per Phase E design doc):
///   * **No Modbus requests** — this class only *receives* snapshots
///     via [update]; it never triggers a read, never spawns a
///     worker, and never touches a serial port.
///   * **No Timer** — it doesn't poll on its own cadence; it's
///     driven entirely by callers (the provider's `_onData`
///     callback) invoking [update].
///   * **No Scheduler interaction** — scheduler / worker / poll
///     loop are unaware of this store's existence.
///
/// Thread-safety: [SnapshotStore] is single-isolate (UI isolate).
/// The provider's data stream subscription runs in the UI isolate's
/// event loop, so [update] and [latest] are guaranteed to be called
/// sequentially — no locking required.
///
/// Lifecycle: a [SnapshotStore] instance lives for the duration of
/// the [PowerSupplyProvider] that owns it.  It's reset implicitly by
/// each new [update] (which supersedes any prior snapshot); callers
/// can explicitly forget the stored snapshot via [clear].
class SnapshotStore {
  PowerSnapshot? _latest;

  /// Replace the stored snapshot.  Idempotent in the sense that
  /// calling [update] with the same instance twice (or different
  /// instances with equivalent field values) is a harmless
  /// overwrite — no dedup is attempted because the DataLogger /
  /// RecordingSession layer is responsible for any sampling
  /// throttling.
  void update(PowerSnapshot snapshot) {
    _latest = snapshot;
  }

  /// Current snapshot, or `null` if no [update] has been received
  /// yet (or [clear] has been called).  Returns the cached reference
  /// directly — callers must NOT mutate it.  Treating the return as
  /// read-only is the stated contract.
  PowerSnapshot? latest() => _latest;

  /// Forget the stored snapshot.  Used by the provider on disconnect
  /// / dispose so a stale device-state doesn't leak into the next
  /// connect session.
  void clear() {
    _latest = null;
  }
}
