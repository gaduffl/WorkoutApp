import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  test('travel context round-trips on plans and session logs', () {
    const plan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Strength — Lower',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 35,
      travelMode: true,
    );
    expect(sessionPlanFromJson(sessionPlanToJson(plan)).travelMode, isTrue);

    final log = SessionLog(
      id: 'travel-session',
      templateId: SessionTypeId.s1,
      tier: SessionTier.full,
      date: DateTime(2026, 7, 12),
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: 35,
      countsAs: const {FloorCategory.strength},
      travelMode: true,
    );
    expect(sessionLogFromJson(sessionLogToJson(log)).travelMode, isTrue);
  });

  test('older persisted data defaults travel context to false', () {
    final planJson = sessionPlanToJson(const SessionPlan(
      sessionId: SessionTypeId.s6,
      sessionName: 'Zone 2',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 35,
    ))..remove('travelMode');

    expect(sessionPlanFromJson(planJson).travelMode, isFalse);
  });

  test('timed set metrics and values round-trip', () {
    final logged = SetLog(
      trackKey: 'coreGrip',
      pattern: MovementPattern.coreGrip,
      exerciseName: 'Plank',
      weight: 0,
      metric: ExerciseMetric.seconds,
      value: 35,
      rir: Rir.rir2,
      timestamp: DateTime(2026, 7, 15),
    );

    final restored = setLogFromJson(setLogToJson(logged));
    expect(restored.metric, ExerciseMetric.seconds);
    expect(restored.value, 35);
  });

  test('legacy rep-only sets and plans remain readable', () {
    final legacySet = setLogToJson(SetLog(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      exerciseName: 'Goblet squat',
      weight: 24,
      value: 10,
      rir: Rir.rir2,
      timestamp: DateTime(2026, 7, 15),
    ))
      ..remove('metric')
      ..remove('value');
    final restoredSet = setLogFromJson(legacySet);
    expect(restoredSet.metric, ExerciseMetric.reps);
    expect(restoredSet.value, 10);

    final legacyPlan = plannedExerciseToJson(const PlannedExercise(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      name: 'Goblet squat',
      sets: 3,
      targetRange: (6, 10),
      rirTarget: Rir.rir2,
    ))
      ..remove('metric')
      ..remove('targetRangeLow')
      ..remove('targetRangeHigh');
    final restoredPlan = plannedExerciseFromJson(legacyPlan);
    expect(restoredPlan.metric, ExerciseMetric.reps);
    expect(restoredPlan.targetRange, (6, 10));
  });

  test('duration-budget metadata round-trips and remains legacy-safe', () {
    const compound = PlannedExercise(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      name: 'DB deadlift',
      sets: 3,
      targetRange: (6, 10),
      rirTarget: Rir.rir2,
      isCompoundWork: true,
    );
    const feeder = PlannedExercise(
      trackKey: 'row',
      pattern: MovementPattern.pullHorizontal,
      name: 'DB row - warm-up 60%',
      sets: 1,
      targetRange: (5, 5),
      rirTarget: Rir.rir3plus,
      isWarmup: true,
      isFeederWarmup: true,
    );
    expect(
      plannedExerciseFromJson(plannedExerciseToJson(compound)).isCompoundWork,
      isTrue,
    );
    expect(
      plannedExerciseFromJson(plannedExerciseToJson(feeder)).isFeederWarmup,
      isTrue,
    );

    final json = plannedExerciseToJson(compound)
      ..remove('isCompoundWork')
      ..remove('isFeederWarmup');
    final legacy = plannedExerciseFromJson(json);
    expect(legacy.isCompoundWork, isTrue);
    expect(legacy.isFeederWarmup, isFalse);

    final explicitFalse = plannedExerciseToJson(compound)
      ..['isCompoundWork'] = false;
    expect(
      plannedExerciseFromJson(explicitFalse).isCompoundWork,
      isFalse,
    );

    final legacyNamed = plannedExerciseToJson(const PlannedExercise(
      trackKey: 'sub:pushVertical:lateral_raise',
      pattern: MovementPattern.pushVertical,
      name: 'Lateral raise',
      sets: 2,
      targetRange: (8, 15),
      rirTarget: Rir.rir2,
    ))..remove('isCompoundWork');
    expect(
      plannedExerciseFromJson(legacyNamed).isCompoundWork,
      isFalse,
    );
  });

  test('REHIT nudge state round-trips and malformed targets fail safely', () {
    final target = DateTime(2026, 7, 15, 15);
    final settings = UserSettings(
      secondRehitNudgeScheduledDay: '2026-07-15',
      secondRehitNudgeScheduledFor: target,
    );
    final json = userSettingsToJson(settings);
    final restored = userSettingsFromJson(json);
    expect(restored.secondRehitNudgeScheduledDay, '2026-07-15');
    expect(restored.secondRehitNudgeScheduledFor, target);

    json.remove('secondRehitNudgeScheduledDay');
    json.remove('secondRehitNudgeScheduledFor');
    final legacy = userSettingsFromJson(json);
    expect(legacy.secondRehitNudgeScheduledDay, isNull);
    expect(legacy.secondRehitNudgeScheduledFor, isNull);

    final malformedString = userSettingsToJson(settings)
      ..['secondRehitNudgeScheduledFor'] = 'not-a-timestamp';
    final restoredMalformedString = userSettingsFromJson(malformedString);
    expect(restoredMalformedString.secondRehitNudgeScheduledDay, '2026-07-15');
    expect(restoredMalformedString.secondRehitNudgeScheduledFor, isNull);

    final malformedType = userSettingsToJson(settings)
      ..['secondRehitNudgeScheduledFor'] = 12345;
    final restoredMalformedType = userSettingsFromJson(malformedType);
    expect(restoredMalformedType.secondRehitNudgeScheduledDay, '2026-07-15');
    expect(restoredMalformedType.secondRehitNudgeScheduledFor, isNull);
  });

  test('optional HRmax and API-key settings remain nullable and legacy-safe',
      () {
    final json = userSettingsToJson(const UserSettings(
      age: 45,
      hrMaxOverride: 185,
      anthropicApiKey: 'secret',
    ))
      ..remove('hrMaxOverride')
      ..remove('anthropicApiKey');

    final restored = userSettingsFromJson(json);
    expect(restored.hrMaxOverride, isNull);
    expect(restored.hrMax, 208 - 0.7 * 45);
    expect(restored.anthropicApiKey, isNull);
  });
}
