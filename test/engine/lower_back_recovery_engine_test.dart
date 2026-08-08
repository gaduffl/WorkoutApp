import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/engine/lower_back_recovery_engine.dart';
import 'package:morningcoach/models/equipment.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/movement_pattern.dart';

void main() {
  const engine = LowerBackRecoveryEngine();
  final today = DateTime(2026, 8, 8);

  LowerBackRecoveryState activeState({
    LowerBackRecoveryStage stage = LowerBackRecoveryStage.isometricHold,
    int holdSeconds = 30,
    int dynamicReps = 6,
    int tolerated = 0,
    List<DateTime> sessionDates = const [],
  }) =>
      LowerBackRecoveryState(
        active: true,
        activatedAt: today.subtract(const Duration(days: 1)),
        symptomOnsetDate: today.subtract(const Duration(days: 21)),
        neurologicalSymptomsAbsentConfirmedAt: today,
        stage: stage,
        targetHoldSeconds: holdSeconds,
        targetDynamicReps: dynamicReps,
        consecutiveToleratedSessions: tolerated,
        recoverySessionDates: sessionDates,
        preRecoveryHingeLoad: 90,
        preRecoveryHingeLadderStepIndex: 0,
      );

  test('activation snapshots hinge state and starts at a conservative hold',
      () {
    final state = engine.activate(
      now: today,
      symptomOnsetDate: today.subtract(const Duration(days: 21)),
      hingeState: ExerciseState(
        trackKey: MovementPattern.hinge.name,
        pattern: MovementPattern.hinge,
        currentLoad: 90,
        ladderStepIndex: 2,
      ),
    );

    expect(state.active, isTrue);
    expect(state.stage, LowerBackRecoveryStage.isometricHold);
    expect(state.targetHoldSeconds, 30);
    expect(state.preRecoveryHingeLoad, 90);
    expect(state.preRecoveryHingeLadderStepIndex, 2);
    expect(engine.isSessionDue(state, today), isTrue);
  });

  test('recovery work is capped at twice per rolling week and spaced 48h',
      () {
    final yesterday = activeState(
      sessionDates: [today.subtract(const Duration(days: 1))],
    );
    expect(engine.isSessionDue(yesterday, today), isFalse);

    final twiceThisWeek = activeState(
      sessionDates: [
        today.subtract(const Duration(days: 5)),
        today.subtract(const Duration(days: 2)),
      ],
    );
    expect(engine.isSessionDue(twiceThisWeek, today), isFalse);

    final oldSessions = activeState(
      sessionDates: [
        today.subtract(const Duration(days: 9)),
        today.subtract(const Duration(days: 7)),
      ],
    );
    expect(engine.isSessionDue(oldSessions, today), isTrue);
  });

  test('same-day completion alone never advances recovery', () {
    final completed = engine.recordSession(
      activeState(),
      sessionDate: today,
      sameDayResponse: LowerBackSymptomResponse.unchanged,
    );

    expect(completed.targetHoldSeconds, 30);
    expect(completed.consecutiveToleratedSessions, 0);
    expect(completed.awaitingNextMorningResponse, isTrue);
    expect(engine.isSessionDue(completed, today.add(const Duration(days: 2))),
        isFalse);
  });

  test('two tolerated next-morning responses advance one small step', () {
    var state = activeState();
    for (final date in [today, today.add(const Duration(days: 3))]) {
      state = engine.recordSession(
        state,
        sessionDate: date,
        sameDayResponse: LowerBackSymptomResponse.unchanged,
      );
      state = engine.recordNextMorningResponse(
        state,
        response: LowerBackSymptomResponse.better,
        responseDate: date.add(const Duration(days: 1)),
      );
    }

    expect(state.targetHoldSeconds, 40);
    expect(state.consecutiveToleratedSessions, 0);
    expect(state.awaitingNextMorningResponse, isFalse);
  });

  test('a worse response regresses the dose and resets tolerance', () {
    final pending = engine.recordSession(
      activeState(holdSeconds: 50, tolerated: 1),
      sessionDate: today,
      sameDayResponse: LowerBackSymptomResponse.unchanged,
    );
    final next = engine.recordNextMorningResponse(
      pending,
      response: LowerBackSymptomResponse.worse,
      responseDate: today.add(const Duration(days: 1)),
    );

    expect(next.stage, LowerBackRecoveryStage.isometricHold);
    expect(next.targetHoldSeconds, 40);
    expect(next.consecutiveToleratedSessions, 0);
  });

  test('stage progression reaches unloaded dynamics then deadlift re-entry',
      () {
    var state = activeState(holdSeconds: 60, tolerated: 1);
    state = engine.recordSession(
      state,
      sessionDate: today,
      sameDayResponse: LowerBackSymptomResponse.unchanged,
    );
    state = engine.recordNextMorningResponse(
      state,
      response: LowerBackSymptomResponse.unchanged,
      responseDate: today.add(const Duration(days: 1)),
    );
    expect(state.stage, LowerBackRecoveryStage.dynamicUnloaded);
    expect(state.targetDynamicReps, 6);

    state = state.copyWith(
      targetDynamicReps: 12,
      consecutiveToleratedSessions: 1,
    );
    state = engine.recordSession(
      state,
      sessionDate: today.add(const Duration(days: 3)),
      sameDayResponse: LowerBackSymptomResponse.unchanged,
    );
    state = engine.recordNextMorningResponse(
      state,
      response: LowerBackSymptomResponse.better,
      responseDate: today.add(const Duration(days: 4)),
    );
    expect(state.stage, LowerBackRecoveryStage.deadliftReentry);
    expect(state.active, isTrue);
  });

  test('prescriptions are unweighted until the explicit 50% re-entry', () {
    final hold = engine.prescriptionFor(
      activeState(),
      today: today,
      equipment: const EquipmentConfig(),
    )!;
    expect(hold.trackKey, lowerBackRecoveryTrackKey);
    expect(hold.metric, ExerciseMetric.seconds);
    expect(hold.sets, 3);
    expect(hold.suggestedValue, 30);
    expect(hold.loadTotal, isNull);
    expect(hold.progressionEligible, isFalse);

    final dynamic = engine.prescriptionFor(
      activeState(stage: LowerBackRecoveryStage.dynamicUnloaded),
      today: today,
      equipment: const EquipmentConfig(),
    )!;
    expect(dynamic.metric, ExerciseMetric.reps);
    expect(dynamic.sets, 2);
    expect(dynamic.targetRange, (6, 6));
    expect(dynamic.loadTotal, isNull);

    final reentry = engine.prescriptionFor(
      activeState(stage: LowerBackRecoveryStage.deadliftReentry),
      today: today,
      equipment: const EquipmentConfig(),
    )!;
    expect(reentry.name, contains('deadlift re-entry'));
    expect(reentry.sets, 1);
    expect(reentry.targetRange, (8, 8));
    expect(reentry.loadTotal, 42);
    expect(reentry.dumbbellCount, 2);
  });
}
