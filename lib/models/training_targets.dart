import 'dart:collection';

/// Muscle groups whose direct and indirect work will be tracked by the
/// stimulus ledger and Decision Engine v2.
enum MajorMuscleGroup {
  quads,
  glutes,
  hamstrings,
  chest,
  back,
  delts,
  biceps,
  triceps,
  coreGrip,
}

/// Weekly-equivalent hypertrophy dose target for one muscle group.
class EffectiveSetTargetBand {
  final double minimum;
  final double center;
  final double maximum;

  const EffectiveSetTargetBand({
    required this.minimum,
    required this.center,
    required this.maximum,
  })  : assert(minimum >= 0),
        assert(center >= minimum),
        assert(maximum >= center);

  double minimumForWindow(int days) => minimum * days / 7;
  double centerForWindow(int days) => center * days / 7;
  double maximumForWindow(int days) => maximum * days / 7;
}

/// Personal, app-level training targets.
///
/// These are optimization targets for the owner of the app, not population
/// activity guidelines. They are deliberately separate from recommendation
/// logic so the recommendation policy can be tested against an immutable,
/// explicit target set.
class TrainingTargets {
  static const EffectiveSetTargetBand defaultHypertrophyBand =
      EffectiveSetTargetBand(minimum: 8, center: 10, maximum: 12);

  final List<int> _hardTimeWindowsMinutes;
  final Map<MajorMuscleGroup, EffectiveSetTargetBand>
      _hypertrophyTargetBands;

  final int hypertrophyEvaluationWindowDays;
  final int intensityRollingWindowDays;
  final int highIntensityDistinctDaysTarget;
  final int preferredNorwegian4x4Exposures;
  final int baseAerobicRollingWindowDays;
  final int baseLongExposureCount;
  final int baseLongExposureMinutes;

  TrainingTargets({
    List<int> hardTimeWindowsMinutes = const [0, 20, 35, 60],
    Map<MajorMuscleGroup, EffectiveSetTargetBand>?
        hypertrophyTargetBands,
    this.hypertrophyEvaluationWindowDays = 28,
    this.intensityRollingWindowDays = 7,
    this.highIntensityDistinctDaysTarget = 3,
    this.preferredNorwegian4x4Exposures = 1,
    this.baseAerobicRollingWindowDays = 7,
    this.baseLongExposureCount = 1,
    this.baseLongExposureMinutes = 60,
  })  : _hardTimeWindowsMinutes =
            List<int>.unmodifiable(hardTimeWindowsMinutes),
        _hypertrophyTargetBands =
            Map<MajorMuscleGroup, EffectiveSetTargetBand>.unmodifiable(
          {
            for (final group in MajorMuscleGroup.values)
              group: defaultHypertrophyBand,
            ...?hypertrophyTargetBands,
          },
        ),
        assert(hardTimeWindowsMinutes.isNotEmpty),
        assert(hardTimeWindowsMinutes.every((minutes) => minutes >= 0)),
        assert(hardTimeWindowsMinutes.contains(0)),
        assert(hypertrophyEvaluationWindowDays > 0),
        assert(intensityRollingWindowDays > 0),
        assert(highIntensityDistinctDaysTarget > 0),
        assert(preferredNorwegian4x4Exposures > 0),
        assert(baseAerobicRollingWindowDays > 0),
        assert(baseLongExposureCount > 0),
        assert(baseLongExposureMinutes > 0);

  List<int> get hardTimeWindowsMinutes =>
      UnmodifiableListView(_hardTimeWindowsMinutes);

  Map<MajorMuscleGroup, EffectiveSetTargetBand>
      get hypertrophyTargetBands =>
          UnmodifiableMapView(_hypertrophyTargetBands);
}
