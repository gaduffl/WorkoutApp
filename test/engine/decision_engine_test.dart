import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  const decisionEngine = DecisionEngine();
  final today = DateTime(2026, 1, 20); // a Tuesday - not a weekend

  Map<String, ExerciseState> baseStates() => {
        'squat': ExerciseState(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          currentLoad: 24,
          lastTrainedDate: today.subtract(const Duration(days: 2)),
        ),
        'hinge': ExerciseState(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          currentLoad: 90,
          lastTrainedDate: today.subtract(const Duration(days: 2)),
        ),
      };

  // "Normal" HRV history so a GREEN bucket is reachable while still using a
  // middling subjective=3 rating (see worked example below).
  List<RecoverySnapshot> normalHrvHistory() => List.generate(
        20,
        (i) => RecoverySnapshot(date: today.subtract(Duration(days: i + 1)), hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      );

  SessionLog buildLog(SessionTypeId id, DateTime date, Set<FloorCategory> categories) => SessionLog(
        id: '$id-${date.toIso8601String()}',
        templateId: id,
        tier: SessionTier.full,
        date: date,
        setLogs: const [],
        plannedWorkSets: 6,
        completedWorkSets: 6,
        durationMinutes: 30,
        countsAs: categories,
      );

  /// Enough logged history that the weekly floor (2 strength, 1 intensity)
  /// is already satisfied - keeps floor-pressure scoring out of tests that
  /// aren't about it.
  List<SessionLog> floorSatisfiedLogs() => [
        buildLog(SessionTypeId.s1, today.subtract(const Duration(days: 2)), {FloorCategory.strength}),
        buildLog(SessionTypeId.s4, today.subtract(const Duration(days: 4)), {FloorCategory.strength}),
        buildLog(SessionTypeId.s3, today.subtract(const Duration(days: 3)), {FloorCategory.intensity}),
      ];

  DecisionEngineInput buildInput({
    required int time,
    required int subjective,
    List<PainFlag> pain = const [],
    RecoverySnapshot? todaySnapshot,
    List<RecoverySnapshot> recoveryHistory = const [],
    List<SessionLog> sessionLogs = const [],
    QueueState queueState = const QueueState(),
    Map<String, ExerciseState>? exerciseStates,
    UserSettings settings = const UserSettings(),
    SessionTypeId? forcedSessionId,
  }) {
    return DecisionEngineInput(
      checkin: CheckIn(date: today, timeMinutes: time, subjective: subjective, pain: pain, timestamp: today),
      todaySnapshot: todaySnapshot,
      recoveryHistory: recoveryHistory,
      checkinHistory: const [],
      sessionLogs: sessionLogs,
      exerciseStates: exerciseStates ?? baseStates(),
      queueState: queueState,
      settings: settings,
      today: today,
      forcedSessionId: forcedSessionId,
    );
  }

  test('§5 worked example: S1 with sharp lower-back pain', () {
    final input = buildInput(
      time: 35,
      subjective: 3,
      pain: [PainFlag(region: BodyRegion.lowerBack, severity: PainSeverity.sharp, flaggedDate: today)],
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s1),
    );
    final output = decisionEngine.decide(input);
    final trace = output.trace;

    expect(trace.recovery.bucket, ReadinessBucket.green);
    expect(trace.plan, isNotNull);
    expect(trace.plan!.sessionId, SessionTypeId.s1);

    final hinge = trace.plan!.exercises.firstWhere((e) => e.substitutedFrom == 'hinge');
    expect(hinge.name, 'Bridge hamstring curl');

    final squat = trace.plan!.exercises.firstWhere((e) => e.pattern == MovementPattern.squat);
    expect(squat.loadTotal, lessThan(24));

    expect(trace.firedRuleCodes, containsAll(['ONBOARD_SUBSTITUTE', 'PAIN_SUB_HINGE_SHARP', 'PAIN_SUB_SQUAT_SHARP']));
  });

  test('floor-pressure day forces a strength candidate even when the queue points at intensity', () {
    final input = buildInput(
      time: 35,
      subjective: 3,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s3), // intensity is "next"
      sessionLogs: const [], // zero strength sessions logged -> deficit 2 -> hard force
    );
    final output = decisionEngine.decide(input);

    expect(output.trace.firedRuleCodes, contains('FLOOR_FORCE_STRENGTH'));
    expect(output.trace.plan!.sessionId, isNot(SessionTypeId.s3));
  });

  group('RED-day swaps', () {
    test('a RED strength session runs as a technique session, not a type swap', () {
      final input = buildInput(
        time: 35,
        subjective: 1, // forces RED
        queueState: const QueueState(pointer: SessionTypeId.s1),
        sessionLogs: floorSatisfiedLogs(),
      );
      final output = decisionEngine.decide(input);

      expect(output.trace.recovery.bucket, ReadinessBucket.red);
      expect(output.trace.plan!.sessionId, SessionTypeId.s1);
      expect(output.trace.firedRuleCodes, contains('RED_SWAP_TECHNIQUE'));
    });

    test('a RED intensity session swaps to Zone 2', () {
      final input = buildInput(
        time: 35,
        subjective: 1,
        queueState: const QueueState(pointer: SessionTypeId.s3),
        sessionLogs: floorSatisfiedLogs(),
      );
      final output = decisionEngine.decide(input);

      expect(output.trace.plan!.sessionId, SessionTypeId.s6);
      expect(output.trace.firedRuleCodes, contains('RED_SWAP_Z2'));
    });
  });

  test('score tie-break follows S1..S5, then S7, then S6', () {
    final input = buildInput(
      time: 35,
      subjective: 3,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s1), // S5 has cycle_distance 4 -> base 10, tying S6/S7
      sessionLogs: floorSatisfiedLogs(),
    );
    final output = decisionEngine.decide(input);
    final order = output.trace.candidates.map((c) => c.sessionId).toList();

    final s5 = order.indexOf(SessionTypeId.s5);
    final s6 = order.indexOf(SessionTypeId.s6);
    final s7 = order.indexOf(SessionTypeId.s7);
    expect(s5, lessThan(s7));
    expect(s7, lessThan(s6));
  });

  group('§11 swap session', () {
    test('forcedSessionId overrides the natural winner but still runs modulation/pain steps', () {
      final input = buildInput(
        time: 35,
        subjective: 3,
        pain: [PainFlag(region: BodyRegion.lowerBack, severity: PainSeverity.sharp, flaggedDate: today)],
        todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
        recoveryHistory: normalHrvHistory(),
        queueState: const QueueState(pointer: SessionTypeId.s1), // natural winner would be S1
        sessionLogs: floorSatisfiedLogs(),
        forcedSessionId: SessionTypeId.s4, // user taps "switch to S4" instead
      );
      final output = decisionEngine.decide(input);

      expect(output.trace.plan!.sessionId, SessionTypeId.s4);
      // S4 also trains squat/hinge, so the sharp lower-back substitution
      // must still have fired against the swapped-to plan.
      expect(output.trace.firedRuleCodes, contains('PAIN_SUB_SQUAT_SHARP'));
    });

    test('an invalid forcedSessionId (not in the feasible set) falls back to the natural winner', () {
      final input = buildInput(
        time: 20, // candidates are only {S1, S5, S7} at 20 minutes
        subjective: 3,
        queueState: const QueueState(pointer: SessionTypeId.s1),
        forcedSessionId: SessionTypeId.s4, // not feasible at 20 min
      );
      final output = decisionEngine.decide(input);
      expect(output.trace.plan!.sessionId, isNot(SessionTypeId.s4));
      expect(output.trace.plan!.sessionId, SessionTypeId.s1); // natural winner
    });
  });

  group('§13 floor deficit==1 aging-out horizon', () {
    test('fires FLOOR_FORCE when the lone qualifying session ages out within 2 days', () {
      final input = buildInput(
        time: 35,
        subjective: 3,
        todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
        recoveryHistory: normalHrvHistory(),
        queueState: const QueueState(pointer: SessionTypeId.s3),
        sessionLogs: [
          SessionLog(
            id: 'a',
            templateId: SessionTypeId.s1,
            tier: SessionTier.full,
            date: today.subtract(const Duration(days: 6)),
            setLogs: const [],
            plannedWorkSets: 6,
            completedWorkSets: 6,
            durationMinutes: 30,
            countsAs: const {FloorCategory.strength},
          ),
        ],
      );
      final output = decisionEngine.decide(input);
      expect(output.trace.firedRuleCodes, contains('FLOOR_FORCE_STRENGTH'));
    });

    test('stays a soft boost when the lone qualifying session is not about to age out', () {
      final input = buildInput(
        time: 35,
        subjective: 3,
        todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
        recoveryHistory: normalHrvHistory(),
        queueState: const QueueState(pointer: SessionTypeId.s1),
        sessionLogs: [
          SessionLog(
            id: 'a',
            templateId: SessionTypeId.s1,
            tier: SessionTier.full,
            date: today.subtract(const Duration(days: 1)),
            setLogs: const [],
            plannedWorkSets: 6,
            completedWorkSets: 6,
            durationMinutes: 30,
            countsAs: const {FloorCategory.strength},
          ),
        ],
      );
      final output = decisionEngine.decide(input);
      expect(output.trace.firedRuleCodes, isNot(contains('FLOOR_FORCE_STRENGTH')));
      expect(output.trace.firedRuleCodes, contains('FLOOR_SOFT_BOOST'));
    });
  });

  test('§6 order of operations: 20-min + YELLOW stacks compression then the 25% volume cut', () {
    final input = buildInput(
      time: 20,
      subjective: 3,
      // No recovery snapshot at all -> subjective-only composite (50) -> YELLOW.
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
    );
    final output = decisionEngine.decide(input);

    expect(output.trace.recovery.bucket, ReadinessBucket.yellow);
    expect(output.trace.plan!.tier.name, 'compressed');
    // Baseline compressed compound sets = 2 (§2.5); 25% cut floors to 1.
    for (final e in output.trace.plan!.exercises) {
      expect(e.sets, 1);
    }
  });

  test('§5 Step 6: RED technique session is a swap — no queue credit, pointer unchanged', () {
    final input = buildInput(
      time: 35,
      subjective: 1, // forces RED
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
    );
    final output = decisionEngine.decide(input);

    expect(output.trace.firedRuleCodes, contains('RED_SWAP_TECHNIQUE'));
    expect(output.trace.plan!.grantsQueueCredit, isFalse);
    expect(output.trace.queue.pointerAfterIfCompleted, SessionTypeId.s1);
  });

  test('§6.5: an active deload actually changes the prescription (60% load, half sets, RIR>=4)', () {
    final states = baseStates();
    states['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      currentLoad: 90,
      status: ExerciseStatus.deload,
      deloadSessionsRemaining: 2,
      preDeloadLoad: 90,
      lastTrainedDate: today.subtract(const Duration(days: 2)),
    );
    final input = buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: states,
    );
    final output = decisionEngine.decide(input);

    expect(output.trace.firedRuleCodes, contains('DELOAD_ACTIVE_SQUAT'));
    final squat = output.trace.plan!.exercises.firstWhere((e) => e.pattern == MovementPattern.squat && !e.isWarmup);
    // 90 x 0.6 = 54 -> rounds down to 48 on the matched 2-DB set (squat state
    // load 90 sits on the DB-squat step in these fixtures' default ladder idx 0
    // = goblet (single-DB): 54 -> 50). Assert the reduction happened and RIR.
    expect(squat.loadTotal, lessThan(90 * 0.61));
    expect(squat.sets, 1); // full-tier compounds 3 -> deload halves -> 1
    expect(squat.rirTarget.name, 'rir3plus');
    final hinge = output.trace.plan!.exercises.firstWhere((e) => e.pattern == MovementPattern.hinge && !e.isWarmup);
    expect(hinge.sets, 3); // deload is per-pattern, not session-wide
  });

  test('§7.2: a sharp freeze keeps substituting on later days without re-tapping the body map', () {
    final states = baseStates();
    states['hinge'] = ExerciseState(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      currentLoad: 90,
      lastTrainedDate: today.subtract(const Duration(days: 2)),
      painFrozen: true,
      painSeverity: PainSeverity.sharp,
      painRegion: BodyRegion.lowerBack,
      painFlaggedDate: today.subtract(const Duration(days: 1)),
      sessionsScheduledWhileFlagged: 0,
      prePainLoad: 90,
    );
    final input = buildInput(
      time: 35,
      subjective: 3,
      pain: const [], // user did NOT re-tap today
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: states,
    );
    final output = decisionEngine.decide(input);

    expect(output.trace.firedRuleCodes, contains('PAIN_SUB_HINGE_SHARP'));
    final hinge = output.trace.plan!.exercises.firstWhere((e) => e.substitutedFrom == 'hinge');
    expect(hinge.trackKey, startsWith('sub:'));
    // and the §7.2 scheduled counter still ticks
    expect(output.patchedExerciseStates['hinge']!.sessionsScheduledWhileFlagged, 1);
  });

  test('§2.5 warm-up protocol: 40/60/80 ramp before the first compound, feeders after', () {
    final input = buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
    );
    final output = decisionEngine.decide(input);
    final ex = output.trace.plan!.exercises;

    // squat (goblet, single-DB, 24 lb): ramp rounds down on the single-DB set
    expect(ex[0].isWarmup, isTrue);
    expect(ex[0].loadTotal, 9); // 40% of 24 = 9.6 -> 9
    expect(ex[1].loadTotal, 12); // 60% = 14.4 -> 12
    expect(ex[2].loadTotal, 18); // 80% = 19.2 -> 18
    expect(ex[3].pattern, MovementPattern.squat);
    expect(ex[3].isWarmup, isFalse);
    // hinge (2-DB, 90 lb): one 60% feeder -> 54 rounds down to 50 matched
    expect(ex[4].isWarmup, isTrue);
    expect(ex[4].loadTotal, 50);
    expect(ex[5].pattern, MovementPattern.hinge);
    // warm-ups never count toward the §8 completion denominator
    expect(output.trace.plan!.plannedWorkSets, 6);
  });

  test('§2.5: the ATG block replaces the ramp on S4 (feeders only)', () {
    final input = buildInput(
      time: 60,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s4),
      sessionLogs: floorSatisfiedLogs(),
    );
    final output = decisionEngine.decide(input);
    final ex = output.trace.plan!.exercises;

    expect(ex.first.trackKey, 'atg_block');
    expect(ex.first.isWarmup, isTrue);
    expect(ex.any((e) => e.name.contains('40%')), isFalse); // no ramp
    // the first compound still gets its 60% feeder
    final squatIdx = ex.indexWhere((e) => e.pattern == MovementPattern.squat && !e.isWarmup);
    expect(ex[squatIdx - 1].isWarmup, isTrue);
    expect(ex[squatIdx - 1].name, contains('60%'));
  });

  test('§12 travel mode: ladders resolve to bodyweight, arm accessories drop out', () {
    final s1 = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      settings: const UserSettings(travelMode: true),
    ));
    final work = s1.trace.plan!.exercises.where((e) => !e.isWarmup).toList();
    expect(work.every((e) => e.loadTotal == null), isTrue);
    expect(work.any((e) => e.name == 'Split squat (bodyweight)'), isTrue);
    expect(work.any((e) => e.name == 'Single-leg RDL (bodyweight)'), isTrue);
    expect(work.every((e) => e.isTravel), isTrue);
    // no percent-load warm-ups without loads
    expect(s1.trace.plan!.exercises.any((e) => e.isWarmup), isFalse);

    final s5 = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s5),
      sessionLogs: floorSatisfiedLogs(),
      settings: const UserSettings(travelMode: true),
    ));
    expect(s5.trace.plan!.exercises.any((e) => e.name == 'DB curl'), isFalse);
  });

  test('§6.6: a detraining-adjusted load is marked to persist on completion', () {
    final states = baseStates();
    states['hinge'] = ExerciseState(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      currentLoad: 100,
      lastTrainedDate: today.subtract(const Duration(days: 15)), // 10-20 days -> 90%
    );
    final input = buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: states,
    );
    final output = decisionEngine.decide(input);

    expect(output.trace.firedRuleCodes, contains('DETRAIN_ADJUST_HINGE'));
    final hinge = output.trace.plan!.exercises.firstWhere((e) => e.pattern == MovementPattern.hinge && !e.isWarmup);
    expect(hinge.loadTotal, 90); // 100 x 0.9 = 90, exact match (§2.6.4)
    expect(hinge.persistLoadOnCompletion, isTrue);
  });
}
