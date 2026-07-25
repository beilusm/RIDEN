import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/power_supply_provider.dart';
import '../services/data_logger.dart';
import '../theme/app_theme.dart';

/// Phase E — minimal recording control widget.
///
/// Surfaces:
///   * Start / Stop Recording button (toggles with the [RecordingSession.isRecording] state)
///   * Elapsed recording time (HH:MM:SS)
///   * Sample count written so far
///   * Absolute path of the open CSV file (truncated if too long)
///
/// Deliberately minimal per Phase E design doc: "不要设计复杂历史管理".
/// No session list, no replay, no export — just the live status of
/// the in-progress recording.  The user manages the file system
/// themselves (recordings land under the platform's application
/// support directory + `recordings/riden_recording_<stamp>.csv`).
class RecordingPanel extends StatelessWidget {
  const RecordingPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PowerSupplyProvider>(
      builder: (context, p, _) {
        final session = p.recordingSession;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('RECORDING',
                      style: AppTheme.digitalLabel
                          .copyWith(fontSize: 10, letterSpacing: 2)),
                  const Spacer(),
                  if (session.isRecording)
                    _pulseDot(),
                ],
              ),
              const SizedBox(height: 6),
              _ToggleButton(provider: p, session: session),
              const SizedBox(height: 6),
              _InfoRow(label: 'Time', value: _formatDuration(session.elapsed)),
              _InfoRow(label: 'Samples', value: '${session.sampleCount}'),
              if (session.filePath != null)
                _InfoRow(
                    label: 'File',
                    value: _truncatePath(session.filePath!),
                    small: true),
            ],
          ),
        );
      },
    );
  }

  /// Animated pulse indicator next to the RECORDING label while
  /// recording — a simple 0.7-second opacity oscillation.  Pure
  /// cosmetic; no behaviour.
  Widget _pulseDot() {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 1.0, end: 0.3),
      duration: const Duration(milliseconds: 700),
      builder: (context, opacity, _) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: AppTheme.errorRed.withValues(alpha: opacity),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }

  static String _formatDuration(Duration d) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(d.inHours)}:${p(d.inMinutes.remainder(60))}:${p(d.inSeconds.remainder(60))}';
  }

  /// Truncate a long absolute path to keep it on one line: keep the
  /// trailing filename + a hint of the parent directory.
  static String _truncatePath(String path) {
    if (path.length <= 56) return path;
    final last = path.split(RegExp(r'[/\\]')).last;
    return '.../$last';
  }
}

class _ToggleButton extends StatelessWidget {
  final PowerSupplyProvider provider;
  final RecordingSession session;
  const _ToggleButton({required this.provider, required this.session});

