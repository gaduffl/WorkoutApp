import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/engine/lower_back_recovery_engine.dart';
import 'package:morningcoach/models/equipment.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/movement_pattern.dart';

void main() {
  const engine = LowerBackRecoveryEngine();
  const equipment = EquipmentConfig();
  final today = DateTime(2026, 8, 8);

  LowerBackRecoveryState activeState({
    BackRebuildStage rebuildStage = BackRebuildStage.bridges,
    int goodMornings = 0,
    LowerBackRecoveryStage stage = LowerBackRecoveryStage.isometricHold,
    int holdSeconds = 30,
    int dynamicReps = 6,
    int tolerated = 0,
    List<DateTime> sessionDates = const [],
    BikeReturnStep bikeReturnStep = BikeReturnStep.walkOnly,
    double? preRecoveryHingeLoad = 90,
  }) => LowerBackRecoveryState(
    active: true,
    activatedAt: today.subtract(const Duration(days: 1)),
    symptomOnsetDate: today.subtract(const Duration(days: 21)),
    neurologicalSymptomsAbsentConfirmedAt: today,
    stage: stage,
    targetHoldSeconds: holdSeconds,
    targetDynamicReps: dynamicReps,
    consecutiveToleratedSessions: tolerated,
    recoverySessionDates: sessionDates,
    preRecoveryHingeLoad: preRecoveryHingeLoad,
    preRecoveryHingeLadderStepIndex: 2,
    rebuildStage: rebuildStage,
    rebuildGoodMornings: goodMornings,
    bikeReturnStep: bikeReturnStep,
  );

  BackCheckOutcome check(
    LowerBackRecoveryState state, {
    required DateTime sessionDate,
    BackRebuildExposure exposure = BackRebuildExposure.accessory,
    bool extension = false,
    bool painFlagged = false,
    LowerBackSymptomResponse response = LowerBackSymptomResponse.unchanged,
    bool capReached = false,
  }) {
    final pending = engine.recordRebuildSession(
      state,
      sessionDate: sessionDate,
      exposure: exposure,
      extension: extension,
      painFlagged: painFlagged,
    );
    return engine.recordNextMorningResponse(
      pending,
      response: response,
      responseDate: sessionDate.add(const Duration(days: 1)),
      stageCapReached: capReached,
    );
  }

  test('activation snapshots the hinge and starts at stage 1 with a walk', () {
    final state = engine.activate(
      now: today,
      symptomOnsetDate: today,
      hingeState: ExerciseState(
        trackKey: MovementPattern.hinge.name,
        pattern: MovementPattern.hinge,
        currentLoad: 90,
        ladderStepIndex: 2,
      ),
    );

    expect(state.active, isTrue);
    expect(state.rebuildStage, BackRebuildStage.bridges);
    expect(state.rebuildGoodMornings, 0);
    expect(state.bikeReturnStep, BikeReturnStep.walkOnly);
    expect(state.preRecoveryHingeLoad, 90);
    expect(state.preRecoveryHingeLadderStepIndex, 2);
    expect(engine.loadedStepFor(state), isNull);
  });

  test('spaced exposures are capped at twice per rolling week, 48h apart', () {
    expect(
      engine.isSessionDue(
        activeState(sessionDates: [today.subtract(const Duration(days: 1))]),
        today,
      ),
      isFalse,
    );
    expect(
      engine.isSessionDue(
        activeState(
          sessionDates: [
            today.subtract(const Duration(days: 5)),
            today.subtract(const Duration(days: 2)),
          ],
        ),
        today,
      ),
      isFalse,
    );
    expect(
      engine.isSessionDue(
        activeState(
          sessionDates: [
            today.subtract(const Duration(days: 9)),
            today.subtract(const Duration(days: 7)),
          ],
        ),
        today,
      ),
      isTrue,
    );
  });

  test('completion alone never advances a stage', () {
    final pending = engine.recordRebuildSession(
      activeState(),
      sessionDate: today,
      exposure: BackRebuildExposure.accessory,
      extension: false,
      painFlagged: false,
    );
    expect(pending.rebuildStage, BackRebuildStage.bridges);
    expect(pending.rebuildGoodMornings, 0);
    expect(pending.awaitingNextMorningResponse, isTrue);
    expect(pending.pendingRebuildExposure, BackRebuildExposure.accessory);
    // Bridges are not a spaced exposure.
    expect(pending.recoverySessionDates, isEmpty);

    final sameDay = engine.recordNextMorningResponse(
      pending,
      response: LowerBackSymptomResponse.better,
      responseDate: today,
    );
    expect(sameDay.state, pending);
  });

  test('two good mornings after stage-1 work open deadlifts from blocks', () {
    var outcome = check(activeState(), sessionDate: today);
    expect(outcome.state.rebuildStage, BackRebuildStage.bridges);
    expect(outcome.state.rebuildGoodMornings, 1);
    expect(outcome.state.awaitingNextMorningResponse, isFalse);

    outcome = check(
      outcome.state,
      sessionDate: today.add(const Duration(days: 2)),
      response: LowerBackSymptomResponse.better,
    );
    expect(outcome.state.rebuildStage, BackRebuildStage.blockDeadlift);
    expect(outcome.state.rebuildGoodMornings, 0);
    expect(outcome.finished, isFalse);
    expect(engine.loadedStepFor(outcome.state), backRebuildBlockDeadlift);
  });

  test('loaded stages need their cap and two good loaded mornings', () {
    final block = activeState(rebuildStage: BackRebuildStage.blockDeadlift);

    // A good morning after bridge-only work neither counts nor advances.
    var outcome = check(block, sessionDate: today);
    expect(outcome.state.rebuildGoodMornings, 0);

    outcome = check(
      block,
      sessionDate: today,
      exposure: BackRebuildExposure.loaded,
    );
    expect(outcome.state.rebuildGoodMornings, 1);
    expect(outcome.state.recoverySessionDates, [today]);

    // Two good loaded mornings below the cap keep the stage.
    outcome = check(
      outcome.state,
      sessionDate: today.add(const Duration(days: 3)),
      exposure: BackRebuildExposure.loaded,
    );
    expect(outcome.state.rebuildStage, BackRebuildStage.blockDeadlift);
    expect(outcome.state.rebuildGoodMornings, 2);

    outcome = check(
      outcome.state,
      sessionDate: today.add(const Duration(days: 7)),
      exposure: BackRebuildExposure.loaded,
      capReached: true,
    );
    expect(outcome.state.rebuildStage, BackRebuildStage.romanianDeadlift);
    expect(outcome.state.rebuildGoodMornings, 0);
  });

  test('the Romanian deadlift stage finishes the rebuild', () {
    final outcome = check(
      activeState(
        rebuildStage: BackRebuildStage.romanianDeadlift,
        goodMornings: 1,
        bikeReturnStep: BikeReturnStep.zone2Ride,
      ),
      sessionDate: today,
      exposure: BackRebuildExposure.loaded,
      capReached: true,
    );
    expect(outcome.finished, isTrue);
    expect(outcome.state.active, isFalse);
    expect(outcome.state.completedAt, isNotNull);
    // The bike return continues on its own after the hinge lane finishes.
    expect(outcome.state.bikeReturnStep, BikeReturnStep.zone2Ride);
  });

  test('a worse morning steps back one stage and resets good mornings', () {
    final outcome = check(
      activeState(
        rebuildStage: BackRebuildStage.romanianDeadlift,
        goodMornings: 1,
      ),
      sessionDate: today,
      exposure: BackRebuildExposure.loaded,
      response: LowerBackSymptomResponse.worse,
      capReached: true,
    );
    expect(outcome.state.rebuildStage, BackRebuildStage.blockDeadlift);
    expect(outcome.state.rebuildGoodMornings, 0);
    expect(outcome.steppedBackFrom, BackRebuildStage.romanianDeadlift);
    expect(outcome.finished, isFalse);

    final atStageOne = check(
      activeState(goodMornings: 1),
      sessionDate: today,
      response: LowerBackSymptomResponse.worse,
    );
    expect(atStageOne.state.rebuildStage, BackRebuildStage.bridges);
    expect(atStageOne.steppedBackFrom, isNull);
  });

  test('pain-flagged rebuild work is a setback whatever the morning says', () {
    final outcome = check(
      activeState(rebuildStage: BackRebuildStage.blockDeadlift),
      sessionDate: today,
      exposure: BackRebuildExposure.loaded,
      painFlagged: true,
      response: LowerBackSymptomResponse.better,
    );
    expect(outcome.state.rebuildStage, BackRebuildStage.bridges);
    expect(outcome.steppedBackFrom, BackRebuildStage.blockDeadlift);
  });

  test('stage loads derive from the preserved pre-rebuild load', () {
    final block = activeState(rebuildStage: BackRebuildStage.blockDeadlift);
    expect(
      engine.stageFloorLoad(block, backRebuildBlockDeadlift, equipment),
      42,
    );
    expect(engine.stageCapLoad(block, backRebuildBlockDeadlift, equipment), 60);
    expect(
      engine.stageFloorLoad(block, backRebuildRomanianDeadlift, equipment),
      60,
    );
    expect(
      engine.stageCapLoad(block, backRebuildRomanianDeadlift, equipment),
      90,
    );
    expect(
      engine.stageCapReached(
        block,
        ExerciseState(
          trackKey: backRebuildBlockDeadlift.trackKey,
          pattern: MovementPattern.hinge,
          currentLoad: 60,
        ),
        equipment,
      ),
      isTrue,
    );
    expect(engine.stageCapReached(block, null, equipment), isFalse);

    final unknown = activeState(
      rebuildStage: BackRebuildStage.blockDeadlift,
      preRecoveryHingeLoad: null,
    );
    expect(
      engine.stageCapLoad(unknown, backRebuildBlockDeadlift, equipment),
      12,
    );
  });

  test('back extensions stay unweighted and never become a deadlift', () {
    final hold = engine.prescriptionFor(
      activeState(),
      today: today,
      equipment: equipment,
    )!;
    expect(hold.trackKey, lowerBackRecoveryTrackKey);
    expect(hold.metric, ExerciseMetric.seconds);
    expect(hold.sets, 3);
    expect(hold.suggestedValue, 30);
    expect(hold.loadTotal, isNull);
    expect(hold.progressionEligible, isFalse);

    final legacyReentry = engine.prescriptionFor(
      activeState(stage: LowerBackRecoveryStage.deadliftReentry),
      today: today,
      equipment: equipment,
    )!;
    expect(legacyReentry.name, 'Controlled back extension (unweighted)');
    expect(legacyReentry.targetRange, (12, 12));
    expect(legacyReentry.loadTotal, isNull);
  });

  test('extension dose steps only after extension exposures', () {
    var state = activeState(holdSeconds: 50, tolerated: 1);
    // Bridge-only mornings leave the extension dose alone.
    state = check(state, sessionDate: today).state;
    expect(state.targetHoldSeconds, 50);

    state = check(
      state,
      sessionDate: today.add(const Duration(days: 2)),
      extension: true,
    ).state;
    expect(state.targetHoldSeconds, 60);
    expect(state.consecutiveToleratedSessions, 0);

    state = check(
      state,
      sessionDate: today.add(const Duration(days: 4)),
      extension: true,
      response: LowerBackSymptomResponse.worse,
    ).state;
    expect(state.targetHoldSeconds, 50);

    var dynamic = activeState(
      stage: LowerBackRecoveryStage.dynamicUnloaded,
      dynamicReps: 12,
      tolerated: 1,
    );
    dynamic = check(dynamic, sessionDate: today, extension: true).state;
    expect(dynamic.stage, LowerBackRecoveryStage.dynamicUnloaded);
    expect(dynamic.targetDynamicReps, 12);
    expect(dynamic.active, isTrue);
  });

  test('the bike returns one step per good morning after the right ride', () {
    LowerBackRecoveryState ride(
      LowerBackRecoveryState state,
      BikeExposure exposure, {
      LowerBackSymptomResponse response = LowerBackSymptomResponse.unchanged,
    }) {
      final pending = engine.recordBikeSession(
        state,
        sessionDate: today,
        exposure: exposure,
      );
      return engine
          .recordNextMorningResponse(
            pending,
            response: response,
            responseDate: today.add(const Duration(days: 1)),
          )
          .state;
    }

    var state = ride(activeState(), BikeExposure.easyRide);
    expect(state.bikeReturnStep, BikeReturnStep.zone2Ride);

    // An easy ride is not enough to open 4×4.
    state = ride(state, BikeExposure.easyRide);
    expect(state.bikeReturnStep, BikeReturnStep.zone2Ride);

    state = ride(state, BikeExposure.zone2Ride);
    expect(state.bikeReturnStep, BikeReturnStep.fourByFour);

    state = ride(
      state,
      BikeExposure.fourByFour,
      response: LowerBackSymptomResponse.worse,
    );
    expect(state.bikeReturnStep, BikeReturnStep.zone2Ride);

    state = ride(state, BikeExposure.zone2Ride);
    state = ride(state, BikeExposure.fourByFour);
    expect(state.bikeReturnStep, BikeReturnStep.complete);
    // Hinge stages are untouched by bike-only mornings.
    expect(state.rebuildStage, BackRebuildStage.bridges);

    final done = engine.recordBikeSession(
      state,
      sessionDate: today,
      exposure: BikeExposure.rehit,
    );
    expect(done.awaitingNextMorningResponse, isFalse);
  });

  test('ending the rebuild restores all cycling and clears pending checks', () {
    final pending = engine.recordRebuildSession(
      activeState(rebuildStage: BackRebuildStage.blockDeadlift),
      sessionDate: today,
      exposure: BackRebuildExposure.loaded,
      extension: false,
      painFlagged: false,
    );
    final ended = engine.deactivate(pending, now: today);
    expect(ended.active, isFalse);
    expect(ended.bikeReturnStep, BikeReturnStep.complete);
    expect(ended.awaitingNextMorningResponse, isFalse);
    expect(ended.pendingRebuildExposure, BackRebuildExposure.none);
  });
}
