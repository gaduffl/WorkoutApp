import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/engine/hov_foot_warmup_engine.dart';
import 'package:morningcoach/engine/stimulus_ledger_engine.dart';
import 'package:morningcoach/engine/strength_duration_engine.dart';
import 'package:morningcoach/models/hov_foot_warmup.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/training_targets.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  test('HOV setting defaults off and survives backup round trips', () {
    expect(
      userSettingsFromJson(
        userSettingsToJson(const UserSettings())
          ..remove('hovFootWarmupEnabled'),
      ).hovFootWarmupEnabled,
      isFalse,
    );
    final settings = const UserSettings().copyWith(hovFootWarmupEnabled: true);
    expect(
      userSettingsFromJson(userSettingsToJson(settings)).hovFootWarmupEnabled,
      isTrue,
    );
  });

  test('Phase 1 preserves two circuit rounds and three holds on EACH foot', () {
    final entries = const HovFootWarmupEngine().build();
    expect(entries.first.trackKey, HovFootWarmup.bridge);
    expect(entries.first.sets, 2);
    expect(entries.first.targetRange, (30, 30));
    expect(entries.skip(1).take(8).map((e) => e.trackKey), [
      for (var round = 0; round < 2; round++) ...[
        HovFootWarmup.roll,
        HovFootWarmup.hinge,
        HovFootWarmup.lifts,
        HovFootWarmup.steps,
      ],
    ]);
    expect(entries.skip(1).take(4).map((e) => e.targetRange.$1), [
      10,
      10,
      30,
      14,
    ]);
    for (final key in [HovFootWarmup.holdLeft, HovFootWarmup.holdRight]) {
      final holds = entries.where((e) => e.trackKey == key);
      expect(holds.fold<int>(0, (sum, e) => sum + e.sets), 3);
      expect(holds.every((e) => e.targetRange == (30, 30)), isTrue);
    }
    expect(entries.every((e) => !e.isWarmup && !e.progressionEligible), isTrue);
    expect(
      entries.every((e) => e.supersetGroup == null && !e.isCompoundWork),
      isTrue,
    );
  });

  test('budget never silently trims the prescribed HOV dose', () {
    final entries = const HovFootWarmupEngine().build();
    final result = const StrengthDurationBudgeter().fit(
      exercises: entries,
      slotMinutes: 5,
    );
    expect(result.fits, isFalse);
    expect(result.exercises, entries);
  });

  test(
    'maps foot work without granting coordination drills hypertrophy credit',
    () {
      const map = ExerciseMuscleMap();
      final entries = const HovFootWarmupEngine().build();
      final exposure = const MuscleExposureEngine().fromPlan(entries);
      for (final muscle in [
        MajorMuscleGroup.calves,
        MajorMuscleGroup.tibialis,
        MajorMuscleGroup.feet,
      ]) {
        expect(exposure.muscles[muscle], greaterThan(0));
        expect(TrainingTargets().hypertrophyTargetBands[muscle]!.minimum, 0);
      }
      expect(exposure.lowerBack, 0);
      SetLog set(String key, Rir rir) => SetLog(
        trackKey: key,
        pattern: MovementPattern.kneeHealth,
        exerciseName: key,
        weight: 0,
        value: 30,
        rir: rir,
        timestamp: DateTime(2026, 10, 28),
      );
      expect(
        map.contributionFor(
          set(HovFootWarmup.bridge, Rir.rir3plus),
        )[MajorMuscleGroup.calves],
        1,
      );
      expect(
        const TargetEffortPolicy().qualifies(
          set(HovFootWarmup.lifts, Rir.rir0),
        ),
        isFalse,
      );
      expect(
        const TargetEffortPolicy().qualifies(
          set(HovFootWarmup.holdLeft, Rir.rir3plus),
        ),
        isTrue,
      );
      expect(
        map.contributionFor(
          set(HovFootWarmup.holdLeft, Rir.rir3plus),
        )[MajorMuscleGroup.calves],
        .5,
      );
      expect(
        const TargetEffortPolicy().qualifies(
          set(HovFootWarmup.bridge, Rir.rir4plus),
        ),
        isFalse,
      );
    },
  );

  test('HOV alone does not satisfy the main strength set count', () {
    final entries = const HovFootWarmupEngine().build();
    // A paired left/right prescription must not inflate bilateral-equivalent dose.
    final strength = PlannedExercise(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      name: 'Goblet squat',
      sets: 2,
      targetRange: (6, 10),
      rirTarget: Rir.rir2,
    );
    expect(entries.where((e) => e.countsTowardStrengthCompletion), isEmpty);
    expect(strength.countsTowardStrengthCompletion, isTrue);
  });
}
