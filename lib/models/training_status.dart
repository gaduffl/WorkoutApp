import 'dart:collection';

import 'training_targets.dart';

/// Snapshot of one muscle group's dose and deficit. All values refer to the
/// enclosing [TrainingStatus.muscleEvaluationWindowDays].
class MuscleTrainingStatus {
  final MajorMuscleGroup muscleGroup;
  final double completedEffectiveSets;
  final double minimumTargetEffectiveSets;
  final double centerTargetEffectiveSets;
  final double maximumTargetEffectiveSets;
  final double deficitToMinimumEffectiveSets;

  const MuscleTrainingStatus({
    required this.muscleGroup,
    required this.completedEffectiveSets,
    required this.minimumTargetEffectiveSets,
    required this.centerTargetEffectiveSets,
    required this.maximumTargetEffectiveSets,
    required this.deficitToMinimumEffectiveSets,
  })  : assert(completedEffectiveSets >= 0),
        assert(minimumTargetEffectiveSets >= 0),
        assert(centerTargetEffectiveSets >= minimumTargetEffectiveSets),
        assert(maximumTargetEffectiveSets >= centerTargetEffectiveSets),
        assert(deficitToMinimumEffectiveSets >= 0);
}

enum AerobicTargetKind {
  norwegian4x4Anchor,
  rehitSeparateDayFallback,
  longBaseExposure,
  shortBaseExposure,
}

/// Snapshot of one aerobic target and its remaining exposure/day deficit.
///
/// Distinct-day values make the REHIT fallback representable without treating
/// two same-day sessions as equivalent to sessions on separate days.
class AerobicTrainingStatus {
  final AerobicTargetKind target;
  final int rollingWindowDays;
  final int completedExposures;
  final int targetExposures;
  final int exposureDeficit;
  final int completedDistinctDays;
  final int targetDistinctDays;
  final int distinctDayDeficit;

  const AerobicTrainingStatus({
    required this.target,
    required this.rollingWindowDays,
    required this.completedExposures,
    required this.targetExposures,
    required this.exposureDeficit,
    this.completedDistinctDays = 0,
    this.targetDistinctDays = 0,
    this.distinctDayDeficit = 0,
  })  : assert(rollingWindowDays > 0),
        assert(completedExposures >= 0),
        assert(targetExposures >= 0),
        assert(exposureDeficit >= 0),
        assert(completedDistinctDays >= 0),
        assert(targetDistinctDays >= 0),
        assert(distinctDayDeficit >= 0);
}

/// Read-only training-dose snapshot consumed by Decision Engine v2.
///
/// This file intentionally contains data only. Qualification and deficit
/// calculations remain in the pure ledger/status engines.
class TrainingStatus {
  final DateTime asOf;
  final int muscleEvaluationWindowDays;
  final List<MuscleTrainingStatus> _muscle;
  final List<AerobicTrainingStatus> _aerobic;

  TrainingStatus({
    required this.asOf,
    required this.muscleEvaluationWindowDays,
    required List<MuscleTrainingStatus> muscle,
    required List<AerobicTrainingStatus> aerobic,
  })  : _muscle = List<MuscleTrainingStatus>.unmodifiable(muscle),
        _aerobic = List<AerobicTrainingStatus>.unmodifiable(aerobic),
        assert(muscleEvaluationWindowDays > 0);

  List<MuscleTrainingStatus> get muscle => UnmodifiableListView(_muscle);
  List<AerobicTrainingStatus> get aerobic => UnmodifiableListView(_aerobic);
}
