import 'package:flutter/foundation.dart';

/// Phase E — event log interface reserved for future use.
///
/// Per Phase E design doc: "本阶段只实现接口，不需要完整 UI".
///
/// Reserved event types (future implementation will materialise these
/// via a sink / persisted log; for now [log] just debugPrints):
///   * `ovp_trigger`     — over-voltage protection activated
///   * `ocp_trigger`     — over-current protection activated
///   * `otp_trigger`     — over-temperature protection activated
///   * `protection_clear` — protection state returned to normal
///   * `slot_change`     — user invoked quickSwitch HR[19] write
///   * `usb_disconnect`  — watcher observed CH340 unplug
///   * `usb_reconnect`   — watcher auto-reconnected after replug
///   * `param_write`     — user parameter write (setVoltage / etc.)
///
/// The shape of [payload] is intentionally unstructured — each
/// event type defines its own fields.  This keeps the interface
/// future-proof without committing to a fixed schema now.
class EventLogger {
  /// Log an event with a [type] discriminator and a free-form
  /// [payload] map.  Phase E first version writes only to
  /// `debugPrint` (visible in dev run logs).  Future phases can
  /// append to a structured log file or surface via UI.
  ///
  /// [type] should be one of the constants declared in the docstring
  /// above (or a new type when new event sources arise).  Callers
  /// must NOT include user-private data (PII) in [payload] if logs
  /// may end up attached to bug reports — keep payloads to
  /// device-level operational signals.
  void log(String type, Map<String, Object?> payload) {
    debugPrint('[EVENT] $type $payload');
  }
}
