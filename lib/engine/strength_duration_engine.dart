import '../models/exercise_metric.dart';
import '../models/plan.dart';

/// Exact movement-preparation allocation within the immutable hard windows.
/// S4's ATG block replaces general preparation, so the two values are never
/// added together.
class StrengthPrepPolicy {
  const StrengthPrepPolicy._();

  static int generalMinutes(int slotMinutes) => switch (slotMinutes) {
        20 => 3,
        35 => 5,
        60 => 6,
        _ => throw ArgumentError.value(
            slotMinutes,
            'slotMinutes',
            'Strength plans require a 20, 35, or 60 minute hard window',
          ),
      };

  static int atgMinutes(int slotMinutes) => switch (slotMinutes) {
        20 => 3,
        35 || 60 => 5,
        _ => throw ArgumentError.value(
            slotMinutes,
            'slotMinutes',
            'Strength plans require a 20, 35, or 60 minute hard window',
          ),
      };
}

/// Conservative, deterministic timing model for generated strength work.
///
/// General or ATG preparation uses the exact minutes in the plan. A load
/// ramp or feeder gets 30 seconds of work plus 45 seconds before the next
/// set. Rep-based work gets 45 seconds per set; timed work uses the upper
/// prescribed bound for every set. Straight compound work and complete
/// superset rounds receive 90 seconds of rest; straight accessory work gets
/// 60 seconds, matching the logger. The final work unit receives no rest,
/// and every work exercise receives a 30-second setup allowance.
class StrengthDurationEstimator {
  static const int loadWarmupWorkSeconds = 30;
  static const int loadWarmupRestSeconds = 45;
  static const int workSetSeconds = 45;
  static const int workRestSeconds = 90;
  static const int accessoryRestSeconds = 60;
  static const int exerciseTransitionSeconds = 30;

  const StrengthDurationEstimator();

  int estimateSeconds(List<PlannedExercise> exercises) {
    var seconds = 0;

    final work = exercises.where((exercise) => !exercise.isWarmup).toList();
    for (final exercise in exercises.where((exercise) => exercise.isWarmup)) {
      if (exercise.metric == ExerciseMetric.minutes) {
        seconds += exercise.targetRange.$2 * 60 * exercise.sets;
      } else {
        seconds += exercise.sets *
            (loadWarmupWorkSeconds + loadWarmupRestSeconds);
      }
    }

    seconds += work.fold<int>(
      0,
      (total, exercise) =>
          total + exercise.sets * _workSecondsPerSet(exercise),
    );

    final grouped = <int, List<PlannedExercise>>{};
    for (final exercise in work) {
      final group = exercise.supersetGroup;
      if (group == null) continue;
      grouped.putIfAbsent(group, () => <PlannedExercise>[]).add(exercise);
    }

    var restSeconds = work
        .where((exercise) => exercise.supersetGroup == null)
        .fold<int>(
          0,
          (total, exercise) =>
              total +
              exercise.sets *
                  (exercise.isCompoundWork
                      ? workRestSeconds
                      : accessoryRestSeconds),
        );
    for (final group in grouped.values) {
      final rounds = group
          .map((exercise) => exercise.sets)
          .fold<int>(0, (largest, sets) => sets > largest ? sets : largest);
      restSeconds += rounds * workRestSeconds;
    }
    if (work.isNotEmpty) {
      final last = work.last;
      restSeconds -= last.supersetGroup != null || last.isCompoundWork
          ? workRestSeconds
          : accessoryRestSeconds;
    }
    if (restSeconds > 0) seconds += restSeconds;
    seconds += work.length * exerciseTransitionSeconds;
    return seconds;
  }

  int estimateMinutes(List<PlannedExercise> exercises) =>
      (estimateSeconds(exercises) / 60).ceil();

  int _workSecondsPerSet(PlannedExercise exercise) => switch (exercise.metric) {
        ExerciseMetric.reps => workSetSeconds,
        ExerciseMetric.seconds => exercise.targetRange.$2,
        ExerciseMetric.minutes => exercise.targetRange.$2 * 60,
      };
}

class StrengthBudgetResult {
  final List<PlannedExercise> exercises;
  final int estimatedDurationMin;
  final bool fits;

  StrengthBudgetResult({
    required List<PlannedExercise> exercises,
    required this.estimatedDurationMin,
    required this.fits,
  }) : exercises = List.unmodifiable(exercises);
}

/// Fits a strength prescription to a hard time window without changing
/// recommendation scoring, progression, pain resolution, or queue credit.
///
/// Trimming removes later accessory exercises first, then reduces surviving
/// work sets one per exercise per pass (never below two for a compound or one
/// for an accessory), then removes later-compound feeder sets. The protected
/// first-compound ramp remains. If that meaningful minimum cannot fit, the
/// caller receives [fits] == false and must not emit an over-budget plan.
class StrengthDurationBudgeter {
  final StrengthDurationEstimator estimator;

  const StrengthDurationBudgeter({
    this.estimator = const StrengthDurationEstimator(),
  });

  StrengthBudgetResult fit({
    required List<PlannedExercise> exercises,
    required int slotMinutes,
  }) {
    final budgeted = List<PlannedExercise>.of(exercises);

    StrengthBudgetResult result() {
      final estimate = estimator.estimateMinutes(budgeted);
      return StrengthBudgetResult(
        exercises: budgeted,
        estimatedDurationMin: estimate,
        fits: estimate <= slotMinutes,
      );
    }

    var current = result();
    if (current.fits) return current;

    final accessories = budgeted
        .where((exercise) => !exercise.isWarmup && !exercise.isCompoundWork)
        .toList()
        .reversed;
    for (final accessory in accessories) {
      final workCount =
          budgeted.where((exercise) => !exercise.isWarmup).length;
      if (workCount <= 1) break;
      final index = budgeted.lastIndexOf(accessory);
      if (index < 0) continue;
      _removeWorkAndItsWarmups(budgeted, index);
      current = result();
      if (current.fits) return current;
    }

    var changed = true;
    while (!current.fits && changed) {
      changed = false;
      for (var i = 0; i < budgeted.length; i++) {
        final exercise = budgeted[i];
        if (exercise.isWarmup) continue;
        final minimumSets = exercise.isCompoundWork ? 2 : 1;
        if (exercise.sets <= minimumSets) continue;
        budgeted[i] = exercise.copyWith(sets: exercise.sets - 1);
        changed = true;
        current = result();
        if (current.fits) return current;
      }
    }

    for (var i = budgeted.length - 1; i >= 0 && !current.fits; i--) {
      if (!budgeted[i].isFeederWarmup) continue;
      budgeted.removeAt(i);
      current = result();
    }

    return current;
  }

  void _removeWorkAndItsWarmups(
    List<PlannedExercise> exercises,
    int workIndex,
  ) {
    final work = exercises.removeAt(workIndex);
    var cursor = workIndex - 1;
    while (cursor >= 0) {
      final candidate = exercises[cursor];
      if (!candidate.isWarmup ||
          candidate.metric == ExerciseMetric.minutes ||
          candidate.trackKey != work.trackKey) {
        break;
      }
      exercises.removeAt(cursor);
      cursor--;
    }
  }
}
