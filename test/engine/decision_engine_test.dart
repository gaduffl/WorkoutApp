import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/ai/ai_explainer.dart';
import 'package:morningcoach/engine/cardio_engine.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/fallback_templates.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
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
        durationMinutes: switch (id) {
          SessionTypeId.s3 => 35,
          SessionTypeId.s6 => 60,
          SessionTypeId.s7 => 10,
          _ => 30,
        },
        countsAs: categories,
      );

  /// Filled cardio-target history used to keep intensity/base pressure out of
  /// tests that exercise strength-plan assembly and safety mechanics.
  List<SessionLog> floorSatisfiedLogs() => [
        buildLog(SessionTypeId.s1, today.subtract(const Duration(days: 2)), {FloorCategory.strength}),
        buildLog(SessionTypeId.s4, today.subtract(const Duration(days: 4)), {FloorCategory.strength}),
        buildLog(SessionTypeId.s3, today.subtract(const Duration(days: 3)), {FloorCategory.intensity}),
        buildLog(SessionTypeId.s6, today.subtract(const Duration(days: 2)), {FloorCategory.aerobic}),
        buildLog(SessionTypeId.s7, today.subtract(const Duration(days: 5)), {FloorCategory.intensity}),
        buildLog(SessionTypeId.s7, today.subtract(const Duration(days: 7)), {FloorCategory.intensity}),
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
    bool forceQueuePointer = true,
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
      forcedSessionId:
          forcedSessionId ?? (forceQueuePointer ? queueState.pointer : null),
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
    expect(
      hinge.instruction,
      contains('This substitute starts deliberately light'),
    );

    final squat = trace.plan!.exercises.firstWhere((e) => e.pattern == MovementPattern.squat);
    expect(squat.loadTotal, lessThan(24));

    expect(trace.firedRuleCodes, containsAll(['ONBOARD_SUBSTITUTE', 'PAIN_SUB_HINGE_SHARP', 'PAIN_SUB_SQUAT_SHARP']));
    expect(
      output.patchedExerciseStates['squat']!
          .sessionsScheduledWhileFlagged,
      1,
    );
    expect(
      output.patchedExerciseStates['hinge']!
          .sessionsScheduledWhileFlagged,
      1,
    );
  });

  test('rest-day pain persists only affected normal tracks without scheduling them', () {
    final unaffectedHinge = ExerciseState(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      currentLoad: 90,
    );
    final painOnlySubstitute = ExerciseState(
      trackKey: bridgeHamstringCurl.trackKey,
      pattern: bridgeHamstringCurl.pattern,
      currentLoad: 12,
    );
    final output = decisionEngine.decide(buildInput(
      time: 0,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.kneeLeft,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
      exerciseStates: {
        unaffectedHinge.trackKey: unaffectedHinge,
        painOnlySubstitute.trackKey: painOnlySubstitute,
      },
    ));

    expect(output.trace.plan, isNull);
    expect(output.patchedExerciseStates.keys.toSet(), {
      'squat',
      unaffectedHinge.trackKey,
      painOnlySubstitute.trackKey,
    });
    final squat = output.patchedExerciseStates['squat']!;
    expect(squat.painFrozen, isTrue);
    expect(squat.painRegion, BodyRegion.kneeLeft);
    expect(squat.painSeverity, PainSeverity.sharp);
    expect(squat.sessionsScheduledWhileFlagged, 0);
    expect(squat.lastPainScheduledDate, isNull);
    expect(
      identical(
        output.patchedExerciseStates[unaffectedHinge.trackKey],
        unaffectedHinge,
      ),
      isTrue,
    );
    expect(
      identical(
        output.patchedExerciseStates[painOnlySubstitute.trackKey],
        painOnlySubstitute,
      ),
      isTrue,
    );
  });

  test('lower-back pain persists both lower tracks on a cardio safety swap', () {
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
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: const {},
      forcedSessionId: SessionTypeId.s3,
    ));

    expect(output.trace.plan!.sessionId, SessionTypeId.s6);
    for (final key in ['squat', 'hinge']) {
      final state = output.patchedExerciseStates[key]!;
      expect(state.painFrozen, isTrue, reason: key);
      expect(state.painRegion, BodyRegion.lowerBack, reason: key);
      expect(state.sessionsScheduledWhileFlagged, 0, reason: key);
      expect(state.lastPainScheduledDate, isNull, reason: key);
    }
  });

  test('persisted check-in pain blocks S3 and S7 next day without a re-tap', () {
    final restDay = decisionEngine.decide(buildInput(
      time: 0,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.hip,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
      exerciseStates: const {},
    ));
    final nextDay = today.add(const Duration(days: 1));

    for (final requested in [
      (SessionTypeId.s3, 35),
      (SessionTypeId.s7, 20),
    ]) {
      final output = decisionEngine.decide(buildInput(
        time: requested.$2,
        subjective: 4,
        pain: const [],
        todaySnapshot: RecoverySnapshot(
          date: nextDay,
          hrvRmssd: 50,
          restingHr: 60,
          sleepScore: 90,
        ),
        recoveryHistory: normalHrvHistory(),
        sessionLogs: floorSatisfiedLogs(),
        exerciseStates: restDay.patchedExerciseStates,
        forcedSessionId: requested.$1,
        asOf: nextDay,
      ));

      expect(
        output.trace.plan!.sessionId,
        anyOf(SessionTypeId.s2, SessionTypeId.s5),
      );
      expect(
        output.patchedExerciseStates['squat']!
            .sessionsScheduledWhileFlagged,
        0,
      );
      expect(
        output.patchedExerciseStates['hinge']!
            .sessionsScheduledWhileFlagged,
        0,
      );
    }
  });

  test('persisted sharp hip swaps next-day leg-heavy work without a re-tap', () {
    final restDay = decisionEngine.decide(buildInput(
      time: 0,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.hip,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
      exerciseStates: const {},
    ));
    final nextDay = today.add(const Duration(days: 1));
    DecisionEngineOutput forcedS1(Map<String, ExerciseState> states) =>
        decisionEngine.decide(buildInput(
          time: 35,
          subjective: 4,
          pain: const [],
          todaySnapshot: RecoverySnapshot(
            date: nextDay,
            hrvRmssd: 50,
            restingHr: 60,
            sleepScore: 90,
          ),
          recoveryHistory: normalHrvHistory(),
          sessionLogs: floorSatisfiedLogs(),
          exerciseStates: states,
          forcedSessionId: SessionTypeId.s1,
          asOf: nextDay,
        ));

    final sharp = forcedS1(restDay.patchedExerciseStates);
    expect(sharp.trace.plan!.sessionId, isNot(SessionTypeId.s1));
    expect(
      sharp.trace.firedRules.any(
        (rule) =>
            rule.key == RuleKey.painSubSharp &&
            rule.pattern == 'HIP_SESSION_SWAP',
      ),
      isTrue,
    );

    final mild = forcedS1({
      'squat': ExerciseState(
        trackKey: 'squat',
        pattern: MovementPattern.squat,
        painFrozen: true,
        painSeverity: PainSeverity.mild,
        painRegion: BodyRegion.hip,
        painFlaggedDate: today,
      ),
    });
    expect(mild.trace.plan!.sessionId, SessionTypeId.s1);
    expect(
      mild.trace.firedRules.any(
        (rule) =>
            rule.key == RuleKey.painSubSharp &&
            rule.pattern == 'HIP_SESSION_SWAP',
      ),
      isFalse,
    );
  });

  test('sharp hip selects upper strength in every window including travel', () {
    const cases = <(int, bool, SessionTypeId)>[
      (20, false, SessionTypeId.s1),
      (35, false, SessionTypeId.s3),
      (60, false, SessionTypeId.s6),
      (20, true, SessionTypeId.s1),
      (35, true, SessionTypeId.s1),
      (60, true, SessionTypeId.s1),
    ];
    for (final (minutes, travel, forced) in cases) {
      final output = decisionEngine.decide(buildInput(
        time: minutes,
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
        settings: UserSettings(travelMode: travel),
        exerciseStates: const {},
        forcedSessionId: forced,
      ));

      expect(
        output.trace.plan!.sessionId,
        anyOf(SessionTypeId.s2, SessionTypeId.s5),
        reason: '$minutes minutes, travel=$travel, forced=${forced.name}',
      );
      expect(output.trace.plan!.exercises, isNotEmpty);
      for (final key in ['squat', 'hinge']) {
        final state = output.patchedExerciseStates[key]!;
        expect(state.painRegion, BodyRegion.hip, reason: key);
        expect(state.painSeverity, PainSeverity.sharp, reason: key);
        expect(state.sessionsScheduledWhileFlagged, 0, reason: key);
      }
      expect(
        output.trace.firedRules.any(
          (rule) =>
              rule.key == RuleKey.painSubSharp &&
              rule.pattern == 'HIP_SESSION_SWAP',
        ),
        isTrue,
      );
      if (travel) {
        expect(
          output.trace.plan!.exercises
              .where((exercise) => !exercise.isWarmup)
              .every((exercise) => exercise.isTravel),
          isTrue,
        );
      }
    }
  });

  test('v2 ignores legacy weekly-floor pressure in selection and trace', () {
    final input = buildInput(
      time: 35,
      subjective: 3,
      todaySnapshot: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 90),
      recoveryHistory: normalHrvHistory(),
      queueState: const QueueState(pointer: SessionTypeId.s3), // intensity is "next"
      sessionLogs: const [],
      forceQueuePointer: false,
    );
    final output = decisionEngine.decide(input);

    expect(output.trace.plan!.sessionId, SessionTypeId.s3);
    expect(
      output.trace.firedRuleCodes.where((code) => code.startsWith('FLOOR_')),
      isEmpty,
    );
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

  test('surplus intensity is scored below target-bearing candidates', () {
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

    final s7 = order.indexOf(SessionTypeId.s7);
    expect(s7, order.length - 1);
    expect(
      output.trace.candidates
          .firstWhere((candidate) => candidate.sessionId == SessionTypeId.s7)
          .scoreTerms,
      contains('surplusIntensitySuppressed'),
    );
  });

  group('§11 swap session', () {
    test('forcedSessionId overrides the natural winner but still runs modulation/pain steps', () {
      final input = buildInput(
        time: 35,
        subjective: 4,
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

    test('20-minute S6 is a valid forced recovery-cardio option', () {
      final input = buildInput(
        time: 20,
        subjective: 4,
        queueState: const QueueState(pointer: SessionTypeId.s1),
        forcedSessionId: SessionTypeId.s6,
      );
      final output = decisionEngine.decide(input);

      expect(output.trace.plan!.sessionId, SessionTypeId.s6);
      expect(output.trace.plan!.estimatedDurationMin, lessThanOrEqualTo(20));
    });
  });

  test('legacy weeklyFloor settings no longer change v2 scores', () {
    final normal = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      sessionLogs: floorSatisfiedLogs(),
      forceQueuePointer: false,
    ));
    final extremeLegacyFloor = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      sessionLogs: floorSatisfiedLogs(),
      forceQueuePointer: false,
      settings: const UserSettings(
        weeklyFloor: {
          FloorCategory.strength: 99,
          FloorCategory.intensity: 99,
        },
      ),
    ));

    expect(extremeLegacyFloor.trace.plan!.sessionId, normal.trace.plan!.sessionId);
    expect(
      extremeLegacyFloor.trace.candidates.map((candidate) => candidate.score),
      normal.trace.candidates.map((candidate) => candidate.score),
    );
    expect(
      extremeLegacyFloor.trace.firedRuleCodes
          .where((code) => code.startsWith('FLOOR_')),
      isEmpty,
    );
  });

  test('§6 order: 20-min YELLOW stacks compression then recovery volume reduction', () {
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
    // Baseline compressed compound sets = 2 (§2.5); integer reduction gives 1.
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
    states[bridgeHamstringCurl.trackKey] = ExerciseState(
      trackKey: bridgeHamstringCurl.trackKey,
      pattern: bridgeHamstringCurl.pattern,
      currentLoad: 12,
      lastTrainedDate: today.subtract(const Duration(days: 2)),
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
    expect(output.trace.firedRuleCodes, isNot(contains('ONBOARD_SUBSTITUTE')));
    final hinge = output.trace.plan!.exercises.firstWhere((e) => e.substitutedFrom == 'hinge');
    expect(hinge.trackKey, startsWith('sub:'));
    expect(
      hinge.instruction,
      'Use a pain-free range and stop if pain worsens.',
    );
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
    expect(ramp.every((e) => e.dumbbellCount == 1), isTrue);
    final squatIdx = ex.indexWhere((e) => e.pattern == MovementPattern.squat && !e.isWarmup);
    expect(squatIdx, greaterThan(0));
    expect(ex[squatIdx].dumbbellCount, 1);
    // hinge (2-DB, 90 lb): one 60% feeder -> 54 rounds down to 50 matched
    final hingeIdx = ex.indexWhere((e) => e.pattern == MovementPattern.hinge && !e.isWarmup);
    expect(ex[hingeIdx].dumbbellCount, 2);
    expect(ex[hingeIdx].allowsUnevenPair, isTrue);
    expect(ex[hingeIdx - 1].isWarmup, isTrue);
    expect(ex[hingeIdx - 1].loadTotal, 50);
    expect(ex[hingeIdx - 1].dumbbellCount, 2);
    expect(ex[hingeIdx - 1].allowsUnevenPair, isTrue);
    // warm-ups never count toward the §8 completion denominator
    expect(output.trace.plan!.plannedWorkSets, 6);
  });

  test('the ATG block replaces general prep, not the first-compound ramp', () {
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
    expect(ex.first.targetRange, (5, 5));
    expect(ex.first.name, 'ATG + upper-body prep');
    for (final cue in [
      '0:00–2:00 · Backward treadmill',
      '2:00–2:45 · Tibialis raises (15–20)',
      '2:45–3:30 · Calf raises (15–20)',
      '3:30–4:15 · Shoulder circles (10 each direction)',
      '4:15–5:00 · Scapular push-ups (8–12)',
      'Replaces general movement prep.',
    ]) {
      expect(ex.first.instruction, contains(cue));
    }
    expect(ex.any((e) => e.name.contains('40%')), isTrue);
    expect(ex.any((e) => e.name.contains('80%')), isTrue);
    // The first compound gets the full 40/60/80 ramp.
    final squatIdx = ex.indexWhere((e) => e.pattern == MovementPattern.squat && !e.isWarmup);
    expect(ex[squatIdx - 1].isWarmup, isTrue);
    expect(ex[squatIdx - 1].name, contains('80%'));
  });

  test('current knee pain replaces S4 ATG loading with equal-time pain-aware prep', () {
    final output = decisionEngine.decide(buildInput(
      time: 60,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.kneeLeft,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      queueState: const QueueState(pointer: SessionTypeId.s4),
      sessionLogs: floorSatisfiedLogs(),
    ));
    final prep = output.trace.plan!.exercises.first;

    expect(prep.trackKey, 'atg_block');
    expect(prep.isWarmup, isTrue);
    expect(prep.targetRange, (5, 5));
    expect(prep.name, 'Pain-aware general + upper/scapular prep');
    expect(prep.name, isNot(contains('ATG')));
    expect(prep.instruction, contains('Skip backward treadmill'));
    expect(prep.instruction, contains('pain-provoking knee movement'));
  });

  test('persisted shoulder pain removes reproducing upper warm-up cues', () {
    final states = baseStates();
    states['pushHorizontal'] = ExerciseState(
      trackKey: 'pushHorizontal',
      pattern: MovementPattern.pushHorizontal,
      currentLoad: 40,
      painFrozen: true,
      painSeverity: PainSeverity.mild,
      painRegion: BodyRegion.shoulderLeft,
      painFlaggedDate: today.subtract(const Duration(days: 1)),
    );
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      queueState: const QueueState(pointer: SessionTypeId.s2),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: states,
    ));
    final prep = output.trace.plan!.exercises.first;

    expect(prep.trackKey, 'warmup:s2');
    expect(prep.isWarmup, isTrue);
    expect(prep.targetRange, (5, 5));
    expect(prep.instruction, contains('non-reproducing scapular motion'));
    expect(prep.instruction, contains('Skip every flagged'));
    expect(prep.instruction, isNot(contains('shoulder circles')));
    expect(prep.instruction, isNot(contains('scapular push-ups')));
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
    final s4Prep = s4.trace.plan!.exercises.singleWhere(
      (exercise) => exercise.trackKey == 'atg_block',
    );
    expect(s4Prep.name, 'Travel ATG + upper-body prep');
    expect(s4Prep.targetRange, (5, 5));
    for (final cue in [
      '0:00–2:00 · Safe backward walking',
      '2:00–2:45 · Wall tibialis raises (15–20)',
      '2:45–3:30 · Wall calf raises (15–20)',
      '3:30–4:15 · Shoulder circles (10 each direction)',
      '4:15–5:00 · Scapular push-ups (8–12)',
      'No equipment; replaces general movement prep.',
    ]) {
      expect(s4Prep.instruction, contains(cue));
    }
    expect(
      s4.trace.plan!.exercises
          .map((exercise) => exercise.name)
          .any((name) => name.contains('treadmill') || name.contains('slant-board')),
      isFalse,
    );

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

  test('YELLOW and RED detraining plans retain their emitted safe baseline marker', () {
    for (final subjective in [3, 1]) {
      final states = baseStates();
      states['hinge'] = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 100,
        lastTrainedDate: today.subtract(const Duration(days: 15)),
      );
      final output = decisionEngine.decide(buildInput(
        time: 35,
        subjective: subjective,
        queueState: const QueueState(pointer: SessionTypeId.s1),
        sessionLogs: floorSatisfiedLogs(),
        exerciseStates: states,
      ));
      final hinge = output.trace.plan!.exercises.firstWhere(
        (exercise) =>
            exercise.pattern == MovementPattern.hinge &&
            !exercise.isWarmup,
      );

      expect(
        output.trace.recovery.bucket,
        subjective == 1 ? ReadinessBucket.red : ReadinessBucket.yellow,
      );
      expect(output.trace.firedRuleCodes, contains('DETRAIN_ADJUST_HINGE'));
      expect(hinge.persistLoadOnCompletion, isTrue);
      expect(hinge.progressionEligible, isFalse);
      expect(hinge.loadTotal, isNotNull);
      expect(hinge.loadTotal, lessThanOrEqualTo(90));
    }
  });

  test('first-ever work uses the minimum load without comeback narration', () {
    final states = baseStates();
    states['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      currentLoad: 0,
    );
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: states,
    ));

    final squat = output.trace.plan!.exercises.firstWhere(
      (exercise) =>
          !exercise.isWarmup && exercise.pattern == MovementPattern.squat,
    );
    expect(output.trace.firedRuleCodes, isNot(contains('DETRAIN_ADJUST_SQUAT')));
    expect(squat.loadTotal, 6, reason: 'the minimum single-DB load remains the onboarding load');
    expect(squat.persistLoadOnCompletion, isFalse);
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

  test('§6.3: the same at-or-above-three RED cluster never retriggers completed tracks', () {
    final completedWithinEpisode = baseStates();
    completedWithinEpisode['hinge'] = ExerciseState(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      currentLoad: 80,
      status: ExerciseStatus.progress,
      deloadSessionsRemaining: 0,
    );
    completedWithinEpisode['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      currentLoad: 20,
      status: ExerciseStatus.deload,
      deloadSessionsRemaining: 1,
      preDeloadLoad: 24,
    );
    final nextDay = today.add(const Duration(days: 1));
    final output = decisionEngine.decide(buildInput(
      time: 0,
      subjective: 4,
      asOf: nextDay,
      checkinHistory: [
        for (final redDate in [
          today,
          today.subtract(const Duration(days: 2)),
          today.subtract(const Duration(days: 4)),
        ])
          CheckIn(
            date: redDate,
            timeMinutes: 35,
            subjective: 1,
            timestamp: redDate,
          ),
      ],
      exerciseStates: completedWithinEpisode,
      forceQueuePointer: false,
    ));

    expect(output.trace.plan, isNull);
    expect(
      output.patchedExerciseStates['hinge']!.status,
      ExerciseStatus.progress,
    );
    expect(
      output.patchedExerciseStates['hinge']!.deloadSessionsRemaining,
      0,
    );
    expect(
      output.patchedExerciseStates['squat']!.deloadSessionsRemaining,
      1,
    );
  });

  test('§6.3: a later RED threshold crossing starts a new deload episode', () {
    final later = today.add(const Duration(days: 10));
    final output = decisionEngine.decide(buildInput(
      time: 0,
      subjective: 1,
      asOf: later,
      checkinHistory: [
        for (final daysAgo in const [2, 4])
          CheckIn(
            date: later.subtract(Duration(days: daysAgo)),
            timeMinutes: 35,
            subjective: 1,
            timestamp: later.subtract(Duration(days: daysAgo)),
          ),
      ],
      exerciseStates: {
        'hinge': ExerciseState(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          currentLoad: 80,
          status: ExerciseStatus.progress,
        ),
      },
      forceQueuePointer: false,
    ));

    expect(output.trace.plan, isNull);
    expect(
      output.patchedExerciseStates['hinge']!.status,
      ExerciseStatus.deload,
    );
    expect(
      output.patchedExerciseStates['hinge']!.deloadSessionsRemaining,
      2,
    );
  });

  test('§6.3: automatic global deload persists for unscheduled tracks after the trigger ages out', () {
    final triggered = decisionEngine.decide(buildInput(
      time: 0,
      subjective: 1,
      checkinHistory: [
        for (final daysAgo in const [2, 4])
          CheckIn(
            date: today.subtract(Duration(days: daysAgo)),
            timeMinutes: 35,
            subjective: 1,
            timestamp: today.subtract(Duration(days: daysAgo)),
          ),
      ],
      exerciseStates: const {},
      forceQueuePointer: false,
    ));

    expect(triggered.trace.plan, isNull);
    expect(
      triggered.patchedExerciseStates[overheadTriceps.trackKey]!.status,
      ExerciseStatus.deload,
    );
    expect(
      triggered.patchedExerciseStates[overheadTriceps.trackKey]!
          .deloadSessionsRemaining,
      2,
    );

    final afterTriggerAgedOut = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      asOf: today.add(const Duration(days: 8)),
      checkinHistory: const [],
      exerciseStates: triggered.patchedExerciseStates,
      forcedSessionId: SessionTypeId.s5,
    ));
    final triceps = afterTriggerAgedOut.trace.plan!.exercises.firstWhere(
      (exercise) => exercise.trackKey == overheadTriceps.trackKey,
    );

    expect(triceps.rirTarget, Rir.rir4plus);
    expect(triceps.sets, 1);
    expect(
      afterTriggerAgedOut.trace.firedRuleCodes,
      contains('DELOAD_ACTIVE_PUSHVERTICAL'),
    );
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

  test('compressed travel S5 preserves its dynamic pair with viable variants', () {
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
    expect(work, hasLength(2));
    expect(
      work.map((exercise) => exercise.name),
      ['Self-resisted curl', 'Prone Y-raise'],
    );
    expect(work.every((exercise) => exercise.isTravel), isTrue);
    expect(output.trace.plan!.plannedWorkSets, greaterThan(0));
  });

  test('mild wrist pain reduces every S5 named accessory by one real load step', () {
    final states = baseStates();
    for (final named in s5NamedAccessories) {
      states[named.trackKey] = ExerciseState(
        trackKey: named.trackKey,
        pattern: named.pattern,
        ladderStepIndex: 3,
        currentLoad: 24,
        lastTrainedDate: today.subtract(const Duration(days: 2)),
      );
    }
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.wrist,
          severity: PainSeverity.mild,
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
      exerciseStates: states,
      forcedSessionId: SessionTypeId.s5,
    ));
    final workByKey = {
      for (final exercise
          in output.trace.plan!.exercises.where((value) => !value.isWarmup))
        exercise.trackKey: exercise,
    };

    for (final named in s5NamedAccessories) {
      expect(workByKey[named.trackKey]!.loadTotal, 21, reason: named.name);
      expect(
        workByKey[named.trackKey]!.instruction,
        contains('pain-free range'),
        reason: named.name,
      );
    }
  });

  test('mild shoulder pain keeps named S5 tracks and uses single-DB reduction', () {
    final states = baseStates();
    for (final named in s5NamedAccessories) {
      states[named.trackKey] = ExerciseState(
        trackKey: named.trackKey,
        pattern: named.pattern,
        ladderStepIndex: 3,
        currentLoad: 24,
        lastTrainedDate: today.subtract(const Duration(days: 2)),
      );
    }
    final output = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      pain: [
        PainFlag(
          region: BodyRegion.shoulderLeft,
          severity: PainSeverity.mild,
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
      exerciseStates: states,
      forcedSessionId: SessionTypeId.s5,
    ));
    final workByKey = {
      for (final exercise
          in output.trace.plan!.exercises.where((value) => !value.isWarmup))
        exercise.trackKey: exercise,
    };

    expect(workByKey[dbCurl.trackKey]!.loadTotal, 24);
    for (final named in [lateralRaise, overheadTriceps]) {
      final exercise = workByKey[named.trackKey]!;
      expect(exercise.name, named.name);
      expect(exercise.loadTotal, 21, reason: named.name);
      expect(exercise.instruction, contains('pain-free range'));
      expect(
        output.patchedExerciseStates[named.trackKey]!.ladderStepIndex,
        3,
      );
    }
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
    expect(plank.targetRange, (20, 60));
    expect(plank.targetLabel, '20-60 seconds');
    expect(plank.suggestedValue, 60);
    expect(plank.progressionFraction, inInclusiveRange(0.0, 1.0));
    expect(plank.progressionLabel, contains('Difficulty 1 of 5'));
    expect(plank.progressionLabel, contains('60-second Plank'));
    expect(plank.nextProgressionLabel, contains('controlled transition'));

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

  test('timed deload lowers the hold itself and hides earnable progress', () {
    final states = baseStates()
      ..['coreGrip'] = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        currentTargetValue: 60,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 1,
        preDeloadTargetValue: 60,
        lastTrainedDate: today.subtract(const Duration(days: 2)),
      );
    final output = decisionEngine.decide(buildInput(
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

    final plank = output.trace.plan!.exercises.firstWhere(
      (exercise) => exercise.name == 'Plank' && !exercise.isWarmup,
    );
    expect(plank.metric, ExerciseMetric.seconds);
    expect(plank.targetRange, (35, 35));
    expect(plank.suggestedValue, 35);
    expect(plank.progressionFraction, isNull);
    expect(plank.prescriptionChange, isNull);
  });

  test('active rep micro-stages emit deterministic execution cues', () {
    const expectations = <(int, String)>[
      (1, 'slow 3-second eccentric'),
      (2, 'controlled 1-second pause'),
      (3, 'deficit or range of motion'),
    ];

    for (final (stage, expectedCue) in expectations) {
      final states = baseStates();
      states['squat'] = ExerciseState(
        trackKey: 'squat',
        pattern: MovementPattern.squat,
        currentLoad: 24,
        lastTrainedDate: today.subtract(const Duration(days: 2)),
        microStepStage: stage,
      );
      final output = decisionEngine.decide(buildInput(
        time: 35,
        subjective: 4,
        recoveryHistory: normalHrvHistory(),
        todaySnapshot: RecoverySnapshot(
          date: today,
          hrvRmssd: 50,
          restingHr: 60,
          sleepScore: 90,
        ),
        queueState: const QueueState(pointer: SessionTypeId.s1),
        sessionLogs: floorSatisfiedLogs(),
        exerciseStates: states,
      ));

      final squat = output.trace.plan!.exercises.firstWhere(
        (exercise) =>
            !exercise.isWarmup && exercise.pattern == MovementPattern.squat,
      );
      expect(squat.instruction, contains(expectedCue), reason: 'stage $stage');
    }
  });

  test('timed-hold micro-stages use position and leverage cues, never rep cues', () {
    const expectations = <(int, String)>[
      (1, 'controlled transition'),
      (2, 'strict hold'),
      (3, 'harder leverage'),
    ];

    for (final (stage, expectedCue) in expectations) {
      final states = baseStates();
      states['coreGrip'] = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        lastTrainedDate: today.subtract(const Duration(days: 2)),
        microStepStage: stage,
      );
      final output = decisionEngine.decide(buildInput(
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

      final hold = output.trace.plan!.exercises.firstWhere(
        (exercise) => exercise.name == 'Plank' && !exercise.isWarmup,
      );
      expect(hold.instruction, contains(expectedCue), reason: 'stage $stage');
      expect(hold.instruction, isNot(matches(RegExp(r'\breps?\b'))));
    }
  });

  test('recovery, deload, pain re-entry, travel, and warm-ups suppress micro cues', () {
    Map<String, ExerciseState> stagedStates() => {
          ...baseStates(),
          'squat': ExerciseState(
            trackKey: 'squat',
            pattern: MovementPattern.squat,
            currentLoad: 24,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
            microStepStage: 2,
          ),
        };

    final yellow = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 3,
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: stagedStates(),
    ));
    final yellowWork = yellow.trace.plan!.exercises.where(
      (exercise) => !exercise.isWarmup,
    );
    expect(yellow.trace.recovery.bucket, ReadinessBucket.yellow);
    expect(yellowWork.every((exercise) => exercise.instruction == null), isTrue);

    final deloadStates = stagedStates();
    deloadStates['squat'] = ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      currentLoad: 24,
      lastTrainedDate: today.subtract(const Duration(days: 2)),
      status: ExerciseStatus.deload,
      deloadSessionsRemaining: 1,
      preDeloadLoad: 24,
      microStepStage: 2,
    );
    final deload = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: deloadStates,
    ));
    final deloadSquat = deload.trace.plan!.exercises.firstWhere(
      (exercise) =>
          !exercise.isWarmup && exercise.pattern == MovementPattern.squat,
    );
    expect(deloadSquat.instruction, isNull);

    final reentryStates = stagedStates();
    reentryStates['squat'] = ExerciseState(
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
      microStepStage: 2,
    );
    final reentry = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: reentryStates,
    ));
    final reentrySquat = reentry.trace.plan!.exercises.firstWhere(
      (exercise) =>
          !exercise.isWarmup && exercise.pattern == MovementPattern.squat,
    );
    expect(reentrySquat.instruction, contains('stop if pain returns'));
    expect(reentrySquat.instruction, isNot(contains('Micro-progression')));

    final travel = decisionEngine.decide(buildInput(
      time: 35,
      subjective: 4,
      recoveryHistory: normalHrvHistory(),
      todaySnapshot: RecoverySnapshot(
        date: today,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: floorSatisfiedLogs(),
      exerciseStates: stagedStates(),
      settings: const UserSettings(travelMode: true),
    ));
    final travelWork = travel.trace.plan!.exercises.where(
      (exercise) => !exercise.isWarmup,
    );
    expect(
      travelWork.every(
        (exercise) =>
            exercise.instruction?.contains('Micro-progression') != true,
      ),
      isTrue,
    );
    expect(
      travel.trace.plan!.exercises
          .where((exercise) => exercise.isWarmup)
          .every(
            (exercise) =>
                exercise.instruction?.contains('Micro-progression') != true,
          ),
      isTrue,
    );
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
        PainFlag(
          region: BodyRegion.shoulderLeft,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.numbness},
        ),
        PainFlag(
          region: BodyRegion.elbow,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.radiating},
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
        PainFlag(
          region: BodyRegion.shoulderLeft,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.tingling},
        ),
        PainFlag(
          region: BodyRegion.elbow,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.radiating},
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

  test('new selection rationales have deterministic EN/DE fallback copy', () {
    const recovery = FiredRule(RuleKey.easyRecoveryCardio);
    const manual = FiredRule(
      RuleKey.manualSessionOverride,
      params: {'session': 'Upper Strength'},
    );

    expect(
      fallbackText(recovery, AppLanguage.en),
      contains('no current base-aerobic deficit'),
    );
    expect(
      fallbackText(recovery, AppLanguage.de),
      contains('kein aktuelles Grundlagendefizit'),
    );
    expect(fallbackText(manual, AppLanguage.en), contains('Upper Strength'));
    expect(fallbackText(manual, AppLanguage.de), contains('Upper Strength'));
    final yellow = fallbackText(
      const FiredRule(RuleKey.yellowVolumeCut),
      AppLanguage.en,
    );
    expect(yellow, contains('training volume is reduced'));
    expect(yellow, isNot(contains('%')));
  });

  test('long base deficit yields to feasible strength deficits', () {
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
      forceQueuePointer: false,
    ));

    expect(output.trace.plan!.sessionId, isNot(SessionTypeId.s6));
    expect(output.trace.firedRuleCodes, isNot(contains('BASE_LONG_DEFICIT')));
    final s6 = output.trace.candidates.firstWhere(
      (candidate) => candidate.sessionId == SessionTypeId.s6,
    );
    expect(s6.scoreTerms, isNot(contains('baseLongDeficit')));
    expect(s6.scoreTerms, isNot(contains('weekendPriority')));
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
      forceQueuePointer: false,
    ));

    expect(output.trace.recovery.bucket, ReadinessBucket.red);
    expect(output.trace.plan!.sessionId, SessionTypeId.s6);
    expect(output.trace.plan!.grantsQueueCredit, isFalse);
    expect(output.trace.firedRuleCodes, contains('RED_SWAP_Z2'));
    expect(output.trace.firedRuleCodes, isNot(contains('RED_SWAP_TECHNIQUE')));
  });

  test('CAROL presets keep fixed duration and full tier', () {
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

    expect(s3.trace.plan!.estimatedDurationMin, 30);
    expect(s3.trace.plan!.tier, SessionTier.full);
    expect(s7.trace.plan!.estimatedDurationMin, 9);
    expect(s7.trace.plan!.tier, SessionTier.full);
    expect(s7.trace.plan!.grantsQueueCredit, isFalse);
  });

  test('all emitted cardio plans carry exact explicit prescriptions', () {
    DecisionEngineOutput outputFor(
      SessionTypeId id,
      int time, {
      UserSettings settings = const UserSettings(age: 40),
    }) =>
        decisionEngine.decide(buildInput(
          time: time,
          subjective: 4,
          todaySnapshot: RecoverySnapshot(
            date: today,
            hrvRmssd: 50,
            restingHr: 60,
            sleepScore: 90,
          ),
          recoveryHistory: normalHrvHistory(),
          sessionLogs: floorSatisfiedLogs(),
          settings: settings,
          forcedSessionId: id,
        ));

    final fourByFour = outputFor(SessionTypeId.s3, 60).trace.plan!;
    final p4 = fourByFour.cardioPrescription!;
    expect(p4.protocol.type, CardioProtocolType.norwegian4x4);
    expect(p4.plannedDurationSeconds, 1800);
    expect(p4.plannedWorkIntervals, 4);
    expect(p4.plannedWorkSeconds, 960);
    expect(p4.plannedRecoveryIntervals, 3);
    expect(p4.plannedRecoverySeconds, 540);
    // Default HRmax for age 40 is 180: 85-95% = 153-171 bpm.
    expect(p4.targetHeartRateMinBpm, closeTo(153, 0.0001));
    expect(p4.targetHeartRateMaxBpm, closeTo(171, 0.0001));
    expect(p4.targetRpeMin, 8);
    expect(p4.targetRpeMax, 9);

    for (final minutes in [35, 60]) {
      final base = outputFor(
        SessionTypeId.s6,
        minutes,
        settings: const UserSettings(age: 40, hrMaxOverride: 200),
      ).trace.plan!;
      final p6 = base.cardioPrescription!;
      expect(base.estimatedDurationMin, minutes);
      expect(p6.protocol.type, CardioProtocolType.zone2Base);
      expect(p6.plannedWorkIntervals, 1);
      expect(p6.plannedWorkSeconds, minutes * 60);
      expect(p6.plannedDurationSeconds, minutes * 60);
      expect(p6.targetHeartRateMinBpm, 130);
      expect(p6.targetHeartRateMaxBpm, 150);
      expect(p6.targetRpeMin, 3);
      expect(p6.targetRpeMax, 4);
    }

    final rehit = outputFor(SessionTypeId.s7, 35).trace.plan!;
    final p7 = rehit.cardioPrescription!;
    expect(p7.protocol.type, CardioProtocolType.rehit);
    expect(p7.plannedDurationSeconds, 520);
    expect(p7.plannedWorkIntervals, 2);
    expect(p7.plannedWorkSeconds, 40);
    expect(p7.plannedRecoveryIntervals, 0);
    expect(p7.plannedRecoverySeconds, 0);
    expect(p7.targetHeartRateMinBpm, isNull);
    expect(p7.targetRpeMin, 9);
    expect(p7.targetRpeMax, 10);
  });

  test('RED 20-minute safety swap stays inside the slot and is non-qualifying base work', () {
    final output = decisionEngine.decide(buildInput(
      time: 20,
      subjective: 1,
      queueState: const QueueState(pointer: SessionTypeId.s3),
      sessionLogs: floorSatisfiedLogs(),
      forcedSessionId: SessionTypeId.s3,
    ));

    final plan = output.trace.plan!;
    expect(plan.sessionId, SessionTypeId.s6);
    expect(plan.estimatedDurationMin, 20);
    expect(plan.grantsQueueCredit, isFalse);
    expect(plan.cardioPrescription!.plannedDurationSeconds, 1200);
    expect(plan.cardioPrescription!.plannedWorkSeconds, 1200);
    expect(plan.exercises, isEmpty);
    final completion = const CardioEngine().completionFromEntry(
      prescription: plan.cardioPrescription!,
      completedWorkIntervals: 1,
      completedDurationMinutes: 20,
    );
    expect(completion.meetsCreditableDose, isFalse);
  });

  test('cardio plans contain no app-added warm-up exercises', () {
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
      expect(plan.exercises, isEmpty, reason: id.name);
      expect(plan.plannedWorkSets, 0, reason: id.name);
      expect(plan.cardioPrescription, isNotNull, reason: id.name);
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
      expect(
        output.patchedExerciseStates['squat']!
            .sessionsScheduledWhileFlagged,
        0,
      );
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

  test('exercise-state insertion order does not affect v2 target scores', () {
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
        ))).toList();

    for (final output in outputs) {
      expect(output.trace.plan!.sessionId, SessionTypeId.s1);
      expect(output.trace.firedRuleCodes, contains('MUSCLE_STIMULUS_DEFICIT'));
      expect(
        output.trace.firedRuleCodes.where((code) => code.startsWith('RECENCY_')),
        isEmpty,
      );
    }
    expect(
      outputs.first.trace.candidates.map((candidate) => candidate.score),
      outputs.last.trace.candidates.map((candidate) => candidate.score),
    );
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

  test('YELLOW and RED keep active deload work prescribed at RIR 4+', () {
    for (final subjective in [3, 1]) {
      final states = baseStates();
      states['squat'] = ExerciseState(
        trackKey: 'squat',
        pattern: MovementPattern.squat,
        currentLoad: 24,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 2,
        preDeloadLoad: 24,
      );
      final output = decisionEngine.decide(buildInput(
        time: 35,
        subjective: subjective,
        sessionLogs: floorSatisfiedLogs(),
        queueState: const QueueState(pointer: SessionTypeId.s1),
        exerciseStates: states,
      ));
      final squat = output.trace.plan!.exercises.firstWhere(
        (exercise) =>
            !exercise.isWarmup && exercise.trackKey == 'squat',
      );

      expect(
        output.trace.recovery.bucket,
        subjective == 1 ? ReadinessBucket.red : ReadinessBucket.yellow,
      );
      expect(squat.progressionEligible, isFalse);
      expect(squat.rirTarget, Rir.rir4plus);
      expect(
        output.trace.firedRuleCodes,
        contains('DELOAD_ACTIVE_SQUAT'),
      );
    }
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
    expect(output.trace.plan!.tier, SessionTier.full);
    expect(output.trace.plan!.estimatedDurationMin, 9);
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
    expect(output.trace.plan!.tier, SessionTier.full);
    expect(output.trace.plan!.estimatedDurationMin, 9);
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

  test('leg-heavy demotion explains a natural non-pointer redirect', () {
    SessionLog bicepsHistory(String id, DateTime at, int setCount) =>
        SessionLog(
          id: id,
          templateId: SessionTypeId.s5,
          tier: SessionTier.full,
          date: at,
          completedAt: at,
          setLogs: [
            for (var index = 0; index < setCount; index++)
              SetLog(
                trackKey: 'sub:coreGrip:db_curl',
                pattern: MovementPattern.coreGrip,
                exerciseName: 'DB curl',
                weight: 8,
                value: 10,
                rir: Rir.rir2,
                timestamp: at,
              ),
          ],
          plannedWorkSets: setCount,
          completedWorkSets: setCount,
          durationMinutes: 20,
          countsAs: const {FloorCategory.strength},
        );
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
      queueState: const QueueState(pointer: SessionTypeId.s1),
      sessionLogs: [
        ...floorSatisfiedLogs(),
        // Biceps sits at 10 sets in 7d and the 40-set 28d center. That makes
        // S1 beat S2 by only its one-point queue edge before the -30
        // back-to-back leg penalty, and S2 win after the penalty.
        bicepsHistory(
          'biceps-recent',
          today.subtract(const Duration(days: 2)),
          10,
        ),
        bicepsHistory(
          'biceps-older',
          today.subtract(const Duration(days: 14)),
          30,
        ),
        buildLog(
          SessionTypeId.s1,
          today.subtract(const Duration(days: 1)),
          {FloorCategory.strength},
        ),
      ],
      forceQueuePointer: false,
    ));

    expect(output.trace.plan!.sessionId, SessionTypeId.s2);
    expect(output.trace.firedRuleCodes, contains('LEGHEAVY_DEMOTED'));
    expect(output.trace.firedRuleCodes, isNot(contains('QUEUE_NEXT')));
  });

  test('empty legacy rule list never fabricates queue provenance', () async {
    final source = decisionEngine.decide(buildInput(
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
      forceQueuePointer: false,
    )).trace;
    final legacy = DecisionTrace(
      date: source.date,
      checkin: source.checkin,
      recovery: source.recovery,
      candidates: source.candidates,
      firedRules: const [],
      plan: source.plan,
      queue: source.queue,
      restReason: source.restReason,
    );

    final explanation = await const AiExplainer().dailyExplanation(
      legacy,
      const UserSettings(),
    );
    expect(
      explanation,
      'No decision rationale was recorded for this saved plan.',
    );
    expect(explanation, isNot(contains('queue')));
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
