import 'dart:async';

enum TaskPriority {
  write(0), userRead(5), fastPoll(15), slowPoll(30), background(50);
  const TaskPriority(this.base);
  final int base;
  /// agingFactor = 0.0002 / ms ≈ 0.2 / s  (spec range: 0.05–0.2/s)
  double effective(int waitMs) => base - 0.0002 * waitMs;
}

enum TaskState { pending, running, completed, cancelled, expired }

class TaskCancelled implements Exception {
  final String taskId;
  TaskCancelled(this.taskId);
  @override String toString() => 'TaskCancelled: $taskId';
}
class TaskExpired implements Exception {
  final String taskId;
  TaskExpired(this.taskId);
  @override String toString() => 'TaskExpired: $taskId';
}

class ModbusTask<T> {
  final String id;
  final TaskPriority priority;
  final String group;
  final String? dedupKey;
  final Duration? expireAfter;
  final DateTime createdAt = DateTime.now();
  final Completer<T> completer = Completer<T>();
  final Future<T> Function() _executor;

  TaskState _state = TaskState.pending;
  TaskState get state => _state;

  ModbusTask({
    required this.id,
    required this.priority,
    required Future<T> Function() execute,
    this.group = 'default',
    this.dedupKey,
    this.expireAfter,
  }) : _executor = execute;

  bool get isExpired =>
      expireAfter != null &&
      DateTime.now().difference(createdAt) > expireAfter!;

  int get waitMs => DateTime.now().difference(createdAt).inMilliseconds;

  double get effectivePriority => priority.effective(waitMs);

  Future<T> execute() => _executor();

  void markRunning() => _state = TaskState.running;
  void markCompleted() => _state = TaskState.completed;
  void markCancelled() {
    _state = TaskState.cancelled;
    if (!completer.isCompleted) completer.completeError(TaskCancelled(id));
  }
  void markExpired() {
    _state = TaskState.expired;
    if (!completer.isCompleted) completer.completeError(TaskExpired(id));
  }
}
