import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/engine/session_templates.dart';
import 'package:morningcoach/engine/strength_duration_engine.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  const estimator = StrengthDurationEstimator();
  const budgeter = StrengthDurationBudgeter();

  PlannedExercise prep(int minutes) => PlannedExercise(
        trackKey: 'prep',
        pattern: MovementPattern.kneeHealth,
        name: 'Movement prep',
        sets: 1,
        metric: ExerciseMetric.minutes,
        targetRange: (minutes, minutes),
        rirTarget: Rir.rir4plus,
        isWarmup: true,
      );

  PlannedExercise work(
    String key, {
    int sets = 3,
    bool compound = true,
    int? group,
    ExerciseMetric metric = ExerciseMetric.reps,
    (int, int) targetRange = const (6, 10),
  }) =>
      PlannedExercise(
        trackKey: key,
        pattern:
            compound ? MovementPattern.squat : MovementPattern.coreGrip,
        name: key,
        sets: sets,
        metric: metric,
        targetRange: targetRange,
        rirTarget: Rir.rir2,
        supersetGroup: group,
        isCompoundWork: compound,
      );

  PlannedExercise loadWarmup(
    String key, {
    bool feeder = false,
  }) =>
      PlannedExercise(
        trackKey: key,
        pattern: MovementPattern.squat,
        name: '$key warm-up',
        sets: 1,
        targetRange: const (5, 5),
        rirTarget: Rir.rir3plus,
        isWarmup: true,
        isFeederWarmup: feeder,
      );

  group('pure duration estimator and budgeter', () {
    test('documents and applies the deterministic logger cadence', () {
      final plan = [
        prep(3),
        loadWarmup('a'),
        loadWarmup('a'),
        work('a', sets: 3, group: 0),
        loadWarmup('b', feeder: true),
        work('b', sets: 3, group: 0),
      ];

      // 180 s prep + 3*(30+45) warm-up + 6*45 work + 2*90 rests
      // + 2*30 exercise setups = 915 s, conservatively rounded to 16 min.
      expect(estimator.estimateSeconds(plan), 915);
      expect(estimator.estimateMinutes(plan), 16);
    });

    test('uses the upper prescription bound for every timed work set', () {
      final hanging = work(
        'hanging',
        sets: 3,
        compound: false,
        metric: ExerciseMetric.seconds,
        targetRange: const (20, 60),
      );
      final timedMinutes = work(
        'timed-minutes',
        sets: 1,
        compound: false,
        metric: ExerciseMetric.minutes,
        targetRange: const (1, 2),
      );

      // Hanging: 3*60 s work + 2*60 s accessory rest + 30 s setup = 330 s.
      expect(estimator.estimateSeconds([hanging]), 330);
      expect(estimator.estimateMinutes([hanging]), 6);
      // Minute-based work follows the same upper-bound rule.
      expect(estimator.estimateSeconds([timedMinutes]), 150);
    });

    test('matches logger rest cadence and omits final-unit rest', () {
      expect(
        estimator.estimateSeconds([work('compound', sets: 2)]),
        210, // 2*45 work + 1*90 rest + 30 setup
      );
      expect(
        estimator.estimateSeconds([
          work('accessory', sets: 2, compound: false),
        ]),
        180, // 2*45 work + 1*60 rest + 30 setup
      );
      expect(
        estimator.estimateSeconds([
          work('a', sets: 2, group: 0),
          work('b', sets: 2, group: 0),
        ]),
        330, // 4*45 work + 1*90 inter-round rest + 2*30 setups
      );
    });

    test('budgets a 60-second hold using its conservative duration', () {
      final result = budgeter.fit(
        exercises: [
          work(
            'hanging',
            sets: 3,
            compound: false,
            metric: ExerciseMetric.seconds,
            targetRange: const (20, 60),
          ),
        ],
        slotMinutes: 6,
      );

      expect(result.fits, isTrue);
      expect(result.estimatedDurationMin, 6);
      expect(result.exercises.single.sets, 3);
      expect(estimator.estimateMinutes(result.exercises), 6);
    });

    test('trims accessories first, then work sets round-robin', () {
      final plan = [
        prep(5),
        loadWarmup('a'),
        loadWarmup('a'),
        loadWarmup('a'),
        work('a', sets: 5, group: 0),
        loadWarmup('b', feeder: true),
        work('b', sets: 5, group: 0),
        work('accessory', sets: 4, compound: false),
      ];

      final result = budgeter.fit(exercises: plan, slotMinutes: 20);
      expect(result.fits, isTrue);
      expect(result.estimatedDurationMin, lessThanOrEqualTo(20));
      expect(
        result.exercises.where((exercise) => exercise.trackKey == 'accessory'),
        isEmpty,
      );
      final compounds =
          result.exercises.where((exercise) => exercise.isCompoundWork);
      expect(compounds.map((exercise) => exercise.sets), [3, 3]);
    });

    test('removes later feeder only after minimum compound sets are reached', () {
      final plan = [
        prep(10),
        loadWarmup('a'),
        loadWarmup('a'),
        loadWarmup('a'),
        work('a', sets: 2, group: 0),
        loadWarmup('b', feeder: true),
        work('b', sets: 2, group: 0),
      ];

      final result = budgeter.fit(exercises: plan, slotMinutes: 20);
      expect(result.fits, isTrue);
      expect(result.exercises.where((exercise) => exercise.isFeederWarmup),
          isEmpty);
      expect(
        result.exercises.where((exercise) => exercise.isCompoundWork).map(
              (exercise) => exercise.sets,
            ),
        [2, 2],
      );
      expect(
        result.exercises.where(
          (exercise) => exercise.isWarmup && !exercise.isFeederWarmup,
        ),
        hasLength(4), // movement prep plus the protected three-set load ramp
      );
    });

    test('never deletes the final meaningful exercise when a slot is impossible',
        () {
      final result = budgeter.fit(
        exercises: [prep(20), work('only', sets: 6, compound: false)],
        slotMinutes: 1,
      );

      expect(result.fits, isFalse);
      final remainingWork =
          result.exercises.where((exercise) => !exercise.isWarmup).toList();
      expect(remainingWork, hasLength(1));
      expect(remainingWork.single.sets, 1);
    });
  });

  group('hard-window plan integration', () {
    const engine = DecisionEngine();
    final today = DateTime(2026, 1, 20);

    List<RecoverySnapshot> normalHistory() => List.generate(
          20,
          (index) => RecoverySnapshot(
            date: today.subtract(Duration(days: index + 1)),
            hrvRmssd: 50,
            restingHr: 60,
            sleepScore: 90,
          ),
        );

    SessionLog completed(
      SessionTypeId id,
      int daysAgo,
      Set<FloorCategory> categories,
    ) =>
        SessionLog(
          id: '${id.name}-$daysAgo',
          templateId: id,
          tier: SessionTier.full,
          date: today.subtract(Duration(days: daysAgo)),
          setLogs: const [],
          plannedWorkSets: 6,
          completedWorkSets: 6,
          durationMinutes: 30,
          countsAs: categories,
        );

    List<SessionLog> floorSatisfied() => [
          completed(SessionTypeId.s1, 2, {FloorCategory.strength}),
          completed(SessionTypeId.s4, 4, {FloorCategory.strength}),
          completed(SessionTypeId.s3, 3, {FloorCategory.intensity}),
        ];

    Map<String, ExerciseState> loadedStates() => {
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
          'pushHorizontal': ExerciseState(
            trackKey: 'pushHorizontal',
            pattern: MovementPattern.pushHorizontal,
            ladderStepIndex: 1,
            currentLoad: 40,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
          'pullHorizontal': ExerciseState(
            trackKey: 'pullHorizontal',
            pattern: MovementPattern.pullHorizontal,
            currentLoad: 40,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
          'pushVertical': ExerciseState(
            trackKey: 'pushVertical',
            pattern: MovementPattern.pushVertical,
            currentLoad: 30,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
          'pullVertical': ExerciseState(
            trackKey: 'pullVertical',
            pattern: MovementPattern.pullVertical,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
          'coreGrip': ExerciseState(
            trackKey: 'coreGrip',
            pattern: MovementPattern.coreGrip,
            ladderStepIndex: 4,
            currentLoad: 20,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
          dbCurl.trackKey: ExerciseState(
            trackKey: dbCurl.trackKey,
            pattern: dbCurl.pattern,
            currentLoad: 20,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
          lateralRaise.trackKey: ExerciseState(
            trackKey: lateralRaise.trackKey,
            pattern: lateralRaise.pattern,
            currentLoad: 20,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
          dip.trackKey: ExerciseState(
            trackKey: dip.trackKey,
            pattern: dip.pattern,
            currentLoad: 20,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
        };

    DecisionEngineOutput decide({
      required int time,
      required SessionTypeId forced,
      int subjective = 4,
      bool includeRecovery = true,
      List<PainFlag> pain = const [],
      UserSettings settings = const UserSettings(),
      Map<String, ExerciseState>? exerciseStates,
    }) =>
        engine.decide(DecisionEngineInput(
          checkin: CheckIn(
            date: today,
            timeMinutes: time,
            subjective: subjective,
            pain: pain,
            timestamp: today,
          ),
          todaySnapshot: includeRecovery
              ? RecoverySnapshot(
                  date: today,
                  hrvRmssd: 50,
                  restingHr: 60,
                  sleepScore: 90,
                )
              : null,
          recoveryHistory: includeRecovery ? normalHistory() : const [],
          checkinHistory: const [],
          sessionLogs: floorSatisfied(),
          exerciseStates: exerciseStates ?? loadedStates(),
          queueState: const QueueState(),
          settings: settings,
          today: today,
          forcedSessionId: forced,
        ));

    test('preparation allocations are exact in every hard window', () {
      expect(StrengthPrepPolicy.generalMinutes(20), 3);
      expect(StrengthPrepPolicy.generalMinutes(35), 5);
      expect(StrengthPrepPolicy.generalMinutes(60), 6);
      expect(StrengthPrepPolicy.atgMinutes(20), 3);
      expect(StrengthPrepPolicy.atgMinutes(35), 5);
      expect(StrengthPrepPolicy.atgMinutes(60), 5);

      for (final entry in {20: 3, 35: 5, 60: 6}.entries) {
        final plan = decide(time: entry.key, forced: SessionTypeId.s1)
            .trace
            .plan!;
        final general = plan.exercises.singleWhere(
          (exercise) => exercise.trackKey == 'warmup:s1',
        );
        expect(general.targetRange, (entry.value, entry.value));
        expect(general.instruction, contains('jumping jacks'));
      }
      for (final entry in {20: 3, 35: 5, 60: 5}.entries) {
        final plan = decide(
          time: entry.key,
          forced: SessionTypeId.s4,
        ).trace.plan!;
        final atg = plan.exercises.singleWhere(
          (exercise) => exercise.trackKey == 'atg_block',
        );
        expect(atg.targetRange, (entry.value, entry.value));
        expect(atg.name, 'ATG + upper-body prep');
        for (final cue in entry.value == 3
            ? [
                '0:00–0:30 · Jumping jacks',
                '0:30–1:00 · Backward treadmill',
                '1:00–1:30 · Tibialis raises (10–15)',
                '1:30–2:00 · Calf raises (10–15)',
                '2:00–2:30 · Shoulder circles (8 each direction)',
                '2:30–3:00 · Scapular push-ups (6–10)',
              ]
            : [
                '0:00–0:45 · Jumping jacks',
                '0:45–2:00 · Backward treadmill',
                '2:00–2:45 · Tibialis raises (15–20)',
                '2:45–3:30 · Calf raises (15–20)',
                '3:30–4:15 · Shoulder circles (10 each direction)',
                '4:15–5:00 · Scapular push-ups (8–12)',
              ]) {
          expect(atg.instruction, contains(cue));
        }
        expect(atg.instruction, contains('Replaces general movement prep.'));
        expect(atg.instruction, isNot(contains('shoulder/scapular rehearsal')));
        expect(
          plan.exercises.where(
            (exercise) => exercise.trackKey.startsWith('warmup:'),
          ),
          isEmpty,
        );
      }
    });

    test('the zero-minute hard window remains a rest outcome', () {
      final output = decide(time: 0, forced: SessionTypeId.s1);
      expect(output.trace.plan, isNull);
      expect(output.trace.restReason, 'Rest day');
    });

    test('every feasible strength template fits 20/35/60 and reports final estimate',
        () {
      const feasible = {
        20: [
          SessionTypeId.s1,
          SessionTypeId.s2,
          SessionTypeId.s4,
          SessionTypeId.s5,
        ],
        35: [
          SessionTypeId.s1,
          SessionTypeId.s2,
          SessionTypeId.s4,
          SessionTypeId.s5,
        ],
        60: [
          SessionTypeId.s1,
          SessionTypeId.s2,
          SessionTypeId.s4,
          SessionTypeId.s5,
        ],
      };

      for (final entry in feasible.entries) {
        for (final id in entry.value) {
          final plan = decide(time: entry.key, forced: id).trace.plan!;
          expect(plan.sessionId, id);
          expect(plan.plannedWorkSets, greaterThan(0));
          expect(
            plan.estimatedDurationMin,
            lessThanOrEqualTo(entry.key),
            reason: '${id.name} exceeded the ${entry.key}-minute window',
          );
          expect(
            plan.estimatedDurationMin,
            estimator.estimateMinutes(plan.exercises),
          );
        }
      }
    });

    test('S2 extended strength plus its optional REHIT stays within 60 minutes',
        () {
      final states = loadedStates();
      states['coreGrip'] = ExerciseState(
        trackKey: 'coreGrip',
        pattern: MovementPattern.coreGrip,
        ladderStepIndex: 2,
        lastTrainedDate: today.subtract(const Duration(days: 2)),
      );
      final plan = decide(
        time: 60,
        forced: SessionTypeId.s2,
        exerciseStates: states,
      ).trace.plan!;
      const optionalRehitMinutes = 9;

      expect(plan.sessionId, SessionTypeId.s2);
      expect(plan.tier, SessionTier.extended);
      expect(
        plan.exercises.singleWhere((exercise) => exercise.name == 'Hanging'),
        isA<PlannedExercise>()
            .having(
              (exercise) => exercise.metric,
              'metric',
              ExerciseMetric.seconds,
            )
            .having(
              (exercise) => exercise.targetRange,
              'range',
              const (20, 60),
            ),
      );
      expect(
        sessionTemplates[plan.sessionId]!.hasOptionalRehitFinisher,
        isTrue,
      );
      expect(
        plan.estimatedDurationMin,
        estimator.estimateMinutes(plan.exercises),
      );
      expect(
        plan.estimatedDurationMin + optionalRehitMinutes,
        lessThanOrEqualTo(60),
      );
      expect(plan.estimatedDurationMin, lessThanOrEqualTo(51));
    });

    test('20-minute ramp is 50%x5 and 75%x3; longer ramps stay 40/60/80',
        () {
      final short =
          decide(time: 20, forced: SessionTypeId.s1).trace.plan!;
      final shortRamp = short.exercises
          .where((exercise) =>
              exercise.isWarmup && exercise.trackKey == 'squat')
          .toList();
      expect(shortRamp, hasLength(2));
      expect(shortRamp.map((exercise) => exercise.name),
          everyElement(anyOf(contains('50%'), contains('75%'))));
      expect(shortRamp.map((exercise) => exercise.targetRange),
          [(5, 5), (3, 3)]);

      for (final time in [35, 60]) {
        final plan = decide(time: time, forced: SessionTypeId.s1)
            .trace
            .plan!;
        final ramp = plan.exercises
            .where((exercise) =>
                exercise.isWarmup && exercise.trackKey == 'squat')
            .toList();
        expect(
          ramp.map((exercise) => exercise.targetRange),
          [(8, 8), (5, 5), (3, 3)],
        );
        final feeder = plan.exercises.singleWhere(
          (exercise) =>
              exercise.isWarmup && exercise.trackKey == 'hinge',
        );
        expect(feeder.targetRange, (5, 5));
        expect(feeder.isFeederWarmup, isTrue);
      }
    });

    test('named and true accessory work never receives an artificial ramp',
        () {
      final s5 = decide(time: 20, forced: SessionTypeId.s5).trace.plan!;
      final namedKeys = {dbCurl.trackKey, lateralRaise.trackKey};
      expect(
        s5.exercises.where((exercise) =>
            exercise.isWarmup && namedKeys.contains(exercise.trackKey)),
        isEmpty,
      );
      final namedWork = s5.exercises
          .where((exercise) =>
              !exercise.isWarmup && namedKeys.contains(exercise.trackKey))
          .toList();
      expect(namedWork, hasLength(2));
      expect(
        namedWork,
        everyElement(
          isA<PlannedExercise>()
              .having((exercise) => exercise.isCompoundWork, 'compound', false)
              .having((exercise) => exercise.supersetGroup, 'group', isNull),
        ),
      );

      final s2 = decide(time: 60, forced: SessionTypeId.s2).trace.plan!;
      expect(
        s2.exercises.where((exercise) =>
            exercise.isWarmup && exercise.trackKey == 'coreGrip'),
        isEmpty,
      );
    });

    test('travel, YELLOW, RED, and pain-adjusted strength plans stay in budget',
        () {
      final travel = decide(
          time: 20,
          forced: SessionTypeId.s1,
          settings: const UserSettings(travelMode: true),
        );
      final yellow = decide(
          time: 35,
          forced: SessionTypeId.s2,
          subjective: 3,
          includeRecovery: false,
        );
      final red = decide(
          time: 35,
          forced: SessionTypeId.s1,
          subjective: 1,
          includeRecovery: false,
        );
      final painAdjusted = decide(
          time: 35,
          forced: SessionTypeId.s1,
          pain: [
            PainFlag(
              region: BodyRegion.lowerBack,
              severity: PainSeverity.sharp,
              flaggedDate: today,
            ),
          ],
        );
      final cases = [travel, yellow, red, painAdjusted];
      final windows = [20, 35, 35, 35];

      for (var index = 0; index < cases.length; index++) {
        final plan = cases[index].trace.plan!;
        expect(plan.estimatedDurationMin, lessThanOrEqualTo(windows[index]));
        expect(plan.estimatedDurationMin,
            estimator.estimateMinutes(plan.exercises));
      }
      expect(travel.trace.plan!.travelMode, isTrue);
      expect(
        travel.trace.plan!.exercises
            .where((exercise) => !exercise.isWarmup)
            .every((exercise) =>
                exercise.isTravel && !exercise.progressionEligible),
        isTrue,
      );
      expect(
        yellow.trace.plan!.exercises
            .where((exercise) => !exercise.isWarmup)
            .every((exercise) => !exercise.progressionEligible),
        isTrue,
      );
      expect(red.trace.plan!.grantsQueueCredit, isFalse);
      expect(
        painAdjusted.trace.plan!.exercises.any(
          (exercise) => exercise.substitutedFrom == 'hinge',
        ),
        isTrue,
      );
    });

    test('self-contained cardio is never inflated or given app warm-ups', () {
      final cases = [
        (decide(time: 35, forced: SessionTypeId.s3), 30),
        (decide(time: 60, forced: SessionTypeId.s3), 30),
        (decide(time: 35, forced: SessionTypeId.s6), 35),
        (decide(time: 60, forced: SessionTypeId.s6), 60),
        (decide(time: 20, forced: SessionTypeId.s7), 9),
        (decide(time: 60, forced: SessionTypeId.s7), 9),
      ];

      for (final (output, expectedMinutes) in cases) {
        final plan = output.trace.plan!;
        expect(plan.exercises, isEmpty);
        expect(plan.estimatedDurationMin, expectedMinutes);
        if (plan.sessionId == SessionTypeId.s3 ||
            plan.sessionId == SessionTypeId.s7) {
          expect(plan.tier, SessionTier.full);
        }
      }
    });
  });

  group('unilateral work costs two bouts per set', () {
    PlannedExercise lift({required bool unilateral}) => PlannedExercise(
          trackKey: 'pushHorizontal',
          pattern: MovementPattern.pushHorizontal,
          name: unilateral ? 'One-arm DB bench' : 'DB bench on bolster',
          sets: 3,
          targetRange: const (6, 10),
          loadTotal: 40,
          rirTarget: Rir.rir2,
          isCompoundWork: true,
          unilateral: unilateral,
        );

    test('a per-side set is charged twice the bilateral set time', () {
      const estimator = StrengthDurationEstimator();
      final bilateral = estimator.estimateSeconds([lift(unilateral: false)]);
      final perSide = estimator.estimateSeconds([lift(unilateral: true)]);
      // Only the working time doubles; rest and setup are unchanged.
      expect(
        perSide - bilateral,
        3 * StrengthDurationEstimator.workSetSeconds,
        reason: 'a unilateral prescription is written per side, so each '
            'logged set is physically two working bouts',
      );
    });

    test('the ladder marks single-DB one-arm compounds as per-side', () {
      for (final (pattern, stepName) in const [
        (MovementPattern.pushHorizontal, 'One-arm DB bench'),
        (MovementPattern.pushVertical, 'Single-arm standing press'),
        (MovementPattern.pullHorizontal, 'Single-arm row +pause'),
      ]) {
        final step = ladders[pattern]!
            .steps
            .firstWhere((candidate) => candidate.name == stepName);
        expect(step.unilateral, isTrue, reason: stepName);
      }
    });
  });
}
