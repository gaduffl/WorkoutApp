import 'movement_pattern.dart';
import 'session_type.dart';
import 'set_log.dart';

class PlannedExercise {
  final String trackKey;
  final MovementPattern pattern;
  final String name;
  final int sets;
  final (int, int) repRange;
  final double? loadTotal;

  /// Human-readable load setup, e.g. "2x large @ 25 lb" or
  /// "L: 45 / R: 50, swap after each set" (§2.6 rule 1 & 3).
  final String? loadDisplay;
  final Rir rirTarget;
  final String? substitutedFrom;
  final bool isWarmup;
  final String? instruction;

  /// §6.6: detraining-adjusted loads become the new working load once the
  /// session is actually completed (otherwise the ramp would snap back to
  /// the pre-break load the very next day).
  final bool persistLoadOnCompletion;

  const PlannedExercise({
    required this.trackKey,
    required this.pattern,
    required this.name,
    required this.sets,
    required this.repRange,
    this.loadTotal,
    this.loadDisplay,
    required this.rirTarget,
    this.substitutedFrom,
    this.isWarmup = false,
    this.instruction,
    this.persistLoadOnCompletion = false,
  });
}

class SessionPlan {
  final SessionTypeId sessionId;
  final String sessionName;
  final SessionTier tier;
  final List<PlannedExercise> exercises;
  final int estimatedDurationMin;

  /// §2.1/§5 Step 6: readiness swaps (RED technique session) leave the
  /// original queue item pending — completing them grants no queue credit.
  final bool grantsQueueCredit;

  const SessionPlan({
    required this.sessionId,
    required this.sessionName,
    required this.tier,
    required this.exercises,
    required this.estimatedDurationMin,
    this.grantsQueueCredit = true,
  });

  int get plannedWorkSets =>
      exercises.where((e) => !e.isWarmup).fold(0, (sum, e) => sum + e.sets);
}

/// Non-workout outcomes: rest day, forced rest, "wrap up" style short plans
/// are still represented as a [SessionPlan] with sessionId == null via
/// [RestOutcome] instead, keeping the pure function's return type simple.
class RestOutcome {
  final String reason;
  final bool queueFrozen;
  const RestOutcome({required this.reason, this.queueFrozen = true});
}
