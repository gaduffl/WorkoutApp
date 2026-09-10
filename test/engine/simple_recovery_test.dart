import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/progression_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/equipment.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  final day = DateTime(2026, 9, 10);
  DecisionEngineOutput plan({
    UserSettings settings = const UserSettings(
      lowerBackRecovery: LowerBackRecoveryState(active: true),
    ),
    int minutes = 35,
    int subjective = 4,
    SessionTypeId id = SessionTypeId.s1,
    List<PainFlag> pain = const [],
  }) => const DecisionEngine().decide(
    DecisionEngineInput(
      checkin: CheckIn(
        date: day,
        timeMinutes: minutes,
        subjective: subjective,
        pain: pain,
        timestamp: day,
      ),
      todaySnapshot: RecoverySnapshot(
        date: day,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: List.generate(
        20,
        (i) => RecoverySnapshot(
          date: day.subtract(Duration(days: i + 1)),
          hrvRmssd: 50,
          restingHr: 60,
          sleepScore: 90,
        ),
      ),
      sessionLogs: const [],
      exerciseStates: {
        'hinge': ExerciseState(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          currentLoad: 90,
          ladderStepIndex: 3,
        ),
      },
      queueState: const QueueState(),
      settings: settings,
      today: day,
      forcedSessionId: id,
    ),
  );

  test('default recovery makes a normal strength plan without extra forms', () {
    for (final id in [
      SessionTypeId.s1,
      SessionTypeId.s2,
      SessionTypeId.s4,
      SessionTypeId.s5,
    ]) {
      for (final minutes in [20, 35, 60]) {
        final result = plan(id: id, minutes: minutes).trace.plan!;
        expect(result.sessionId, id);
        expect(result.estimatedDurationMin, lessThanOrEqualTo(minutes));
        expect(
          result.exercises.any(
            (e) =>
                e.trackKey == lowerBackRecoveryTrackKey ||
                e.trackKey == 'hinge',
          ),
          isFalse,
        );
        if (id == SessionTypeId.s1 || id == SessionTypeId.s4) {
          expect(
            result.exercises.map((e) => e.trackKey),
            containsAll([
              lowerBackRecoveryFloorGluteBridge.trackKey,
              lowerBackRecoverySlidingHamstringCurl.trackKey,
            ]),
          );
        }
      }
    }
    expect(
      plan().trace.plan!.exercises.map((e) => e.trackKey),
      contains(recoveryAbdominalActivation.trackKey),
    );
  });

  test('readiness restrictions still stop upper strength progression', () {
    final result = plan(id: SessionTypeId.s2, subjective: 1).trace.plan!;
    expect(
      result.exercises
          .where((e) => !e.isWarmup)
          .every((e) => !e.progressionEligible),
      isTrue,
    );
  });

  test('cycling pause rejects forced cardio and optional finishers', () {
    for (final id in [SessionTypeId.s3, SessionTypeId.s6, SessionTypeId.s7]) {
      final result = plan(id: id, minutes: 60).trace.plan!;
      expect([
        SessionTypeId.s3,
        SessionTypeId.s6,
        SessionTypeId.s7,
      ], isNot(contains(result.sessionId)));
      expect(result.optionalRehitFinisherReserved, isFalse);
    }
  });

  test('legacy deadlift reentry stage cannot load a hinge in recovery', () {
    final result = plan(
      settings: const UserSettings(
        recoveryBackExtensionsEnabled: true,
        lowerBackRecovery: LowerBackRecoveryState(
          active: true,
          stage: LowerBackRecoveryStage.deadliftReentry,
          preRecoveryHingeLoad: 90,
        ),
      ),
    ).trace.plan!;
    expect(
      result.exercises
          .where((e) => e.pattern == MovementPattern.hinge)
          .every((e) => e.loadTotal == null),
      isTrue,
    );
  });

  test('normal alternative starts independently and respects sharp pain', () {
    final result = plan(
      settings: const UserSettings(deadliftAlternative: true),
      minutes: 60,
    ).trace.plan!;
    expect(
      result.exercises.map((e) => e.trackKey),
      containsAll([
        alternativeGluteBridge.trackKey,
        alternativeHamstringCurl.trackKey,
      ]),
    );
    expect(result.exercises.any((e) => e.trackKey == 'hinge'), isFalse);
    expect(
      result.exercises
          .firstWhere((e) => e.trackKey == alternativeGluteBridge.trackKey)
          .loadTotal!,
      lessThan(90),
    );
    final painful = plan(
      settings: const UserSettings(deadliftAlternative: true),
      minutes: 60,
      pain: [
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.sharp,
          flaggedDate: day,
        ),
      ],
    ).trace.plan!;
    expect(
      painful.exercises.any(
        (e) => e.trackKey == alternativeGluteBridge.trackKey,
      ),
      isFalse,
    );
  });

  test(
    'recovery pull-ups and dips progress tempo and pause without loaded ladders',
    () {
      for (final e in [lowerBackRecoveryPullUp, lowerBackRecoveryDip]) {
        var state = ExerciseState(trackKey: e.trackKey, pattern: e.pattern);
        for (var i = 0; i < 5; i++) {
          state = const ProgressionEngine().evaluateSession(
            state,
            [
              SetLog(
                trackKey: e.trackKey,
                pattern: e.pattern,
                exerciseName: e.name,
                weight: 0,
                value: 15,
                rir: Rir.rir3plus,
                timestamp: day,
              ),
            ],
            equipmentConfig: const EquipmentConfig(),
            sessionDate: day,
          );
        }
        expect(state.microStepStage, 2);
        expect(state.ladderStepIndex, 0);
        expect(state.currentLoad, 0);
        expect(
          const ProgressionEngine()
              .progressionPresentationFor(state, const EquipmentConfig())
              .nextLabel,
          contains('no added load'),
        );
      }
    },
  );
}
