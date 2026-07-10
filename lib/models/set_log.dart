import 'movement_pattern.dart';

/// Reps-in-reserve, §2.4 / §6 logger input.
enum Rir { rir0, rir1, rir2, rir3plus, rir4plus }

class SetLog {
  final String trackKey;
  final MovementPattern pattern;
  final String exerciseName;
  final double weight;
  final int reps;
  final Rir rir;
  final bool painFlag;
  final bool isWarmup;
  final DateTime timestamp;

  const SetLog({
    required this.trackKey,
    required this.pattern,
    required this.exerciseName,
    required this.weight,
    required this.reps,
    required this.rir,
    this.painFlag = false,
    this.isWarmup = false,
    required this.timestamp,
  });
}
