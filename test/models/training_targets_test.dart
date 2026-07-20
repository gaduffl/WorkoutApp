import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/models/training_targets.dart';

void main() {
  test('personal defaults encode the fixed windows and target contract', () {
    final targets = TrainingTargets();

    expect(targets.hardTimeWindowsMinutes, [0, 20, 35, 60]);
    expect(targets.hypertrophyEvaluationWindowDays, 28);
    expect(
      targets.hypertrophyTargetBands.keys.toSet(),
      MajorMuscleGroup.values.toSet(),
    );
    for (final band in targets.hypertrophyTargetBands.values) {
      expect(band.minimum, 8);
      expect(band.center, 10);
      expect(band.maximum, 12);
      expect(band.centerForWindow(28), 40);
    }

    expect(targets.intensityRollingWindowDays, 7);
    expect(targets.highIntensityDistinctDaysTarget, 3);
    expect(targets.preferredNorwegian4x4Exposures, 1);
    expect(targets.baseAerobicRollingWindowDays, 7);
    expect(targets.baseLongExposureCount, 1);
    expect(targets.baseLongExposureMinutes, 60);
  });

  test('target collections cannot be mutated by consumers', () {
    final targets = TrainingTargets();

    expect(
      () => targets.hardTimeWindowsMinutes.add(90),
      throwsA(isA<UnsupportedError>()),
    );
    expect(
      () => targets.hypertrophyTargetBands[MajorMuscleGroup.chest] =
          const EffectiveSetTargetBand(minimum: 1, center: 2, maximum: 3),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
