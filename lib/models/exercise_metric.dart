/// The value recorded for an exercise set or plan step.
///
/// Keep this explicit per exercise: a movement-pattern bucket can contain
/// both rep-based work (wrist curls) and timed holds (planks/hangs).
enum ExerciseMetric { reps, seconds, minutes }

extension ExerciseMetricX on ExerciseMetric {
  String get inputLabel => switch (this) {
        ExerciseMetric.reps => 'Reps',
        ExerciseMetric.seconds => 'Seconds',
        ExerciseMetric.minutes => 'Minutes',
      };

  String unitLabel(int value) => switch (this) {
        ExerciseMetric.reps => value == 1 ? 'rep' : 'reps',
        ExerciseMetric.seconds => value == 1 ? 'second' : 'seconds',
        ExerciseMetric.minutes => value == 1 ? 'minute' : 'minutes',
      };

  String formatRange((int, int) range) {
    final (low, high) = range;
    final value = low == high ? '$low' : '$low-$high';
    return '$value ${unitLabel(low == high ? low : high)}';
  }
}
