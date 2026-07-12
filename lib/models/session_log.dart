import 'floor_category.dart';
import 'session_type.dart';
import 'set_log.dart';

/// §2.4 / §8: planned vs completed exercises, completion ratio, duration.
class SessionLog {
  final String id;
  final SessionTypeId templateId;
  final SessionTier tier;
  final DateTime date;
  final List<SetLog> setLogs;

  /// Work sets planned in the *final emitted plan* (post compression,
  /// readiness cuts, pain substitutions) - §8's denominator.
  final int plannedWorkSets;
  final int completedWorkSets;
  final int durationMinutes;
  final String? notes;

  /// Resolved at completion: handles the conditional S2 intensity credit
  /// (only if the REHIT finisher was actually done, §2.1).
  final Set<FloorCategory> countsAs;
  final bool rehitFinisherCompleted;
  final bool travelMode;

  SessionLog({
    required this.id,
    required this.templateId,
    required this.tier,
    required this.date,
    required this.setLogs,
    required this.plannedWorkSets,
    required this.completedWorkSets,
    required this.durationMinutes,
    required this.countsAs,
    this.rehitFinisherCompleted = false,
    this.travelMode = false,
    this.notes,
  });

  double get completionRatio =>
      plannedWorkSets == 0 ? 1.0 : completedWorkSets / plannedWorkSets;

  /// §8: >=50% -> counts & queue advances; <50% -> partial, queue frozen.
  bool get countsTowardQueueAndFloor => completionRatio >= 0.5;
}
