import 'dart:async';
import 'package:flutter/foundation.dart';
import 'modbus_task.dart';

/// Central task scheduler.  Guarantees:
/// - One task executing at a time
/// - Priority + aging ordering
/// - Deduplication by dedupKey
/// - Group pause/resume
/// - Expiry of stale tasks
class ModbusScheduler {
  static const _verboseLog = false; // set true for per-task debug logs
  final List<ModbusTask> _pending = [];
  ModbusTask? _active;
  bool _running = false;
  final Set<String> _pausedGroups = {};

  // ── Public API ─────────────────────────────────────────────────

  /// Enqueue a task. Returns a Future that resolves when the task
  /// executes, fails, or is cancelled/expired.
  Future<T> enqueue<T>(ModbusTask<T> task) {
    // Dedup: cancel old tasks with same dedupKey (pending only — never running)
    if (task.dedupKey != null) {
      for (final t in _pending.toList()) {
        if (t.dedupKey == task.dedupKey && t.state == TaskState.pending) {
          if (_verboseLog) debugPrint('[SCHED] dedup key=${task.dedupKey}  old=${t.id}');
          t.markCancelled();
          _pending.remove(t);
        }
      }
    }

    _pending.add(task);
    if (_verboseLog) {
      debugPrint('[SCHED] enq   key=${task.dedupKey ?? task.id}  '
          'pri=${task.priority.base}  group=${task.group}  '
          'pending=${_pending.length}');
    }

    if (!_running) {
      _running = true;
      _processLoop();
    }
    return task.completer.future;
  }

  /// Pause all tasks in [group]. They stay in the queue but are skipped.
  void pauseGroup(String group) {
    _pausedGroups.add(group);
    debugPrint('[SCHED] pause  group=$group');
  }

  /// Resume all tasks in [group].
  void resumeGroup(String group) {
    _pausedGroups.remove(group);
    debugPrint('[SCHED] resume group=$group');
    if (!_running && _pending.any((t) => t.group == group)) {
      _running = true;
      _processLoop();
    }
  }

  /// Cancel all pending tasks in [group].
  void cancelGroup(String group) {
    for (final t in _pending.where((t) => t.group == group).toList()) {
      t.markCancelled();
      _pending.remove(t);
    }
  }

  Future<void> shutdown() async {
    for (final t in _pending.toList()) {
      t.markCancelled();
    }
    _pending.clear();
    _pausedGroups.clear();
    if (_active != null) {
      try {
        await _active!.completer.future.timeout(const Duration(milliseconds: 500));
      } catch (_) {}
    }
  }

  // ── Internal ───────────────────────────────────────────────────

  void _processLoop() {
    _running = true;
    Future.doWhile(() async {
      try {
        // Remove expired and cancelled
        _pending.removeWhere((t) {
          if (t.state != TaskState.pending) return true;
          if (t.isExpired) {
            if (_verboseLog) debugPrint('[SCHED] expire key=${t.dedupKey ?? "-"}  id=${t.id}');
            t.markExpired();
            return true;
          }
          return false;
        });

        // Skip paused groups
        final eligible = _pending
            .where((t) => !_pausedGroups.contains(t.group))
            .toList();
        if (eligible.isEmpty) {
          if (_pending.isEmpty) {
            _running = false;
            return false;
          }
          // All pending are paused — idle until resume
          await Future.delayed(const Duration(milliseconds: 50));
          return true;
        }

        // Sort by effective priority (ascending = highest pri first)
        eligible.sort((a, b) => a.effectivePriority.compareTo(b.effectivePriority));

        final task = eligible.first;
        _pending.remove(task);
        _active = task;
        task.markRunning();

        if (_verboseLog) {
          debugPrint('[SCHED] run   key=${task.dedupKey ?? task.id}  '
              'pri=${task.priority.base}  wait=${task.waitMs}ms  '
              'pending=${_pending.length}');
        }

        final sw = Stopwatch()..start();
        try {
          final result = await task.execute();
          sw.stop();
          task.markCompleted();
          if (_verboseLog) debugPrint('[SCHED] done  key=${task.dedupKey ?? task.id}  '
              'cost=${sw.elapsedMilliseconds}ms');
          if (!task.completer.isCompleted) {
            task.completer.complete(result);
          }
        } catch (e) {
          sw.stop();
          if (task.state == TaskState.running) {
            if (_verboseLog) debugPrint('[SCHED] FAIL  key=${task.dedupKey ?? task.id}  '
                'err=$e  cost=${sw.elapsedMilliseconds}ms');
            if (!task.completer.isCompleted) {
              task.completer.completeError(e);
            }
          }
        } finally {
          _active = null;
        }
        return true;
      } catch (e) {
        debugPrint('[SCHED] LOOP-ERROR $e');
        return _pending.isNotEmpty; // keep alive if work remains
      }
    }).catchError((e) {
      debugPrint('[SCHED] LOOP-FATAL $e');
      _running = false;
    });
  }

  // For debugging
  int get pendingCount => _pending.length;
  ModbusTask? get active => _active;
  bool get isIdle => _active == null && _pending.isEmpty;
}
