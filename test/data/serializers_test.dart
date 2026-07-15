import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';

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
}
