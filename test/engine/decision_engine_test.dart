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
}
