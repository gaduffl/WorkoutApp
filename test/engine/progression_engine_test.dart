import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/intensity_recovery_policy.dart';
import 'package:morningcoach/engine/progression_engine.dart';
import 'package:morningcoach/models/equipment.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/set_log.dart';

void main() {
  const engine = ProgressionEngine();
  const cfg = EquipmentConfig();
  final today = DateTime(2026, 1, 20);

  SetLog set({required int reps, required Rir rir, double weight = 60}) => SetLog(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        exerciseName: 'DB RDL',
        weight: weight,
        value: reps,
        rir: rir,
        timestamp: today,
      );

  group('§6.2.5 middle zone', () {
    test('timed holds evaluate seconds against their per-step target', () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
      );
      final result = engine.evaluateSession(
        state,
        [
          SetLog(
            trackKey: 'coreGrip',
            pattern: MovementPattern.coreGrip,
            exerciseName: 'Plank',
            weight: 0,
            metric: ExerciseMetric.seconds,
            value: 60,
            rir: Rir.rir2,
            timestamp: today,
          ),
        ],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(engine.metricFor(state), ExerciseMetric.seconds);
      expect(engine.targetRangeFor(state), (20, 60));
      expect(engine.suggestedValueFor(state), 60);
      expect(result.microStepStage, 1);
    });

    test('warm-up logs never drive progression', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 60,
        ladderStepIndex: 2,
      );
      final result = engine.evaluateSession(
        state,
        [
          SetLog(
            trackKey: 'hinge',
            pattern: MovementPattern.hinge,
            exerciseName: 'DB RDL - warm-up 80%',
            weight: 50,
            value: 10,
            rir: Rir.rir4plus,
            isWarmup: true,
            timestamp: today,
          ),
        ],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentLoad, 60);
      expect(result.lastTrainedDate, isNull);
      expect(result.microStepStage, 0);
    });

    test('zero-value work never drives progression or training recency', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 60,
        ladderStepIndex: 2,
      );
      final result = engine.evaluateSession(
        state,
        [set(reps: 0, rir: Rir.rir4plus)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentLoad, 60);
      expect(result.lastTrainedDate, isNull);
      expect(result.status, ExerciseStatus.progress);
      expect(result.microStepStage, 0);
    });

    test('reps inside range with no RIR-0 set never progresses or holds', () {
      final state = ExerciseState(trackKey: 'hinge', pattern: MovementPattern.hinge, currentLoad: 60, ladderStepIndex: 2);
      final result = engine.evaluateSession(
        state,
        [set(reps: 8, rir: Rir.rir1), set(reps: 7, rir: Rir.rir2), set(reps: 8, rir: Rir.rir1)],
        equipmentConfig: cfg,
        sessionDate: today,
      );
      expect(result.status, ExerciseStatus.progress);
      expect(result.currentLoad, 60); // unchanged
      expect(result.consecutiveHoldCount, 0);
    });

    test('adopts the most recent user-adjusted work-set load', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 60,
        ladderStepIndex: 2,
      );
      final result = engine.evaluateSession(
        state,
        [
          set(reps: 8, rir: Rir.rir1, weight: 48),
          set(reps: 8, rir: Rir.rir1, weight: 50),
        ],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.status, ExerciseStatus.progress);
      expect(result.currentLoad, 50);
    });

    test('does not persist a logger weight for a bodyweight step', () {
      final state = ExerciseState(
        trackKey: 'pushHorizontal',
        pattern: MovementPattern.pushHorizontal,
      );
      final bodyweightSet = SetLog(
        trackKey: 'pushHorizontal',
        pattern: MovementPattern.pushHorizontal,
        exerciseName: 'Push-up',
        weight: 25,
        value: 8,
        rir: Rir.rir1,
        timestamp: today,
      );

      final result = engine.evaluateSession(
        state,
        [bodyweightSet],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentLoad, 0);
    });
  });

  group('§2.6 rule 2 increment guard inside the state machine', () {
    test('RIR 4+ qualifies for a top-of-range progression trigger', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 40,
        ladderStepIndex: 2,
      );

      final result = engine.evaluateSession(
        state,
        [set(reps: 10, rir: Rir.rir4plus, weight: 40)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentLoad, 42);
    });

    test('RIR 3+ and 4+ both qualify for the undershoot correction', () {
      for (final rir in [Rir.rir3plus, Rir.rir4plus]) {
        final state = ExerciseState(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          currentLoad: 40,
          ladderStepIndex: 2,
          awaitingUndershootCheck: true,
        );

        final result = engine.evaluateSession(
          state,
          [set(reps: 8, rir: rir, weight: 40)],
          equipmentConfig: cfg,
          sessionDate: today,
        );

        expect(result.currentLoad, 42, reason: '$rir should apply one increment');
        expect(result.awaitingUndershootCheck, isFalse);
      }
    });

    test('below-minimum work cannot pass the one-shot undershoot check', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 40,
        ladderStepIndex: 2,
        awaitingUndershootCheck: true,
      );

      final result = engine.evaluateSession(
        state,
        [set(reps: 4, rir: Rir.rir4plus, weight: 40)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentLoad, 40);
      expect(result.awaitingUndershootCheck, isFalse);
      expect(result.status, ExerciseStatus.hold);
      expect(result.consecutiveHoldCount, 1);
    });

    test('a >10% jump stalls one session on tempo before the load actually jumps', () {
      // Large-block-only rig so the canonical 30 -> 40 press example (+33%,
      // matching §2.6's illustrative jump) is unambiguous: with both blocks
      // in play, 36 (2x18 small) would be the finer next step, which the
      // guard would stall just the same (still a 20% jump) - large-only
      // isolates the exact figures the design doc calls out.
      const largeOnlyCfg = EquipmentConfig(blocks: [largePowerBlock]);
      var state = ExerciseState(trackKey: 'pushVertical', pattern: MovementPattern.pushVertical, currentLoad: 30);
      SetLog topSet() => SetLog(
            trackKey: 'pushVertical',
            pattern: MovementPattern.pushVertical,
            exerciseName: 'Standing DB press',
            weight: 30,
            value: 10,
            rir: Rir.rir2,
            timestamp: today,
          );

      state = engine.evaluateSession(state, [topSet(), topSet()], equipmentConfig: largeOnlyCfg, sessionDate: today);
      expect(state.currentLoad, 30, reason: 'guard should stall the jump for one session');
      expect(state.microStepStage, 1);

      state = engine.evaluateSession(state, [topSet(), topSet()], equipmentConfig: largeOnlyCfg, sessionDate: today);
      expect(state.currentLoad, 40, reason: 'second top-of-range session permits the jump');
      expect(state.microStepStage, 0);
    });
  });

  group('§6.2.3 regression', () {
    test('2 consecutive HOLD sessions with missed reps step back one increment', () {
      var state = ExerciseState(trackKey: 'hinge', pattern: MovementPattern.hinge, currentLoad: 60, ladderStepIndex: 2);
      final missed = [set(reps: 4, rir: Rir.rir1), set(reps: 4, rir: Rir.rir1)];

      state = engine.evaluateSession(state, missed, equipmentConfig: cfg, sessionDate: today);
      expect(state.status, ExerciseStatus.hold);

      state = engine.evaluateSession(state, missed, equipmentConfig: cfg, sessionDate: today.add(const Duration(days: 3)));
      expect(state.status, ExerciseStatus.regress);
      expect(state.currentLoad, lessThan(60));
    });

    test('bodyweight regression removes one active micro-progression', () {
      var state = ExerciseState(
        trackKey: 'pushHorizontal',
        pattern: MovementPattern.pushHorizontal,
        microStepStage: 2,
      );
      SetLog missed() => SetLog(
            trackKey: 'pushHorizontal',
            pattern: MovementPattern.pushHorizontal,
            exerciseName: 'Push-up',
            weight: 0,
            value: 2,
            rir: Rir.rir0,
            timestamp: today,
          );

      state = engine.evaluateSession(
        state,
        [missed()],
        equipmentConfig: cfg,
        sessionDate: today,
      );
      state = engine.evaluateSession(
        state,
        [missed()],
        equipmentConfig: cfg,
        sessionDate: today.add(const Duration(days: 3)),
      );

      expect(state.status, ExerciseStatus.regress);
      expect(state.microStepStage, 1);
      expect(state.ladderStepIndex, 0);
    });

    test('timed-hold regression returns to the prior final micro stage', () {
      var state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        ladderStepIndex: 1,
      );
      SetLog missedHold() => SetLog(
            trackKey: 'coreGrip',
            pattern: MovementPattern.coreGrip,
            exerciseName: 'L-sit progression',
            weight: 0,
            metric: ExerciseMetric.seconds,
            value: 5,
            rir: Rir.rir0,
            timestamp: today,
          );

      state = engine.evaluateSession(
        state,
        [missedHold()],
        equipmentConfig: cfg,
        sessionDate: today,
      );
      state = engine.evaluateSession(
        state,
        [missedHold()],
        equipmentConfig: cfg,
        sessionDate: today.add(const Duration(days: 3)),
      );

      expect(state.status, ExerciseStatus.regress);
      expect(state.microStepStage, 3);
      expect(state.ladderStepIndex, 0);
      expect(engine.ladderStepFor(state).name, 'Plank');
    });
  });

  group('§6.3 deload trigger', () {
    test('global deload materializes every built-in progressable track', () {
      final states = engine.forceGlobalDeloadForBuiltInTracks(const {});
      final expectedKeys = {
        'squat',
        'hinge',
        'pushHorizontal',
        'pushVertical',
        'pullVertical',
        'pullHorizontal',
        'coreGrip',
        dbCurl.trackKey,
        lateralRaise.trackKey,
        dip.trackKey,
      };

      expect(states.keys.toSet(), expectedKeys);
      expect(states, isNot(contains('kneeHealth')));
      expect(states, isNot(contains(bridgeHamstringCurl.trackKey)));
      expect(states, isNot(contains(lightSingleLegRdl.trackKey)));
      expect(states, isNot(contains(floorPress.trackKey)));
      expect(
        states.values,
        everyElement(
          isA<ExerciseState>()
              .having((state) => state.status, 'status', ExerciseStatus.deload)
              .having(
                (state) => state.deloadSessionsRemaining,
                'remaining touches',
                2,
              ),
        ),
      );
    });

    test('global materialization preserves existing pain and deload state', () {
      final flaggedAt = today.subtract(const Duration(days: 2));
      final historicalSubstitute = ExerciseState(
        trackKey: bridgeHamstringCurl.trackKey,
        pattern: bridgeHamstringCurl.pattern,
        currentLoad: 10,
        lastTrainedDate: flaggedAt,
      );
      final importedTrack = ExerciseState(
        trackKey: 'imported:custom-row',
        pattern: MovementPattern.pullHorizontal,
        ladderStepIndex: 2,
        currentLoad: 42,
        status: ExerciseStatus.hold,
      );
      final states = engine.forceGlobalDeloadForBuiltInTracks({
        'hinge': ExerciseState(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          ladderStepIndex: 3,
          currentLoad: 90,
          status: ExerciseStatus.hold,
          painFrozen: true,
          painSeverity: PainSeverity.sharp,
          painRegion: BodyRegion.lowerBack,
          painFlaggedDate: flaggedAt,
          painTags: const {PainTag.tingling},
          sessionsScheduledWhileFlagged: 1,
          prePainLoad: 100,
          prePainLadderStepIndex: 4,
        ),
        'squat': ExerciseState(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          currentLoad: 24,
          status: ExerciseStatus.deload,
          deloadSessionsRemaining: 1,
          preDeloadLoad: 24,
        ),
        bridgeHamstringCurl.trackKey: historicalSubstitute,
        importedTrack.trackKey: importedTrack,
      });

      final hinge = states['hinge']!;
      expect(hinge.status, ExerciseStatus.hold);
      expect(hinge.painFrozen, isTrue);
      expect(hinge.painSeverity, PainSeverity.sharp);
      expect(hinge.painRegion, BodyRegion.lowerBack);
      expect(hinge.painFlaggedDate, flaggedAt);
      expect(hinge.painTags, {PainTag.tingling});
      expect(hinge.sessionsScheduledWhileFlagged, 1);
      expect(hinge.prePainLoad, 100);
      expect(hinge.prePainLadderStepIndex, 4);
      expect(hinge.currentLoad, 90);
      expect(hinge.ladderStepIndex, 3);
      expect(states['squat']!.deloadSessionsRemaining, 1);
      expect(
        identical(
          states[bridgeHamstringCurl.trackKey],
          historicalSubstitute,
        ),
        isTrue,
      );
      expect(
        states[bridgeHamstringCurl.trackKey]!.status,
        ExerciseStatus.progress,
      );
      expect(states[bridgeHamstringCurl.trackKey]!.deloadSessionsRemaining, 0);
      expect(
        states[bridgeHamstringCurl.trackKey]!.preDeloadLoad,
        isNull,
      );
      expect(identical(states[importedTrack.trackKey], importedTrack), isTrue);
      expect(states[importedTrack.trackKey]!.status, ExerciseStatus.hold);
      expect(states[importedTrack.trackKey]!.currentLoad, 42);
    });

    test('global deload clears without ever scheduling a pain substitute', () {
      final historicalSubstitute = ExerciseState(
        trackKey: bridgeHamstringCurl.trackKey,
        pattern: bridgeHamstringCurl.pattern,
        currentLoad: 10,
        lastTrainedDate: today.subtract(const Duration(days: 30)),
      );
      final states = engine.forceGlobalDeloadForBuiltInTracks({
        historicalSubstitute.trackKey: historicalSubstitute,
      });
      expect(
        identical(states[historicalSubstitute.trackKey], historicalSubstitute),
        isTrue,
      );
      expect(states, isNot(contains(lightSingleLegRdl.trackKey)));
      expect(states, isNot(contains(floorPress.trackKey)));

      final normalPlanKeys = states.keys
          .where((key) => key != historicalSubstitute.trackKey)
          .toList();
      for (final key in normalPlanKeys) {
        var state = states[key]!;
        for (var touch = 0; touch < 2; touch++) {
          state = engine.evaluateSession(
            state,
            [
              SetLog(
                trackKey: state.trackKey,
                pattern: state.pattern,
                exerciseName: engine.ladderStepFor(state).name,
                weight: state.currentLoad,
                metric: engine.metricFor(state),
                value: 1,
                rir: Rir.rir4plus,
                timestamp: today.add(Duration(days: touch)),
              ),
            ],
            equipmentConfig: cfg,
            sessionDate: today.add(Duration(days: touch)),
          );
        }
        states[key] = state;
      }

      expect(
        normalPlanKeys.map((key) => states[key]!),
        everyElement(
          isA<ExerciseState>()
              .having(
                (state) => state.status,
                'status',
                ExerciseStatus.progress,
              )
              .having(
                (state) => state.deloadSessionsRemaining,
                'remaining touches',
                0,
              ),
        ),
      );
      expect(
        identical(states[historicalSubstitute.trackKey], historicalSubstitute),
        isTrue,
      );
      expect(historicalSubstitute.status, ExerciseStatus.progress);
      expect(historicalSubstitute.deloadSessionsRemaining, 0);
      expect(
        historicalSubstitute.lastTrainedDate,
        today.subtract(const Duration(days: 30)),
      );
      final safety = const IntensityRecoveryPolicy()
          .evaluateHighIntensitySafety(
        logs: const [],
        asOf: today.add(const Duration(days: 2)),
        checkInPain: const [],
        exerciseStates: states.values,
      );
      expect(safety.deloadActive, isFalse);
      expect(safety.blocked, isFalse);
    });

    test('>=2 regressions within a rolling 28 days forces a deload', () {
      var state = ExerciseState(trackKey: 'hinge', pattern: MovementPattern.hinge, currentLoad: 60);
      state.regressionDates.addAll([today.subtract(const Duration(days: 5)), today.subtract(const Duration(days: 10))]);

      final result = engine.evaluateSession(
        state,
        [set(reps: 8, rir: Rir.rir1)], // any completed session re-checks the 28-day count
        equipmentConfig: cfg,
        sessionDate: today,
      );
      expect(result.status, ExerciseStatus.deload);
      expect(result.deloadSessionsRemaining, 2);
    });

    test('deload runs for exactly 2 sessions then auto-returns to PROGRESS', () {
      var state = ExerciseState(trackKey: 'hinge', pattern: MovementPattern.hinge, currentLoad: 60, status: ExerciseStatus.deload, deloadSessionsRemaining: 2, preDeloadLoad: 60);
      state = engine.evaluateSession(state, [set(reps: 8, rir: Rir.rir3plus)], equipmentConfig: cfg, sessionDate: today);
      expect(state.status, ExerciseStatus.deload);
      expect(state.deloadSessionsRemaining, 1);

      state = engine.evaluateSession(state, [set(reps: 8, rir: Rir.rir3plus)], equipmentConfig: cfg, sessionDate: today);
      expect(state.status, ExerciseStatus.progress);
      expect(state.deloadSessionsRemaining, 0);
    });

    test('a positive prescribed deload entry consumes one touch but no work does not', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 60,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 2,
        preDeloadLoad: 60,
      );

      final noWork = engine.evaluateSession(
        state,
        const [],
        equipmentConfig: cfg,
        sessionDate: today,
      );
      expect(noWork.deloadSessionsRemaining, 2);

      final completed = engine.evaluateSession(
        noWork,
        [set(reps: 8, rir: Rir.rir4plus, weight: 36)],
        equipmentConfig: cfg,
        sessionDate: today,
      );
      expect(completed.status, ExerciseStatus.deload);
      expect(completed.deloadSessionsRemaining, 1);
      expect(completed.lastTrainedDate, today);
    });

    test('deload exit restores the saved step then removes its newest stage', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        ladderStepIndex: 0,
        currentLoad: 24,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 1,
        preDeloadLoad: 60,
        preDeloadLadderStepIndex: 2,
        microStepStage: 2,
      );

      final result = engine.evaluateSession(
        state,
        [set(reps: 8, rir: Rir.rir4plus, weight: 36)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.status, ExerciseStatus.progress);
      expect(result.ladderStepIndex, 2);
      expect(engine.ladderStepFor(result).name, 'DB RDL');
      expect(result.currentLoad, 60);
      expect(result.microStepStage, 1);
      expect(result.regressionDates, isEmpty);
      expect(result.preDeloadLoad, isNull);
      expect(result.preDeloadLadderStepIndex, isNull);
    });

    test('deload exit removes one micro stage at the dumbbell floor', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        ladderStepIndex: 0,
        currentLoad: 60,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 1,
        preDeloadLoad: 12,
        preDeloadLadderStepIndex: 2,
        microStepStage: 2,
      );

      final result = engine.evaluateSession(
        state,
        [set(reps: 8, rir: Rir.rir4plus, weight: 12)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.ladderStepIndex, 2);
      expect(result.currentLoad, 12);
      expect(result.microStepStage, 1);
      expect(result.regressionDates, isEmpty);
    });

    test('deload exit removes the newest backpack micro stage first', () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        ladderStepIndex: 0,
        currentLoad: 0,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 1,
        preDeloadLoad: 25,
        preDeloadLadderStepIndex: 3,
        microStepStage: 2,
      );

      final result = engine.evaluateSession(
        state,
        [
          SetLog(
            trackKey: 'coreGrip',
            pattern: MovementPattern.coreGrip,
            exerciseName: 'Weighted hanging',
            weight: 15,
            metric: ExerciseMetric.seconds,
            value: 20,
            rir: Rir.rir4plus,
            timestamp: today,
          ),
        ],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.ladderStepIndex, 3);
      expect(result.currentLoad, 25);
      expect(result.microStepStage, 1);
      expect(result.regressionDates, isEmpty);
    });

    test('timed-hold deload exit returns to the prior final micro stage', () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        ladderStepIndex: 0,
        currentLoad: 0,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 1,
        preDeloadLoad: 0,
        preDeloadLadderStepIndex: 2,
      );

      final result = engine.evaluateSession(
        state,
        [
          SetLog(
            trackKey: 'coreGrip',
            pattern: MovementPattern.coreGrip,
            exerciseName: 'Hanging',
            weight: 0,
            metric: ExerciseMetric.seconds,
            value: 20,
            rir: Rir.rir4plus,
            timestamp: today,
          ),
        ],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.ladderStepIndex, 1);
      expect(engine.ladderStepFor(result).name, 'L-sit progression');
      expect(result.microStepStage, 3);
      expect(result.currentLoad, 0);
      expect(result.regressionDates, isEmpty);
    });

    test('named no-load deload exit never enters its pattern ladder', () {
      final state = ExerciseState(
        trackKey: bridgeHamstringCurl.trackKey,
        pattern: bridgeHamstringCurl.pattern,
        ladderStepIndex: 4,
        currentLoad: 0,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 1,
        preDeloadLoad: 0,
        preDeloadLadderStepIndex: 4,
      );

      final result = engine.evaluateSession(
        state,
        [
          SetLog(
            trackKey: bridgeHamstringCurl.trackKey,
            pattern: bridgeHamstringCurl.pattern,
            exerciseName: bridgeHamstringCurl.name,
            weight: 0,
            value: 8,
            rir: Rir.rir4plus,
            timestamp: today,
          ),
        ],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.ladderStepIndex, 4);
      expect(result.microStepStage, 0);
      expect(engine.ladderStepFor(result).name, bridgeHamstringCurl.name);
      expect(result.regressionDates, isEmpty);
    });

    test('does not replace the working load with a temporary deload load', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 60,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 2,
        preDeloadLoad: 60,
      );

      final result = engine.evaluateSession(
        state,
        [set(reps: 8, rir: Rir.rir3plus, weight: 36)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentLoad, 60);
      expect(result.status, ExerciseStatus.deload);
      expect(result.deloadSessionsRemaining, 1);
    });

    test('consumes triggering regressions and does not immediately re-enter deload', () {
      var state = ExerciseState(trackKey: 'hinge', pattern: MovementPattern.hinge, currentLoad: 60);
      state.regressionDates.addAll([
        today.subtract(const Duration(days: 5)),
        today.subtract(const Duration(days: 10)),
      ]);
      final normalSets = [set(reps: 8, rir: Rir.rir1)];

      state = engine.evaluateSession(state, normalSets, equipmentConfig: cfg, sessionDate: today);
      expect(state.status, ExerciseStatus.deload);
      expect(state.regressionDates, isEmpty);

      state = engine.evaluateSession(
        state,
        normalSets,
        equipmentConfig: cfg,
        sessionDate: today.add(const Duration(days: 3)),
      );
      state = engine.evaluateSession(
        state,
        normalSets,
        equipmentConfig: cfg,
        sessionDate: today.add(const Duration(days: 6)),
      );
      expect(state.status, ExerciseStatus.progress);
      expect(state.deloadSessionsRemaining, 0);

      state = engine.evaluateSession(
        state,
        normalSets,
        equipmentConfig: cfg,
        sessionDate: today.add(const Duration(days: 9)),
      );
      expect(state.status, ExerciseStatus.progress);
      expect(state.deloadSessionsRemaining, 0);
    });
  });

  group('named exercise progression', () {
    test('uses an adjusted DB curl load as the base for progression', () {
      final state = ExerciseState(
        trackKey: dbCurl.trackKey,
        pattern: dbCurl.pattern,
        currentLoad: 18,
      );
      SetLog adjustedTopSet() => SetLog(
            trackKey: dbCurl.trackKey,
            pattern: dbCurl.pattern,
            exerciseName: dbCurl.name,
            weight: 24,
            value: 15,
            rir: Rir.rir2,
            timestamp: today,
          );

      final result = engine.evaluateSession(
        state,
        [adjustedTopSet(), adjustedTopSet()],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentLoad, 25);
      expect(result.ladderStepIndex, 0);
    });

    test('DB curl stays capped without falling through to the core/grip ladder', () {
      var state = ExerciseState(
        trackKey: dbCurl.trackKey,
        pattern: dbCurl.pattern,
        currentLoad: 50,
      );
      SetLog topSet() => SetLog(
            trackKey: dbCurl.trackKey,
            pattern: dbCurl.pattern,
            exerciseName: dbCurl.name,
            weight: 50,
            value: 15,
            rir: Rir.rir2,
            timestamp: today,
          );

      for (var i = 0; i < 6; i++) {
        state = engine.evaluateSession(
          state,
          [topSet(), topSet()],
          equipmentConfig: cfg,
          sessionDate: today.add(Duration(days: i)),
        );
      }

      expect(state.currentLoad, 50);
      expect(state.ladderStepIndex, 0);
      expect(state.microStepStage, 3);
      expect(state.awaitingUndershootCheck, isFalse);
      expect(engine.ladderStepFor(state).name, dbCurl.name);
    });
  });

  group('§6.6 detraining adjustment', () {
    test('a never-trained exercise stays an onboarding prescription', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 0,
      );

      final resolution = engine.resolveTodaysPrescription(state, today, cfg);

      expect(resolution.detrainFired, isFalse);
      expect(resolution.state.currentLoad, 0);
      expect(resolution.state.ladderStepIndex, 0);
      expect(identical(resolution.state, state), isTrue);
    });

    test('10-20 days untrained resumes at 90%', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 100,
        lastTrainedDate: today.subtract(const Duration(days: 12)),
      );
      final resolution = engine.resolveTodaysPrescription(state, today, cfg);
      expect(resolution.detrainFired, isTrue);
      expect(resolution.state.currentLoad, 90);
    });

    test('>21 days untrained resumes at 80% and one ladder step easier', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 100,
        ladderStepIndex: 3,
        lastTrainedDate: today.subtract(const Duration(days: 25)),
      );
      final resolution = engine.resolveTodaysPrescription(state, today, cfg);
      expect(resolution.state.ladderStepIndex, 2);
      expect(resolution.state.currentLoad, 80);
    });

    test('>42 days untrained resumes at 70%', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 100,
        lastTrainedDate: today.subtract(const Duration(days: 50)),
      );
      final resolution = engine.resolveTodaysPrescription(state, today, cfg);
      expect(resolution.state.currentLoad, 70);
    });
  });

  group('§6.6 precedence: pain re-entry overrides detraining', () {
    test('a pending re-entry test runs at 50% of pre-pain load, ignoring the detrain %', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 40,
        prePainLoad: 90,
        painFrozen: true,
        painReentryTestOffered: true,
        lastTrainedDate: today.subtract(const Duration(days: 30)), // would otherwise be a big detrain
      );
      final resolution = engine.resolveTodaysPrescription(state, today, cfg);
      expect(resolution.painReentryTestFired, isTrue);
      expect(resolution.detrainFired, isFalse);
      // floor(0.5*90=45) to the nearest achievable matched total -> 42.
      expect(resolution.state.currentLoad, 42);
    });

    test('post-reentry resume takes the lower of detrain-adjusted vs pre-pain-minus-one-increment', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 45,
        prePainLoad: 90,
        painFrozen: true,
        painSeverity: PainSeverity.mild,
        painRegion: BodyRegion.lowerBack,
        painFlaggedDate: today.subtract(const Duration(days: 14)),
        painTags: {PainTag.radiating, PainTag.tingling},
        sessionsScheduledWhileFlagged: 2,
        lastPainScheduledDate: today.subtract(const Duration(days: 1)),
        painReentryTestOffered: true,
        painReentryTestPassed: true,
        lastTrainedDate: today.subtract(const Duration(days: 25)), // >21 days -> 80%
      );
      final resumed = engine.resolvePostReentryResume(state, today, cfg);
      expect(resumed.painFrozen, isFalse);
      expect(resumed.painSeverity, isNull);
      expect(resumed.painRegion, isNull);
      expect(resumed.painFlaggedDate, isNull);
      expect(resumed.painTags, isEmpty);
      expect(resumed.sessionsScheduledWhileFlagged, 0);
      expect(resumed.lastPainScheduledDate, isNull);
      expect(resumed.painReentryTestOffered, isFalse);
      expect(resumed.painReentryTestPassed, isFalse);
      // detrain-adjusted: floor(90*0.8=72) to nearest achievable -> 70;
      // pre-pain-minus-one-increment below 90 -> 80. Lower of the two is 70.
      expect(resumed.currentLoad, 70);
    });
  });

  group('timed targets and audited progression boundaries', () {
    SetLog timedSet({
      required int seconds,
      Rir rir = Rir.rir2,
      double weight = 0,
      String exerciseName = 'Plank',
    }) =>
        SetLog(
          trackKey: 'coreGrip',
          pattern: MovementPattern.coreGrip,
          exerciseName: exerciseName,
          weight: weight,
          metric: ExerciseMetric.seconds,
          value: seconds,
          rir: rir,
          timestamp: today,
        );

    test('legacy Plank starts at the established 60-second target', () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
      );

      expect(engine.targetRangeFor(state), (20, 60));
      expect(engine.suggestedValueFor(state), 60);
    });

    test('45 seconds no longer counts as Plank mastery', () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        currentTargetValue: 60,
      );

      final result = engine.evaluateSession(
        state,
        [timedSet(seconds: 45), timedSet(seconds: 45)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentTargetValue, 60);
      expect(result.microStepStage, 0);
      expect(result.ladderStepIndex, 0);
      expect(result.lastPrescriptionChange, isNull);
    });

    test('a successful 60-second Plank advances and explains the new stage',
        () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        currentTargetValue: 60,
      );

      final result = engine.evaluateSession(
        state,
        [timedSet(seconds: 60), timedSet(seconds: 60)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentTargetValue, 60);
      expect(result.microStepStage, 1);
      expect(result.lastPrescriptionChange, contains('controlled transition'));
    });

    test('four mastered Plank exposures reach L-sit at its safe target', () {
      var state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        currentTargetValue: 60,
      );

      for (var exposure = 0; exposure < 4; exposure++) {
        state = engine.evaluateSession(
          state,
          [timedSet(seconds: 60), timedSet(seconds: 60)],
          equipmentConfig: cfg,
          sessionDate: today.add(Duration(days: exposure)),
        );
      }

      expect(state.ladderStepIndex, 1);
      expect(engine.ladderStepFor(state).name, 'L-sit progression');
      expect(state.currentTargetValue, 10);
      expect(state.microStepStage, 0);
      expect(state.awaitingUndershootCheck, isTrue);
      expect(state.lastPrescriptionChange, contains('New difficulty'));
    });

    test('timed targets rise by five seconds before technique progression',
        () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        ladderStepIndex: 1,
        currentTargetValue: 10,
      );

      final result = engine.evaluateSession(
        state,
        [
          timedSet(seconds: 10, exerciseName: 'L-sit progression'),
          timedSet(seconds: 10, exerciseName: 'L-sit progression'),
        ],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentTargetValue, 15);
      expect(result.microStepStage, 0);
      expect(result.lastPrescriptionChange, contains('10 → 15 seconds'));
    });

    test('timed regression removes a stage before reducing duration', () {
      final staged = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        currentTargetValue: 60,
        microStepStage: 2,
        status: ExerciseStatus.hold,
        consecutiveHoldCount: 1,
      );
      final stagedResult = engine.evaluateSession(
        staged,
        [timedSet(seconds: 10, rir: Rir.rir0)],
        equipmentConfig: cfg,
        sessionDate: today,
      );
      expect(stagedResult.currentTargetValue, 60);
      expect(stagedResult.microStepStage, 1);

      final targeted = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        ladderStepIndex: 1,
        currentTargetValue: 20,
        status: ExerciseStatus.hold,
        consecutiveHoldCount: 1,
      );
      final targetedResult = engine.evaluateSession(
        targeted,
        [
          timedSet(
            seconds: 5,
            rir: Rir.rir0,
            exerciseName: 'L-sit progression',
          ),
        ],
        equipmentConfig: cfg,
        sessionDate: today,
      );
      expect(targetedResult.currentTargetValue, 15);
      expect(targetedResult.microStepStage, 0);
    });

    test('an unchanged exposure clears stale prescription-change copy', () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        currentTargetValue: 60,
        lastPrescriptionChange: 'Old change',
      );

      final result = engine.evaluateSession(
        state,
        [timedSet(seconds: 50, rir: Rir.rir1)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentTargetValue, 60);
      expect(result.microStepStage, 0);
      expect(result.lastPrescriptionChange, isNull);
    });

    test('loaded regression removes the active stage before reducing load',
        () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 60,
        ladderStepIndex: 2,
        microStepStage: 2,
        status: ExerciseStatus.hold,
        consecutiveHoldCount: 1,
      );

      final result = engine.evaluateSession(
        state,
        [set(reps: 4, rir: Rir.rir0)],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.status, ExerciseStatus.regress);
      expect(result.currentLoad, 60);
      expect(result.microStepStage, 1);
    });

    test('pending pain re-entry takes precedence over an active deload', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 40,
        prePainLoad: 90,
        painFrozen: true,
        painReentryTestOffered: true,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 2,
        preDeloadLoad: 90,
      );

      final resolution = engine.resolveTodaysPrescription(state, today, cfg);

      expect(resolution.painReentryTestFired, isTrue);
      expect(resolution.deloadActive, isFalse);
      expect(resolution.state.currentLoad, 42);
    });

    test('passed pain re-entry leaves an overlapping deload reachable', () {
      final state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 42,
        prePainLoad: 90,
        painFrozen: true,
        painReentryTestPassed: true,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 2,
        preDeloadLoad: 90,
        lastTrainedDate: today.subtract(const Duration(days: 2)),
      );

      final resumed = engine.resolvePostReentryResume(state, today, cfg);
      expect(resumed.painFrozen, isFalse);
      expect(resumed.status, ExerciseStatus.deload);
      expect(resumed.deloadSessionsRemaining, 2);
      expect(
        engine.resolveTodaysPrescription(resumed, today, cfg).deloadActive,
        isTrue,
      );
    });

    test('backpack loading uses the configured DB maximum as its auto cap',
        () {
      final state = ExerciseState(
        trackKey: 'pullVertical',
        pattern: MovementPattern.pullVertical,
        ladderStepIndex: 2,
        currentLoad: 50,
      );
      final top = SetLog(
        trackKey: 'pullVertical',
        pattern: MovementPattern.pullVertical,
        exerciseName: 'Weighted pull-up (backpack/DB)',
        weight: 50,
        value: 10,
        rir: Rir.rir2,
        timestamp: today,
      );

      final result = engine.evaluateSession(
        state,
        [top, top],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.currentLoad, 50);
      expect(result.microStepStage, 1);
    });

    test('capped backpack progression can advance the movement ladder', () {
      final state = ExerciseState(
        trackKey: 'pullVertical',
        pattern: MovementPattern.pullVertical,
        ladderStepIndex: 2,
        currentLoad: 50,
        microStepStage: 3,
      );
      final top = SetLog(
        trackKey: 'pullVertical',
        pattern: MovementPattern.pullVertical,
        exerciseName: 'Weighted pull-up (backpack/DB)',
        weight: 50,
        value: 10,
        rir: Rir.rir2,
        timestamp: today,
      );

      final result = engine.evaluateSession(
        state,
        [top, top],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.ladderStepIndex, 3);
      expect(
        engine.ladderStepFor(result).name,
        'Weighted pull-up +pause at top',
      );
      expect(result.currentLoad, 40);
      expect(result.currentLoad, lessThanOrEqualTo(50));
    });

    test('detraining reduces a timed target in five-second steps', () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        currentTargetValue: 60,
        lastTrainedDate: today.subtract(const Duration(days: 12)),
      );

      final resolution = engine.resolveTodaysPrescription(state, today, cfg);

      expect(resolution.detrainFired, isTrue);
      expect(resolution.state.currentTargetValue, 50);
    });

    test('timed deload target reduces the actual hold duration', () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        currentTargetValue: 60,
        status: ExerciseStatus.deload,
      );

      expect(engine.deloadTargetValueFor(state), 35);
    });

    test('easy first timed exposure applies a real undershoot increment', () {
      final state = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        ladderStepIndex: 1,
        currentTargetValue: 10,
        awaitingUndershootCheck: true,
      );

      final result = engine.evaluateSession(
        state,
        [
          timedSet(
            seconds: 10,
            rir: Rir.rir4plus,
            exerciseName: 'L-sit progression',
          ),
        ],
        equipmentConfig: cfg,
        sessionDate: today,
      );

      expect(result.awaitingUndershootCheck, isFalse);
      expect(result.currentTargetValue, 15);
    });
  });
}
