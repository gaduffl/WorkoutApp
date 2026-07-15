import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/ai/ai_explainer.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/fallback_templates.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/rule_key.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
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
    List<CheckIn> checkinHistory = const [],
    List<SessionLog> sessionLogs = const [],
    QueueState queueState = const QueueState(),
    Map<String, ExerciseState>? exerciseStates,
    UserSettings settings = const UserSettings(),
    SessionTypeId? forcedSessionId,
    DateTime? asOf,
  }) {
    final decisionDate = asOf ?? today;
    return DecisionEngineInput(
      checkin: CheckIn(
        date: decisionDate,
        timeMinutes: time,
        subjective: subjective,
        pain: pain,
        timestamp: decisionDate,
      ),
      todaySnapshot: todaySnapshot,
      recoveryHistory: recoveryHistory,
      checkinHistory: checkinHistory,
      sessionLogs: sessionLogs,
      exerciseStates: exerciseStates ?? baseStates(),
      queueState: queueState,
      settings: settings,
      today: decisionDate,
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
        time: 20, // S4 is not in the 20-minute conceptual candidate set
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
          buildLog(
            SessionTypeId.s3,
            today.subtract(const Duration(days: 2)),
            {FloorCategory.intensity},
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
          buildLog(
            SessionTypeId.s3,
            today.subtract(const Duration(days: 2)),
            {FloorCategory.intensity},
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
    expect(squat.rirTarget, Rir.rir4plus);
    final hinge = output.trace.plan!.exercises.firstWhere((e) => e.pattern == MovementPattern.hinge && !e.isWarmup);
    expect(hinge.sets, 3); // deload is per-pattern, not session-wide
  });

  test('a named pain substitute obeys its own active deload prescription', () {
    final states = baseStates();
    states[bridgeHamstringCurl.trackKey] = ExerciseState(
      trackKey: bridgeHamstringCurl.trackKey,
      pattern: bridgeHamstringCurl.pattern,
      currentLoad: 0,
      status: ExerciseStatus.deload,
      deloadSessionsRemaining: 2,
      preDeloadLoad: 0,
      lastTrainedDate: today.subtract(const Duration(days: 2)),
    );
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: states,
    ));

    final substitute = output.trace.plan!.exercises.firstWhere(
      (exercise) => exercise.trackKey == bridgeHamstringCurl.trackKey,
    );
    expect(substitute.sets, 1); // full-tier 3 sets -> deload half, floored
    expect(substitute.rirTarget, Rir.rir4plus);
    expect(output.trace.firedRuleCodes, contains('DELOAD_ACTIVE_HINGE'));
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

    expect(ex.first.trackKey, 'warmup:s1');
    expect(ex.first.isWarmup, isTrue);
    expect(ex.first.metric, ExerciseMetric.minutes);
    // squat (goblet, single-DB, 24 lb): ramp rounds down on the single-DB set
    final ramp = ex.where((e) => e.isWarmup && e.name.contains('Goblet squat')).toList();
    expect(ramp.map((e) => e.loadTotal), [9, 12, 18]);
    final squatIdx = ex.indexWhere((e) => e.pattern == MovementPattern.squat && !e.isWarmup);
    expect(squatIdx, greaterThan(0));
    // hinge (2-DB, 90 lb): one 60% feeder -> 54 rounds down to 50 matched
    final hingeIdx = ex.indexWhere((e) => e.pattern == MovementPattern.hinge && !e.isWarmup);
    expect(ex[hingeIdx - 1].isWarmup, isTrue);
    expect(ex[hingeIdx - 1].loadTotal, 50);
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

  test('§5 Step 7 "60->35": a 60-min session in a 35-min slot drops the accessory block', () {
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s2),
      sessionLogs: floorSatisfiedLogs(),
    ));
    final work = output.trace.plan!.exercises.where((e) => !e.isWarmup).toList();
    // all four primary superset compounds survive, the core/grip accessory does not
    expect(work.length, 4);
    expect(work.every((e) => e.pattern != MovementPattern.coreGrip), isTrue);
    expect(output.trace.plan!.plannedWorkSets, 12); // 4 x 3, fits the slot
    // at a true 60-min slot the accessory comes back (extended tier)
    final ext = decisionEngine.decide(buildInput(
      time: 60,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s2),
      sessionLogs: floorSatisfiedLogs(),
    ));
    expect(
      ext.trace.plan!.exercises.any((e) => !e.isWarmup && e.pattern == MovementPattern.coreGrip),
      isTrue,
    );
  });

  test('§2.6: work exercises carry their PowerBlock achievable-total steps', () {
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
    ));
    final squat = output.trace.plan!.exercises.firstWhere((e) => e.pattern == MovementPattern.squat && !e.isWarmup);
    // goblet squat is single-DB: steps are the union of both blocks
    expect(squat.loadSteps, isNotNull);
    expect(squat.loadSteps, containsAllInOrder([6, 9, 10, 12, 15, 18, 20, 21, 24, 25]));
    // and the current load sits on a real step
    expect(squat.loadSteps!.contains(squat.loadTotal), isTrue);
  });

  test('§2.5: consecutive compound work exercises are paired into superset groups', () {
    final output = decisionEngine.decide(buildInput(
      time: 60,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s2),
      sessionLogs: floorSatisfiedLogs(),
    ));
    final work = output.trace.plan!.exercises.where((e) => !e.isWarmup).toList();
    final compounds = work.where((e) => e.pattern.patternClass == PatternClass.compound).toList();
    // S2 extended has 4 compounds -> two superset groups (0,0,1,1)
    expect(compounds.map((e) => e.supersetGroup).toList(), [0, 0, 1, 1]);
    // the accessory (core/grip) stays straight
    final accessory = work.firstWhere((e) => e.pattern == MovementPattern.coreGrip);
    expect(accessory.supersetGroup, isNull);
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
    expect(work.every((e) => !e.progressionEligible), isTrue);
    expect(s1.trace.plan!.travelMode, isTrue);
    expect(s1.trace.firedRuleCodes, contains('TRAVEL_MODE_ACTIVE'));
    // no percent-load ramp without loads, but movement prep remains explicit
    final travelWarmups = s1.trace.plan!.exercises.where((e) => e.isWarmup).toList();
    expect(travelWarmups, hasLength(1));
    expect(travelWarmups.single.trackKey, 'warmup:s1');
    expect(s1.trace.plan!.plannedWorkSets, 6);

    final s2 = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s2),
      sessionLogs: floorSatisfiedLogs(),
      settings: const UserSettings(travelMode: true),
    ));
    final s2Names = s2.trace.plan!.exercises.map((e) => e.name).toSet();
    expect(s2Names, containsAll(const ['Prone lat pull-down', 'Prone W-row']));
    expect(s2Names.any((name) => name.contains('bar') || name.contains('Table')), isFalse);

    final s4 = decisionEngine.decide(buildInput(
      time: 60,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s4),
      sessionLogs: floorSatisfiedLogs(),
      settings: const UserSettings(travelMode: true),
    ));
    final s4Names = s4.trace.plan!.exercises.map((e) => e.name).toList();
    expect(s4Names, contains('Travel knee-health: backward walking, wall tibialis raises, calf raises'));
    expect(s4Names.any((name) => name.contains('treadmill') || name.contains('slant-board')), isFalse);

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
    final s5Work = s5.trace.plan!.exercises.where((e) => !e.isWarmup).toList();
    expect(
      s5Work.map((e) => e.name),
      containsAll(const ['Self-resisted curl', 'Prone Y-raise', 'Diamond push-up', 'Plank / hollow hold']),
    );
    expect(s5Work.every((e) => e.isTravel && e.loadTotal == null), isTrue);
  });

  test('travel mode keeps pain adjustments conservative without equipment', () {
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      settings: const UserSettings(travelMode: true),
    ));

    final work = output.trace.plan!.exercises.where((e) => !e.isWarmup).toList();
    expect(work.any((e) => e.name == 'Bridge hamstring curl'), isTrue);
    expect(work.every((e) => e.loadTotal == null), isTrue);
    expect(work.where((e) => e.instruction?.contains('pain-free range') == true), isNotEmpty);
    expect(work.where((e) => e.instruction?.contains('pain-free range') == true).every((e) => e.rirTarget == Rir.rir4plus), isTrue);
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

  test('§6.3: a third RED day starts global deload before double-RED rest', () {
    final states = baseStates();
    states['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      currentLoad: 24,
      status: ExerciseStatus.deload,
      deloadSessionsRemaining: 1,
      preDeloadLoad: 24,
    );
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 1,
      checkinHistory: [
        CheckIn(
          date: today.subtract(const Duration(days: 1)),
          timeMinutes: 35,
          subjective: 1,
          timestamp: today.subtract(const Duration(days: 1)),
        ),
        CheckIn(
          date: today.subtract(const Duration(days: 3)),
          timeMinutes: 35,
          subjective: 1,
          timestamp: today.subtract(const Duration(days: 3)),
        ),
      ],
      exerciseStates: states,
      sessionLogs: floorSatisfiedLogs(),
    ));

    expect(output.trace.firedRuleCodes, contains('REST_DOUBLE_RED'));
    expect(output.trace.plan, isNull);
    expect(output.patchedExerciseStates['hinge']!.status, ExerciseStatus.deload);
    // An already-active deload is preserved rather than reset to two sessions.
    expect(output.patchedExerciseStates['squat']!.deloadSessionsRemaining, 1);
  });

  test('§6.3: global deload also applies to a newly created scheduled state', () {
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 1,
      checkinHistory: [
        CheckIn(
          date: today.subtract(const Duration(days: 2)),
          timeMinutes: 35,
          subjective: 1,
          timestamp: today.subtract(const Duration(days: 2)),
        ),
        CheckIn(
          date: today.subtract(const Duration(days: 4)),
          timeMinutes: 35,
          subjective: 1,
          timestamp: today.subtract(const Duration(days: 4)),
        ),
      ],
      exerciseStates: {
        'squat': baseStates()['squat']!,
      },
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
    ));

    expect(output.trace.plan, isNotNull);
    expect(output.patchedExerciseStates['hinge']!.status, ExerciseStatus.deload);
    expect(output.patchedExerciseStates['hinge']!.deloadSessionsRemaining, 2);
  });

  test('sharp hip protection overrides a manually forced leg-heavy session', () {
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.hip,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
      forcedSessionId: SessionTypeId.s1,
    ));

    expect(sessionTypes[output.trace.plan!.sessionId]!.legHeavy, isFalse);
    expect(output.trace.firedRuleCodes, contains('PAIN_SUB_HIP_SESSION_SWAP_SHARP'));
  });

  test('pain re-entry is exactly 1 x 8 at the resolved 50% test load', () {
    final states = baseStates();
    states['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      currentLoad: 24,
      lastTrainedDate: today.subtract(const Duration(days: 2)),
      painFrozen: true,
      painSeverity: PainSeverity.sharp,
      painRegion: BodyRegion.kneeLeft,
      painFlaggedDate: today.subtract(const Duration(days: 2)),
      sessionsScheduledWhileFlagged: 2,
      lastPainScheduledDate: today.subtract(const Duration(days: 1)),
      prePainLoad: 24,
      painReentryTestOffered: true,
    );
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: states,
    ));

    final squat = output.trace.plan!.exercises.firstWhere(
      (exercise) => exercise.pattern == MovementPattern.squat && !exercise.isWarmup,
    );
    expect(squat.sets, 1);
    expect(squat.repRange, (8, 8));
    expect(squat.loadTotal, 12);
    expect(squat.rirTarget, Rir.rir4plus);
    expect(squat.instruction, contains('stop if pain returns'));
    expect(output.trace.firedRuleCodes, contains('PAIN_REENTRY_TEST_SQUAT'));
  });

  test('travel movement check does not claim to complete the loaded pain re-entry test', () {
    final states = baseStates();
    states['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      currentLoad: 24,
      lastTrainedDate: today.subtract(const Duration(days: 2)),
      painFrozen: true,
      painSeverity: PainSeverity.sharp,
      painRegion: BodyRegion.kneeLeft,
      painFlaggedDate: today.subtract(const Duration(days: 2)),
      sessionsScheduledWhileFlagged: 2,
      lastPainScheduledDate: today.subtract(const Duration(days: 1)),
      prePainLoad: 24,
      painReentryTestOffered: true,
    );
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: states,
      settings: const UserSettings(travelMode: true),
    ));

    final squat = output.trace.plan!.exercises.firstWhere(
      (exercise) => exercise.pattern == MovementPattern.squat && !exercise.isWarmup,
    );
    expect(squat.sets, 1);
    expect(squat.repRange, (8, 8));
    expect(squat.loadTotal, isNull);
    expect(squat.instruction, contains('formal loaded re-entry remains pending'));
    expect(output.trace.firedRuleCodes, isNot(contains('PAIN_REENTRY_TEST_SQUAT')));
    expect(output.trace.firedRuleCodes, contains('TRAVEL_MODE_ACTIVE'));
  });

  test('compressed travel S5 retains a bodyweight core work slot', () {
    final output = decisionEngine.decide(buildInput(
      time: 20,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s5),
      sessionLogs: floorSatisfiedLogs(),
      settings: const UserSettings(travelMode: true),
    ));

    final work = output.trace.plan!.exercises.where((exercise) => !exercise.isWarmup).toList();
    expect(work, isNotEmpty);
    final hold = work.firstWhere((exercise) => exercise.name == 'Plank / hollow hold');
    expect(hold.metric, ExerciseMetric.seconds);
    expect(hold.targetRange, (20, 45));
    expect(output.trace.plan!.plannedWorkSets, greaterThan(0));
  });

  test('home core holds use seconds while wrist curls remain rep-based', () {
    final plankOutput = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      queueState: const QueueState(pointer: SessionTypeId.s5),
      sessionLogs: floorSatisfiedLogs(),
    ));
    final plank = plankOutput.trace.plan!.exercises.firstWhere(
      (exercise) => exercise.name == 'Plank' && !exercise.isWarmup,
    );
    expect(plank.metric, ExerciseMetric.seconds);
    expect(plank.targetRange, (20, 45));
    expect(plank.targetLabel, '20-45 seconds');

    final states = baseStates()
      ..['coreGrip'] = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        ladderStepIndex: 4,
        currentLoad: 12,
        lastTrainedDate: today.subtract(const Duration(days: 2)),
      );
    final curlOutput = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      queueState: const QueueState(pointer: SessionTypeId.s5),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: states,
    ));
    final wristCurl = curlOutput.trace.plan!.exercises.firstWhere(
      (exercise) => exercise.name == 'Wrist curls' && !exercise.isWarmup,
    );
    expect(wristCurl.metric, ExerciseMetric.reps);
    expect(wristCurl.targetRange, (8, 15));
    expect(wristCurl.targetLabel, '8-15 reps');
  });

  test('every hold step has an explicit seconds prescription', () {
    final coreSteps = ladders[MovementPattern.coreGrip]!.steps;
    for (final name in ['Plank', 'L-sit progression', 'Hanging', 'Weighted hanging']) {
      final step = coreSteps.firstWhere((candidate) => candidate.name == name);
      expect(step.metric, ExerciseMetric.seconds, reason: name);
      expect(step.targetRange, isNotNull, reason: name);
      expect(step.targetRange!.$1, greaterThan(0), reason: name);
      expect(step.targetRange!.$2, greaterThan(step.targetRange!.$1), reason: name);
    }
    final wristCurl = coreSteps.firstWhere((step) => step.name == 'Wrist curls');
    expect(wristCurl.metric, ExerciseMetric.reps);
  });

  test('a strength template with no pain-free work returns a no-plan outcome', () {
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.tingling},
        ),
      ],
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
    ));

    expect(output.trace.plan, isNull);
    expect(output.trace.restReason, contains('No pain-free work'));
    expect(output.trace.queue.pointerAfterIfCompleted, isNull);
    expect(
      output.trace.firedRuleCodes,
      containsAll([
        'PAIN_MEDICAL_ESCALATION_SQUAT',
        'PAIN_MEDICAL_ESCALATION_HINGE',
      ]),
    );
    expect(
      output.trace.firedRules.any((rule) => rule.key == RuleKey.painSubSharp),
      isFalse,
    );
  });

  test('medical escalation wording is fixed in EN/DE and bypasses AI narration', () async {
    const rule = FiredRule(
      RuleKey.painMedicalEscalation,
      pattern: 'squat',
    );
    const english =
        'Stop the affected movement and seek a qualified medical assessment before resuming it.';
    const german =
        'Betroffene Bewegung stoppen und vor der Wiederaufnahme eine qualifizierte medizinische Abklärung suchen.';
    expect(fallbackText(rule, AppLanguage.en), english);
    expect(fallbackText(rule, AppLanguage.de), german);

    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.numbness},
        ),
      ],
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
    ));
    final explanation = await const AiExplainer().dailyExplanation(
      output.trace,
      const UserSettings(
        anthropicApiKey: 'must-not-be-used-for-safety-rule',
      ),
    );
    expect(explanation, english);
  });

  test('weekend prioritization selects S6 and emits its matching rule', () {
    final saturday = DateTime(2026, 1, 24);
    final weekendHistory = List.generate(
      20,
      (i) => RecoverySnapshot(
        date: saturday.subtract(Duration(days: i + 1)),
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
    );
    final weekendLogs = [
      buildLog(SessionTypeId.s1, saturday.subtract(const Duration(days: 1)), {FloorCategory.strength}),
      buildLog(SessionTypeId.s4, saturday.subtract(const Duration(days: 3)), {FloorCategory.strength}),
      buildLog(SessionTypeId.s3, saturday.subtract(const Duration(days: 2)), {FloorCategory.intensity}),
    ];
    final output = decisionEngine.decide(buildInput(
      time: 60,
      subjective: 4,
      asOf: saturday,
      todaySnapshot: RecoverySnapshot(
        date: saturday,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: weekendHistory,
      exerciseStates: const {},
      sessionLogs: weekendLogs,
    ));

    expect(output.trace.plan!.sessionId, SessionTypeId.s6);
    expect(output.trace.firedRuleCodes, contains('S6_WEEKEND_RULE'));
    final s6 = output.trace.candidates.firstWhere(
      (candidate) => candidate.sessionId == SessionTypeId.s6,
    );
    expect(s6.scoreTerms['weekendPriority'], 50);
  });

  test('a RED weekend S6 winner remains Zone 2 and never becomes a technique session', () {
    final saturday = DateTime(2026, 1, 24);
    final weekendLogs = [
      buildLog(SessionTypeId.s1, saturday.subtract(const Duration(days: 1)), {FloorCategory.strength}),
      buildLog(SessionTypeId.s4, saturday.subtract(const Duration(days: 3)), {FloorCategory.strength}),
      buildLog(SessionTypeId.s3, saturday.subtract(const Duration(days: 2)), {FloorCategory.intensity}),
    ];
    final output = decisionEngine.decide(buildInput(
      time: 60,
      subjective: 1,
      asOf: saturday,
      exerciseStates: const {},
      sessionLogs: weekendLogs,
    ));

    expect(output.trace.recovery.bucket, ReadinessBucket.red);
    expect(output.trace.plan!.sessionId, SessionTypeId.s6);
    expect(output.trace.plan!.grantsQueueCredit, isFalse);
    expect(output.trace.firedRuleCodes, contains('RED_SWAP_Z2'));
    expect(output.trace.firedRuleCodes, isNot(contains('RED_SWAP_TECHNIQUE')));
  });

  test('cardio duration is capped at its type duration and non-cycle cardio gets no credit', () {
    final s3 = decisionEngine.decide(buildInput(
      time: 60,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
      forcedSessionId: SessionTypeId.s3,
    ));
    final s7 = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
      forcedSessionId: SessionTypeId.s7,
    ));

    expect(s3.trace.plan!.estimatedDurationMin, 35);
    expect(s7.trace.plan!.estimatedDurationMin, 10);
    expect(s7.trace.plan!.grantsQueueCredit, isFalse);
  });

  test('every cardio plan visibly prescribes an easy warm-up without work-set credit', () {
    for (final id in [SessionTypeId.s3, SessionTypeId.s6, SessionTypeId.s7]) {
      final output = decisionEngine.decide(buildInput(
        time: 60,
        subjective: 4,
        todaySnapshot: RecoverySnapshot(
          date: today,
          hrvRmssd: 50,
          restingHr: 60,
          sleepScore: 90,
        ),
        recoveryHistory: normalHrvHistory(),
        sessionLogs: floorSatisfiedLogs(),
        forcedSessionId: id,
      ));
      final plan = output.trace.plan!;
      final warmup = plan.exercises.singleWhere((exercise) => exercise.isWarmup);
      expect(warmup.name, 'Easy cardio warm-up', reason: id.name);
      expect(warmup.metric, ExerciseMetric.minutes, reason: id.name);
      expect(warmup.instruction, isNotEmpty, reason: id.name);
      expect(plan.plannedWorkSets, 0, reason: id.name);
    }
  });

  test('CAP_LADDER_JUMP follows awaitingUndershootCheck, not detraining regression', () {
    final advancedStates = baseStates();
    advancedStates['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      ladderStepIndex: 1,
      currentLoad: 24,
      lastTrainedDate: today.subtract(const Duration(days: 2)),
      awaitingUndershootCheck: true,
    );
    final advanced = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: advancedStates,
    ));
    expect(advanced.trace.firedRuleCodes, contains('CAP_LADDER_JUMP_SQUAT'));

    final detrainedStates = baseStates();
    detrainedStates['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      ladderStepIndex: 1,
      currentLoad: 24,
      lastTrainedDate: today.subtract(const Duration(days: 30)),
    );
    final detrained = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: detrainedStates,
    ));
    expect(detrained.trace.firedRuleCodes, contains('DETRAIN_ADJUST_SQUAT'));
    expect(detrained.trace.firedRuleCodes, isNot(contains('CAP_LADDER_JUMP_SQUAT')));
  });

  test('pain resolution chooses the most restrictive flag independent of tap order', () {
    final lowerBack = PainFlag(
      region: BodyRegion.lowerBack,
      severity: PainSeverity.sharp,
      flaggedDate: today,
    );
    final knee = PainFlag(
      region: BodyRegion.kneeLeft,
      severity: PainSeverity.sharp,
      flaggedDate: today,
    );

    for (final flags in [
      [lowerBack, knee],
      [knee, lowerBack],
    ]) {
      final output = decisionEngine.decide(buildInput(
        time: 35,
        subjective: 4,
        pain: flags,
        todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
        recoveryHistory: normalHrvHistory(),
        queueState: const QueueState(pointer: SessionTypeId.s1),
        sessionLogs: floorSatisfiedLogs(),
      ));
      expect(
        output.trace.plan!.exercises.any(
          (exercise) => !exercise.isWarmup && exercise.pattern == MovementPattern.squat,
        ),
        isFalse,
      );
      expect(output.patchedExerciseStates['squat']!.painRegion, BodyRegion.kneeLeft);
    }
  });

  test('persisted escalation tags and stricter region survive a day without re-tapping', () {
    final first = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.mild,
          flaggedDate: today,
        ),
        PainFlag(
          region: BodyRegion.kneeLeft,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.radiating},
        ),
      ],
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
    ));
    final frozen = first.patchedExerciseStates['squat']!;
    expect(frozen.painRegion, BodyRegion.kneeLeft);
    expect(frozen.painTags, contains(PainTag.radiating));

    final nextDay = today.add(const Duration(days: 1));
    final second = decisionEngine.decide(DecisionEngineInput(
      checkin: CheckIn(
        date: nextDay,
        timeMinutes: 35,
        subjective: 4,
        timestamp: nextDay,
      ),
      todaySnapshot: null,
      recoveryHistory: const [],
      checkinHistory: const [],
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: first.patchedExerciseStates,
      queueState: const QueueState(pointer: SessionTypeId.s1),
      settings: const UserSettings(),
      today: nextDay,
    ));
    final squatStillScheduled = second.trace.plan?.exercises.any(
          (exercise) =>
              !exercise.isWarmup && exercise.pattern == MovementPattern.squat,
        ) ??
        false;
    expect(squatStillScheduled, isFalse);
    expect(second.patchedExerciseStates['squat']!.painRegion, BodyRegion.kneeLeft);
    expect(second.patchedExerciseStates['squat']!.painTags, contains(PainTag.radiating));
  });

  test('equal recency ties use a stable movement-pattern order', () {
    final squat = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      lastTrainedDate: today.subtract(const Duration(days: 10)),
    );
    final push = ExerciseState(
      trackKey: 'pushHorizontal',
      pattern: MovementPattern.pushHorizontal,
      lastTrainedDate: today.subtract(const Duration(days: 10)),
    );
    final outputs = [
      {'squat': squat, 'pushHorizontal': push},
      {'pushHorizontal': push, 'squat': squat},
    ].map((states) => decisionEngine.decide(buildInput(
          time: 35,
          subjective: 4,
          todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
          recoveryHistory: normalHrvHistory(),
          sessionLogs: floorSatisfiedLogs(),
          queueState: const QueueState(pointer: SessionTypeId.s1),
          exerciseStates: states,
        )));

    for (final output in outputs) {
      expect(output.trace.plan!.sessionId, SessionTypeId.s1);
      expect(output.trace.firedRuleCodes, contains('RECENCY_BOOST_SQUAT'));
    }
  });

  test('readiness prescriptions persist progression eligibility and exact RED RIR', () {
    final green = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
    ));
    final yellow = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 3,
      sessionLogs: floorSatisfiedLogs(),
    ));
    final red = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 1,
      sessionLogs: floorSatisfiedLogs(),
    ));

    final greenWork = green.trace.plan!.exercises.where((exercise) => !exercise.isWarmup);
    final yellowWork = yellow.trace.plan!.exercises.where((exercise) => !exercise.isWarmup);
    final redWork = red.trace.plan!.exercises.where((exercise) => !exercise.isWarmup);
    expect(greenWork.every((exercise) => exercise.progressionEligible), isTrue);
    expect(yellowWork.every((exercise) => !exercise.progressionEligible), isTrue);
    expect(redWork.every((exercise) => !exercise.progressionEligible), isTrue);
    expect(redWork.every((exercise) => exercise.rirTarget == Rir.rir4plus), isTrue);
  });

  test('20-minute S3 priority substitutes to S7 without compression trace or queue credit', () {
    final output = decisionEngine.decide(buildInput(
      time: 20,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s3),
      sessionLogs: floorSatisfiedLogs(),
    ));

    expect(output.trace.candidates.map((candidate) => candidate.sessionId), contains(SessionTypeId.s3));
    expect(output.trace.plan!.sessionId, SessionTypeId.s7);
    expect(output.trace.plan!.grantsQueueCredit, isFalse);
    expect(output.trace.firedRuleCodes, contains('S7_TIME_SUB'));
    expect(output.trace.firedRuleCodes, isNot(contains('TIME_COMPRESS_35_20')));
  });

  test('RED 20-minute S3 applies time substitution before the S7-to-S6 safety swap', () {
    final output = decisionEngine.decide(buildInput(
      time: 20,
      subjective: 1,
      queueState: const QueueState(pointer: SessionTypeId.s3),
      sessionLogs: floorSatisfiedLogs(),
    ));

    expect(output.trace.recovery.bucket, ReadinessBucket.red);
    expect(output.trace.plan!.sessionId, SessionTypeId.s6);
    expect(
      output.trace.firedRuleCodes,
      containsAllInOrder(['S7_TIME_SUB', 'RED_SWAP_Z2']),
    );
    expect(output.trace.plan!.grantsQueueCredit, isFalse);
  });

  test('native 20-minute S7 does not claim strength time compression', () {
    final output = decisionEngine.decide(buildInput(
      time: 20,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
      forcedSessionId: SessionTypeId.s7,
    ));
    expect(output.trace.firedRuleCodes, isNot(contains('TIME_COMPRESS_35_20')));
  });

  test('recency and queue rules describe only the actually selected plan', () {
    final overdueStates = baseStates();
    overdueStates['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      lastTrainedDate: today.subtract(const Duration(days: 10)),
    );
    final forced = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: overdueStates,
      forcedSessionId: SessionTypeId.s7,
    ));
    expect(forced.trace.firedRuleCodes, isNot(contains('RECENCY_BOOST_SQUAT')));

    final hipSwap = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      pain: [PainFlag(region: BodyRegion.hip, severity: PainSeverity.sharp, flaggedDate: today)],
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      sessionLogs: floorSatisfiedLogs(),
      queueState: const QueueState(pointer: SessionTypeId.s1),
    ));
    expect(hipSwap.trace.plan!.sessionId, isNot(SessionTypeId.s1));
    expect(hipSwap.trace.firedRuleCodes, isNot(contains('QUEUE_NEXT')));
  });

  test('floor rationale is omitted when a forced plan does not cover the pressured category', () {
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      settings: const UserSettings(
        weeklyFloor: {
          FloorCategory.strength: 2,
          FloorCategory.intensity: 0,
        },
      ),
      sessionLogs: const [],
      forcedSessionId: SessionTypeId.s7,
    ));

    expect(output.trace.plan!.sessionId, SessionTypeId.s7);
    expect(output.trace.firedRuleCodes, isNot(contains('FLOOR_FORCE_STRENGTH')));
    expect(output.trace.firedRuleCodes, isNot(contains('FLOOR_SOFT_BOOST')));
  });
}
