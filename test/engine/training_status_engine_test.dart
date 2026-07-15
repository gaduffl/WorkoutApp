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

  TrainingStatus status({
    Iterable<MuscleStimulusEvent> muscle = const [],
    Iterable<AerobicStimulusEvent> aerobic = const [],
    TrainingTargets? targets,
  }) =>
      statusEngine.build(
        targets: targets ?? TrainingTargets(),
        ledger: ledgerEngine.build(
          muscleEvents: muscle,
          aerobicEvents: aerobic,
          asOf: asOf,
        ),
      );

  AerobicTrainingStatus aerobicStatus(
    TrainingStatus value,
    AerobicTargetKind kind,
  ) =>
      value.aerobic.firstWhere((entry) => entry.target == kind);

  test('empty history yields default 28-day muscle and cardio deficits', () {
    final result = status();

    expect(result.muscleEvaluationWindowDays, 28);
    expect(result.muscle.length, MajorMuscleGroup.values.length);
    for (final muscle in result.muscle) {
      expect(muscle.completedEffectiveSets, 0);
      expect(muscle.minimumTargetEffectiveSets, 32);
      expect(muscle.centerTargetEffectiveSets, 40);
      expect(muscle.maximumTargetEffectiveSets, 48);
      expect(muscle.deficitToMinimumEffectiveSets, 32);
    }

    final fourByFour = aerobicStatus(
      result,
      AerobicTargetKind.norwegian4x4Anchor,
    );
    expect(fourByFour.targetExposures, 1);
    expect(fourByFour.exposureDeficit, 1);

    final fallback = aerobicStatus(
      result,
      AerobicTargetKind.rehitSeparateDayFallback,
    );
    expect(fallback.targetExposures, 2);
    expect(fallback.exposureDeficit, 2);
    expect(fallback.targetDistinctDays, 2);
    expect(fallback.distinctDayDeficit, 2);

    expect(
      aerobicStatus(result, AerobicTargetKind.longBaseExposure)
          .exposureDeficit,
      1,
    );
    expect(
      aerobicStatus(result, AerobicTargetKind.shortBaseExposure)
          .exposureDeficit,
      1,
    );
  });

  test('28-day strength totals produce per-muscle target deficits', () {
    final result = status(
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
      (entry) => entry.muscleGroup == MajorMuscleGroup.chest,
    );
    final back = result.muscle.firstWhere(
      (entry) => entry.muscleGroup == MajorMuscleGroup.back,
    );
    expect(chest.completedEffectiveSets, 30);
    expect(chest.deficitToMinimumEffectiveSets, 2);
    expect(back.completedEffectiveSets, 40);
    expect(back.deficitToMinimumEffectiveSets, 0);
  });

  test('one REHIT does not satisfy 4x4 or either base target', () {
    final result = status(
      aerobic: [
        AerobicStimulusEvent(
          sourceId: 'rehit-only',
          protocol: CardioProtocolType.rehit,
          performedAt: asOf,
          durationMinutes: 10,
        ),
      ],
    );

    expect(
      aerobicStatus(result, AerobicTargetKind.norwegian4x4Anchor)
          .exposureDeficit,
      1,
    );
    final fallback = aerobicStatus(
      result,
      AerobicTargetKind.rehitSeparateDayFallback,
    );
    expect(fallback.exposureDeficit, 1);
    expect(fallback.distinctDayDeficit, 1);
    expect(
      aerobicStatus(result, AerobicTargetKind.longBaseExposure)
          .exposureDeficit,
      1,
    );
    expect(
      aerobicStatus(result, AerobicTargetKind.shortBaseExposure)
          .exposureDeficit,
      1,
    );
  });

  test('two same-day REHITs do not satisfy separate-day fallback', () {
    final result = status(
      aerobic: [
        for (final hour in const [8, 17])
          AerobicStimulusEvent(
            sourceId: 'rehit-$hour',
            protocol: CardioProtocolType.rehit,
            performedAt: DateTime(2026, 7, 14, hour),
            durationMinutes: 10,
          ),
      ],
    );
    final fallback = aerobicStatus(
      result,
      AerobicTargetKind.rehitSeparateDayFallback,
    );

    expect(fallback.completedExposures, 2);
    expect(fallback.exposureDeficit, 0);
    expect(fallback.completedDistinctDays, 1);
    expect(fallback.distinctDayDeficit, 1);
  });

  group('base exposure allocation', () {
    TrainingStatus withBaseDurations(List<int> durations) => status(
          aerobic: [
            for (var i = 0; i < durations.length; i++)
              AerobicStimulusEvent(
                sourceId: 'base-$i',
                protocol: CardioProtocolType.zone2Base,
                performedAt: asOf.subtract(Duration(hours: i)),
                durationMinutes: durations[i],
              ),
          ],
        );

    test('one 60-minute session fills long but leaves short deficit', () {
      final result = withBaseDurations([60]);
      expect(
        aerobicStatus(result, AerobicTargetKind.longBaseExposure)
            .exposureDeficit,
        0,
      );
      expect(
        aerobicStatus(result, AerobicTargetKind.shortBaseExposure)
            .exposureDeficit,
        1,
      );
    });

    test('one 60 plus one 35-minute session fills both targets', () {
      final result = withBaseDurations([60, 35]);
      expect(
        aerobicStatus(result, AerobicTargetKind.longBaseExposure)
            .exposureDeficit,
        0,
      );
      expect(
        aerobicStatus(result, AerobicTargetKind.shortBaseExposure)
            .exposureDeficit,
        0,
      );
    });

    test('two 60-minute sessions fill long and short without double counting', () {
      final result = withBaseDurations([60, 60]);
      final long = aerobicStatus(
        result,
        AerobicTargetKind.longBaseExposure,
      );
      final short = aerobicStatus(
        result,
        AerobicTargetKind.shortBaseExposure,
      );
      expect(long.completedExposures, 1);
      expect(long.exposureDeficit, 0);
      expect(short.completedExposures, 1);
      expect(short.exposureDeficit, 0);
    });
  });
}
