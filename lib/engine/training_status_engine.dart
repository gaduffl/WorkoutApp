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
    final fourByFourCompleted = fourByFour.sessionsForWindow(intensityWindow);
    final highIntensityDistinctDays = intensityWindow == 7
        ? ledger.highIntensityDistinctDays7d
        : intensityWindow == 28
            ? ledger.highIntensityDistinctDays28d
            : _distinctHighIntensityDays(ledger, intensityWindow);

    final baseWindow = targets.baseAerobicRollingWindowDays;
    final base = ledger.protocol(CardioProtocolType.zone2Base);
    final longQualified = base.sessionDurationsForWindow(baseWindow)
        .where(
          (duration) => duration >= targets.baseLongExposureMinutes,
        )
        .length;
    final allocatedToLong = longQualified < targets.baseLongExposureCount
        ? longQualified
        : targets.baseLongExposureCount;

    return TrainingStatus(
      asOf: ledger.asOf,
      muscleEvaluationWindowDays: muscleWindow,
      muscle: muscle,
      aerobic: [
        AerobicTrainingStatus(
          target: AerobicTargetKind.highIntensityDistinctDays,
          rollingWindowDays: intensityWindow,
          completedExposures: highIntensityDistinctDays,
          targetExposures: targets.highIntensityDistinctDaysTarget,
          exposureDeficit: _deficit(
            targets.highIntensityDistinctDaysTarget,
            highIntensityDistinctDays,
          ),
          distinctDayDeficit: _deficit(
            targets.highIntensityDistinctDaysTarget,
            highIntensityDistinctDays,
          ),
          completedDistinctDays: highIntensityDistinctDays,
          targetDistinctDays: targets.highIntensityDistinctDaysTarget,
        ),
        AerobicTrainingStatus(
          target: AerobicTargetKind.norwegian4x4Preference,
          rollingWindowDays: intensityWindow,
          completedExposures: fourByFourCompleted,
          targetExposures: targets.preferredNorwegian4x4Exposures,
          exposureDeficit: _deficit(
            targets.preferredNorwegian4x4Exposures,
            fourByFourCompleted,
          ),
          completedDistinctDays: highIntensityDistinctDays,
          targetDistinctDays: targets.highIntensityDistinctDaysTarget,
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

  int _distinctHighIntensityDays(StimulusLedgerSnapshot ledger, int days) {
    // Custom target windows are not currently user-editable; retain a stable
    // protocol-safe fallback instead of manufacturing a partial count.
    return days <= 7
        ? ledger.highIntensityDistinctDays7d
        : ledger.highIntensityDistinctDays28d;
  }
}
