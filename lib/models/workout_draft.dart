import 'plan.dart';
import 'set_log.dart';

/// The last durable checkpoint of a strength workout. The plan is snapshotted
/// so a regenerated recommendation cannot change the meaning of saved sets.
class WorkoutDraft {
  final SessionPlan plan;
  final DateTime startedAt;
  final DateTime stepStartedAt;
  final bool superset;
  final int current;
  final List<SetLog> logged;
  final List<String> loggedKeys;
  final Map<int, double> weights;
  final int value;
  final Rir rir;
  final bool painFlag;
  final int plannedRestIntoStep;
  final DateTime? restEndsAt;
  final int holdSecondsLeft;
  final int holdTargetSeconds;
  final bool holdTimerUsed;
  final DateTime? holdEndsAt;
  final int warmupSecondsLeft;
  final DateTime? warmupEndsAt;

  const WorkoutDraft({
    required this.plan,
    required this.startedAt,
    required this.stepStartedAt,
    required this.superset,
    required this.current,
    required this.logged,
    required this.loggedKeys,
    required this.weights,
    required this.value,
    required this.rir,
    required this.painFlag,
    required this.plannedRestIntoStep,
    this.restEndsAt,
    required this.holdSecondsLeft,
    required this.holdTargetSeconds,
    required this.holdTimerUsed,
    this.holdEndsAt,
    required this.warmupSecondsLeft,
    this.warmupEndsAt,
  });
}