  @override
  Widget build(BuildContext context) {
    final recording = session.isRecording;
    final color = recording ? AppTheme.errorRed : AppTheme.voltGreen;
    final label = recording ? 'STOP' : 'START';
    return GestureDetector(
      onTap: () async {
        try {
          if (recording) {
            // STOP — flush + close the underlying CSV sink.  The session
            // state is retained (filePath + startTime still readable
            // after stop) so we can read the tmp file back and export.
            await provider.stopRecording();
            if (!context.mounted) return;
            if (Platform.isAndroid) {
              await _exportAndroidRecording(context, provider);
            }
            return;
          }
          // START ──────────────────────────────────────────────────────
          // Desktop: pop native Save dialog FIRST, pick the destination
          // path, then start the IOSink writing to that path.  This is
          // the original Phase E flow — `file_picker.saveFile` on Linux
          // / Windows returns a writable filesystem path.
          //
          // Android: SAF (Storage Access Framework) is one-shot
          // bytes-only — `saveFile(bytes:)` writes the bytes upfront
          // to a content:// URI; there is NO "open a writable stream"
          // mode.  We cannot IOSink to a SAF URI.  So Android records
          // in real-time to an app-private tmp file (path_provider
          // application support dir) and pops the Save dialog on STOP
          // instead — that way the user still chooses the final
          // destination via the system file picker as the user
          // requested.  See `Phase 4 fix: Android recording export via
          // SAF` commit for the full rationale.
          if (!Platform.isAndroid) {
            final now = DateTime.now();
            String p(int v) => v.toString().padLeft(2, '0');
            final stamp =
                '${now.year}${p(now.month)}${p(now.day)}_${p(now.hour)}${p(now.minute)}${p(now.second)}';
            final defaultName = 'riden_recording_$stamp.csv';
            final picked = await FilePicker.platform.saveFile(
              dialogTitle: 'Save recording as…',
              fileName: defaultName,
              type: FileType.custom,
              allowedExtensions: const ['csv'],
              lockParentWindow: true,
            );
            if (picked == null) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Recording cancelled — no file selected.'),
                backgroundColor: AppTheme.textDim,
                duration: Duration(seconds: 2),
              ));
              return;
            }
            await provider.startRecording(filePath: picked);
          } else {
            // Android — start immediately; Save dialog pops on STOP.
            await provider.startRecording();
          }
        } catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Recording error: $e'),
            backgroundColor: AppTheme.errorRed,
            duration: const Duration(seconds: 3),
          ));
        }
      },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            // withAlpha takes an int in 0..255 (codebase convention —
            // see serial_panel.dart:332).  Do NOT confuse with the
            // newer Color.withValues(alpha:) which expects a 0.0-1.0
            // double; passing 0x18 (=24) there clamasks to 1.0 alpha =
            // 100% opaque green/red, masking the entire button.
            color: color.withAlpha(0x18),
            border: Border.all(color: color, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(recording ? Icons.stop : Icons.fiber_manual_record,
                color: color, size: 12),
            const SizedBox(width: 6),
            Text(label,
                style: AppTheme.digitalValue
                    .copyWith(fontSize: 13, color: color)),
          ],
        ),
      ),
    );
  }

  /// Android-only export path invoked after [provider.stopRecording]
  /// returns.  Reads the closed tmp CSV from the app-private cache
  /// (DataLogger uses `path_provider` application support dir as the
  /// default when called with no `filePath`) and pops the system file
  /// picker via `FilePicker.saveFile(bytes:)` so the user can choose
  /// the destination (Downloads / external storage / cloud Drive
  /// etc.).  SAF writes the bytes there in one shot, then we delete
  /// the tmp file.  Cancelling the dialog leaves the tmp file alone
  /// (user can retry by re-starting STOP — no — actually the tmp
  /// file stays put; OS will sweep app-private cache eventually) and
  /// surfaces the cache path so the user knows where it lives.
  ///
  /// Filename is reused from [RecordingSession.startTime] so the
  /// exported file matches the in-app tmp name.
  Future<void> _exportAndroidRecording(
    BuildContext context,
    PowerSupplyProvider provider,
  ) async {
    final session = provider.recordingSession;
    final tmpPath = session.filePath;
    if (tmpPath == null) return;

    final File tmpFile;
    try {
      tmpFile = File(tmpPath);
      if (!tmpFile.existsSync()) return;
    } catch (_) {
      return;
    }

    Uint8List bytes;
    try {
      bytes = await tmpFile.readAsBytes();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to read recording: $e'),
        backgroundColor: AppTheme.errorRed,
        duration: const Duration(seconds: 3),
      ));
      return;
    }

    final startedAt = session.startTime ?? DateTime.now();
    String pad(int v) => v.toString().padLeft(2, '0');
    final name = 'riden_recording_'
        '${startedAt.year}${pad(startedAt.month)}${pad(startedAt.day)}_'
        '${pad(startedAt.hour)}${pad(startedAt.minute)}${pad(startedAt.second)}'
        '.csv';

    String? picked;
    try {
      picked = await FilePicker.platform.saveFile(
        dialogTitle: 'Save recording as…',
        fileName: name,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        lockParentWindow: true,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Export failed: $e'),
        backgroundColor: AppTheme.errorRed,
        duration: const Duration(seconds: 3),
      ));
      return;
    }

    if (picked == null) {
      // User cancelled the SAF picker — keep tmp file so the user can
      // pull it via adb / file manager.  Surface the cache path.
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Recording kept in app cache:\n$tmpPath'),
        backgroundColor: AppTheme.textDim,
        duration: const Duration(seconds: 4),
      ));
      return;
    }

    // SAF has written `bytes` to `picked`.  Optionally delete the
    // tmp file — silent if cleanup fails (OS sweeps app-private cache
    // eventually).
    try {
      await tmpFile.delete();
    } catch (_) {}

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Recording saved to:\n$picked'),
      backgroundColor: AppTheme.voltGreen,
      duration: const Duration(seconds: 4),
    ));
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool small;
  const _InfoRow({required this.label, required this.value, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Text(label,
              style: AppTheme.digitalLabel.copyWith(
                  fontSize: small ? 10 : 11, color: AppTheme.textDim)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: AppTheme.bodyMono.copyWith(
                    fontSize: small ? 10 : 12, color: AppTheme.textPrimary)),
          ),
        ],
      ),
    );
  }
}
