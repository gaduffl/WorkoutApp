/// Movement patterns from design doc §2.3. Each `ExerciseState` is tracked
/// per pattern per user (or per named substitute variant, see §7.1).
enum MovementPattern {
  squat,
  hinge,
  pushHorizontal,
  pushVertical,
  pullVertical,
  pullHorizontal,
  kneeHealth,
  coreGrip,
}

/// §6.1: compound patterns use 6-10 reps, accessories use 8-15.
/// Knee-health has no state machine (rep/ROM progression only).
enum PatternClass { compound, accessory, kneeHealth }

extension MovementPatternX on MovementPattern {
  PatternClass get patternClass {
    switch (this) {
      case MovementPattern.squat:
      case MovementPattern.hinge:
      case MovementPattern.pushHorizontal:
      case MovementPattern.pushVertical:
      case MovementPattern.pullVertical:
      case MovementPattern.pullHorizontal:
        return PatternClass.compound;
      case MovementPattern.kneeHealth:
        return PatternClass.kneeHealth;
      case MovementPattern.coreGrip:
        return PatternClass.accessory;
    }
  }

  /// (low, high) inclusive rep target range.
  (int, int) get repRange {
    switch (patternClass) {
      case PatternClass.compound:
        return (6, 10);
      case PatternClass.accessory:
        return (8, 15);
      case PatternClass.kneeHealth:
        return (0, 0);
    }
  }

  /// §6.4: ladder-jump load reduction differs by pattern group.
  double get ladderJumpReductionFraction {
    switch (this) {
      case MovementPattern.squat:
      case MovementPattern.hinge:
        return 0.30;
      default:
        return 0.20;
    }
  }

  bool get isLegHeavy =>
      this == MovementPattern.squat || this == MovementPattern.hinge;
}
