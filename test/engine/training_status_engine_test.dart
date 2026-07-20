import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/stimulus_ledger_engine.dart';
import 'package:morningcoach/engine/training_status_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/stimulus_ledger.dart';
import 'package:morningcoach/models/training_status.dart';
import 'package:morningcoach/models/training_targets.dart';

void main() {
  const ledgerEngine = StimulusLedgerEngine();
  const statusEngine = TrainingStatusEngine();
  final asOf = DateTime(2026, 7, 15, 12);

  TrainingStatus status(
    Iterable<AerobicStimulusEvent> aerobic, {
    Iterable<MuscleStimulusEvent> muscle = const [],
  }) =>
      statusEngine.build(
        targets: TrainingTargets(),
        ledger: ledgerEngine.build(
          muscleEvents: muscle,
          aerobicEvents: aerobic,
          asOf: asOf,
        ),
      );

  AerobicTrainingStatus target(TrainingStatus status, AerobicTargetKind kind) =>
      status.aerobic.firstWhere((value) => value.target == kind);

  test('empty history retains default 28-day muscle targets', () {
    final result = status(const []);
    expect(result.muscleEvaluationWindowDays, 28);
    expect(result.muscle, hasLength(MajorMuscleGroup.values.length));
    for (final muscle in result.muscle) {
      expect(muscle.completedEffectiveSets, 0);
      expect(muscle.minimumTargetEffectiveSets, 32);
      expect(muscle.centerTargetEffectiveSets, 40);
      expect(muscle.maximumTargetEffectiveSets, 48);
      expect(muscle.deficitToMinimumEffectiveSets, 32);
    }
  });

  test('28-day chest and back totals retain their effective-set deficits', () {
    final result = status(
      const [],
      muscle: [
        for (var i = 0; i < 30; i++)
          MuscleStimulusEvent(
            sourceId: 'chest-$i',
            performedAt: asOf.subtract(Duration(hours: i)),
            effectiveSets: const {MajorMuscleGroup.chest: 1},
          ),
        for (var i = 0; i < 40; i++)
          MuscleStimulusEvent(
            sourceId: 'back-$i',
            performedAt: asOf.subtract(Duration(hours: i)),
            effectiveSets: const {MajorMuscleGroup.back: 1},
          ),
      ],
    );
    final chest = result.muscle.firstWhere(
      (value) => value.muscleGroup == MajorMuscleGroup.chest,
    );
    final back = result.muscle.firstWhere(
      (value) => value.muscleGroup == MajorMuscleGroup.back,
    );
    expect(chest.completedEffectiveSets, 30);
    expect(chest.deficitToMinimumEffectiveSets, 2);
    expect(back.completedEffectiveSets, 40);
    expect(back.deficitToMinimumEffectiveSets, 0);
  });

  test('default targets expose three distinct high-intensity days and one 4x4 preference', () {
    final result = status(const []);
    expect(target(result, AerobicTargetKind.highIntensityDistinctDays).targetDistinctDays, 3);
    expect(target(result, AerobicTargetKind.highIntensityDistinctDays).distinctDayDeficit, 3);
    expect(target(result, AerobicTargetKind.norwegian4x4Preference).exposureDeficit, 1);
    expect(target(result, AerobicTargetKind.longBaseExposure).exposureDeficit, 1);
    expect(result.aerobic, hasLength(3));
  });

  test('4x4 plus two REHIT days satisfies the union frequency target', () {
    final result = status([
      AerobicStimulusEvent(sourceId: '4x4', protocol: CardioProtocolType.norwegian4x4, performedAt: asOf, durationMinutes: 35),
      AerobicStimulusEvent(sourceId: 'rehit-one', protocol: CardioProtocolType.rehit, performedAt: asOf.subtract(const Duration(days: 1)), durationMinutes: 10),
      AerobicStimulusEvent(sourceId: 'rehit-two', protocol: CardioProtocolType.rehit, performedAt: asOf.subtract(const Duration(days: 2)), durationMinutes: 10),
    ]);
    final intensity = target(result, AerobicTargetKind.highIntensityDistinctDays);
    expect(intensity.completedDistinctDays, 3);
    expect(intensity.distinctDayDeficit, 0);
    expect(target(result, AerobicTargetKind.norwegian4x4Preference).exposureDeficit, 0);
  });

  test('same-day high-intensity protocols count once and 4x4 plus REHIT leaves one day due', () {
    final result = status([
      AerobicStimulusEvent(sourceId: '4x4', protocol: CardioProtocolType.norwegian4x4, performedAt: asOf, durationMinutes: 35),
      AerobicStimulusEvent(sourceId: 'same-day-rehit', protocol: CardioProtocolType.rehit, performedAt: asOf, durationMinutes: 10),
      AerobicStimulusEvent(sourceId: 'next-day-rehit', protocol: CardioProtocolType.rehit, performedAt: asOf.subtract(const Duration(days: 1)), durationMinutes: 10),
    ]);
    final intensity = target(result, AerobicTargetKind.highIntensityDistinctDays);
    expect(intensity.completedDistinctDays, 2);
    expect(intensity.distinctDayDeficit, 1);
  });

  test('only a 60-minute session fills the sole continuous base target', () {
    TrainingStatus withBase(int minutes) => status([
          AerobicStimulusEvent(
            sourceId: 'base-$minutes',
            protocol: CardioProtocolType.zone2Base,
            performedAt: asOf,
            durationMinutes: minutes,
          ),
        ]);

    expect(
      target(withBase(35), AerobicTargetKind.longBaseExposure).exposureDeficit,
      1,
    );
    final sixty = target(withBase(60), AerobicTargetKind.longBaseExposure);
    expect(sixty.completedExposures, 1);
    expect(sixty.exposureDeficit, 0);
  });

  test('continuous base exposure count is capped at its configured target', () {
    final result = status([
      for (var day = 0; day < 2; day++)
        AerobicStimulusEvent(
          sourceId: 'base-$day',
          protocol: CardioProtocolType.zone2Base,
          performedAt: asOf.subtract(Duration(days: day)),
          durationMinutes: 60,
        ),
    ]);
    final base = target(result, AerobicTargetKind.longBaseExposure);
    expect(base.completedExposures, 1);
    expect(base.exposureDeficit, 0);
  });
}
