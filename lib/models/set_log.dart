import 'exercise_metric.dart';
import 'movement_pattern.dart';

/// Reps-in-reserve, §2.4 / §6 logger input.
enum Rir { rir0, rir1, rir2, rir3plus, rir4plus }

class SetLog {
  final String trackKey;
  final MovementPattern pattern;
  final String exerciseName;
  final double weight;
  final ExerciseMetric metric;
  final int value;
  final Rir rir;
  final bool painFlag;
  final bool isWarmup;
  final DateTime timestamp;

  /// When this step became the active one in the logger. Together with
  /// [timestamp] (submission) this bounds everything the set actually cost:
  /// the rest taken into it, the setup, and the execution.
  ///
  /// Null for sets logged before per-set timing existed, and for any set
  /// whose activation instant is unknown.
  final DateTime? startedAt;

  /// Prescribed rest (seconds) that was already counting down when this step
  /// became active — 0 when the previous step had no rest after it.
  ///
  /// Held separately from the measured cycle because the app cannot observe
  /// when the user *stopped* resting: prescribed rest is the only defensible
  /// boundary between "recovering" and "working" inside one cycle.
  final int? plannedRestSecondsBefore;

  const SetLog({
    required this.trackKey,
    required this.pattern,
    required this.exerciseName,
    required this.weight,
    required this.value,
    this.metric = ExerciseMetric.reps,
    required this.rir,
    this.painFlag = false,
    this.isWarmup = false,
    required this.timestamp,
    this.startedAt,
    this.plannedRestSecondsBefore,
  });

  /// Compatibility alias for older call sites and serialized history.
  int get reps => value;

  /// Total seconds this step occupied: rest into it, setup, and execution.
  /// Null when the set predates timing capture; negative spans (a clock
  /// change mid-session) collapse to null rather than lying.
  int? get cycleSeconds {
    final start = startedAt;
    if (start == null) return null;
    final seconds = timestamp.difference(start).inSeconds;
    return seconds < 0 ? null : seconds;
  }

  /// The part of the cycle covered by prescribed rest, capped by the cycle
  /// itself (finishing before the timer runs out is common).
  int? get restSeconds {
    final cycle = cycleSeconds;
    if (cycle == null) return null;
    final planned = plannedRestSecondsBefore ?? 0;
    return planned < cycle ? planned : cycle;
  }

  /// Everything in the cycle beyond the prescribed rest: walking to the rack,
  /// loading dumbbells, the working set itself, and any rest overrun. Named
  /// as an estimate because those parts are not separately observable.
  int? get activeSecondsEstimate {
    final cycle = cycleSeconds;
    if (cycle == null) return null;
    return cycle - restSeconds!;
  }
}
