import '../models/cardio_protocol.dart';
import '../models/stimulus_ledger.dart';
import '../models/training_status.dart';
import '../models/training_targets.dart';

/// Converts an observed stimulus ledger into target-relative deficits.
///
/// This is a pure status calculation. It deliberately does not select or rank
/// sessions; recommendation behavior remains owned by DecisionEngine.
class TrainingStatusEngine {
  const TrainingStatusEngine();

  TrainingStatus build({
    required TrainingTargets targets,
    required StimulusLedgerSnapshot ledger,
  }) {
    final muscleWindow = targets.hypertrophyEvaluationWindowDays;
    final muscle = [
      for (final group in MajorMuscleGroup.values)
        _muscleStatus(
          group: group,
          windowDays: muscleWindow,
          targets: targets,
          ledger: ledger,
        ),
    ];

    final intensityWindow = targets.intensityRollingWindowDays;
    final fourByFour =
        ledger.protocol(CardioProtocolType.norwegian4x4);
    final rehit = ledger.protocol(CardioProtocolType.rehit);
    final fourByFourCompleted = fourByFour.sessionsForWindow(intensityWindow);
    final rehitCompleted = rehit.sessionsForWindow(intensityWindow);
    final rehitDistinctDays = rehit.separateDaysForWindow(intensityWindow);
    final fallbackDistinctDayTarget = targets.fallbackRehitRequiresSeparateDays
        ? targets.fallbackRehitExposures
        : 0;

    final baseWindow = targets.baseAerobicRollingWindowDays;
    final base = ledger.protocol(CardioProtocolType.zone2Base);
    final baseDurations = base.sessionDurationsForWindow(baseWindow);
    final longQualified = baseDurations
        .where(
          (duration) => duration >= targets.baseLongExposureMinutes,
        )
        .length;
    final allocatedToLong = longQualified < targets.baseLongExposureCount
        ? longQualified
        : targets.baseLongExposureCount;
    final shortThreshold = targets.baseShortExposureMinutes.reduce(
      (current, next) => current < next ? current : next,
    );
    final shortCandidates =
        baseDurations.where((duration) => duration >= shortThreshold).length -
            allocatedToLong;
    final shortQualifiedAfterLongAllocation =
        shortCandidates > 0 ? shortCandidates : 0;

    return TrainingStatus(
      asOf: ledger.asOf,
      muscleEvaluationWindowDays: muscleWindow,
      muscle: muscle,
      aerobic: [
        AerobicTrainingStatus(
          target: AerobicTargetKind.norwegian4x4Anchor,
          rollingWindowDays: intensityWindow,
          completedExposures: fourByFourCompleted,
          targetExposures: targets.preferredNorwegian4x4Exposures,
          exposureDeficit: _deficit(
            targets.preferredNorwegian4x4Exposures,
            fourByFourCompleted,
          ),
        ),
        AerobicTrainingStatus(
          target: AerobicTargetKind.rehitSeparateDayFallback,
          rollingWindowDays: intensityWindow,
          completedExposures: rehitCompleted,
          targetExposures: targets.fallbackRehitExposures,
          exposureDeficit: _deficit(
            targets.fallbackRehitExposures,
            rehitCompleted,
          ),
          completedDistinctDays: rehitDistinctDays,
          targetDistinctDays: fallbackDistinctDayTarget,
          distinctDayDeficit: _deficit(
            fallbackDistinctDayTarget,
            rehitDistinctDays,
          ),
        ),
        AerobicTrainingStatus(
          target: AerobicTargetKind.longBaseExposure,
          rollingWindowDays: baseWindow,
          completedExposures: allocatedToLong,
          targetExposures: targets.baseLongExposureCount,
          exposureDeficit: _deficit(
            targets.baseLongExposureCount,
            allocatedToLong,
          ),
        ),
        AerobicTrainingStatus(
          target: AerobicTargetKind.shortBaseExposure,
          rollingWindowDays: baseWindow,
          completedExposures: shortQualifiedAfterLongAllocation,
          targetExposures: targets.baseShortExposureCount,
          exposureDeficit: _deficit(
            targets.baseShortExposureCount,
            shortQualifiedAfterLongAllocation,
          ),
        ),
      ],
    );
  }

  MuscleTrainingStatus _muscleStatus({
    required MajorMuscleGroup group,
    required int windowDays,
    required TrainingTargets targets,
    required StimulusLedgerSnapshot ledger,
  }) {
    final completed = ledger.muscle(group).effectiveSetsForWindow(windowDays);
    final band = targets.hypertrophyTargetBands[group]!;
    final minimum = band.minimumForWindow(windowDays);
    final center = band.centerForWindow(windowDays);
    final maximum = band.maximumForWindow(windowDays);
    return MuscleTrainingStatus(
      muscleGroup: group,
      completedEffectiveSets: completed,
      minimumTargetEffectiveSets: minimum,
      centerTargetEffectiveSets: center,
      maximumTargetEffectiveSets: maximum,
      deficitToMinimumEffectiveSets:
          minimum > completed ? minimum - completed : 0.0,
    );
  }

  int _deficit(int target, int completed) =>
      target > completed ? target - completed : 0;
}
