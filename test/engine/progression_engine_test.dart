import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/progression_engine.dart';
import 'package:morningcoach/models/equipment.dart';
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
        reps: reps,
        rir: rir,
        timestamp: today,
      );

  group('§6.2.5 middle zone', () {
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
        reps: 8,
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
            reps: 10,
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
  });

  group('§6.3 deload trigger', () {
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
            reps: 15,
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
            reps: 15,
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
}
