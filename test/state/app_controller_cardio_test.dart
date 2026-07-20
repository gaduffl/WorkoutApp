import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/cardio_engine.dart';
import 'package:morningcoach/engine/intensity_recovery_policy.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/engine/rehit_eligibility_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/rule_key.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/user_settings.dart';
import 'package:morningcoach/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const cardio = CardioEngine();
  const recoveryPolicy = IntensityRecoveryPolicy();

  SessionPlan cardioPlan(SessionTypeId id, int minutes) => SessionPlan(
        sessionId: id,
        sessionName: id.name,
        tier: SessionTier.full,
        exercises: const [],
        estimatedDurationMin: minutes,
        cardioPrescription: cardio.prescriptionFor(
          sessionId: id,
          durationMinutes: minutes,
          heartRateMaxBpm: 180,
        ),
        grantsQueueCredit: id == SessionTypeId.s3,
      );

  SessionPlan strengthPlan({
    SessionTypeId id = SessionTypeId.s1,
    int sets = 4,
    SessionTier tier = SessionTier.full,
    bool? reserveRehitFinisher,
  }) =>
      SessionPlan(
        sessionId: id,
        sessionName: 'Strength test',
        tier: tier,
        exercises: [
          PlannedExercise(
            trackKey: 'squat',
            pattern: MovementPattern.squat,
            name: 'Squat',
            sets: sets,
            targetRange: (6, 10),
            rirTarget: Rir.rir2,
          ),
        ],
        estimatedDurationMin: 35,
        optionalRehitFinisherReserved: reserveRehitFinisher ??
            (id == SessionTypeId.s2 && tier == SessionTier.extended),
      );

  List<SetLog> workSets(
    int count, {
    bool painFlag = false,
    int value = 8,
  }) =>
      List.generate(
        count,
        (index) => SetLog(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          exerciseName: 'Squat',
          weight: 20,
          value: value,
          rir: Rir.rir2,
          painFlag: painFlag && index == count - 1,
          timestamp: DateTime.now(),
        ),
      );

  DecisionTrace traceFor(
    DateTime now,
    SessionPlan plan, {
    ReadinessBucket bucket = ReadinessBucket.green,
    List<PainFlag> pain = const [],
    List<FiredRule> firedRules = const [],
  }) =>
      DecisionTrace(
        date: DateTime(now.year, now.month, now.day),
        checkin: CheckIn(
          date: DateTime(now.year, now.month, now.day),
          timeMinutes: 35,
          subjective: 4,
          pain: pain,
          timestamp: now,
        ),
        recovery: RecoveryTrace(
          hrvZToday: 0,
          hrvTrend3: 0,
          sleepScore: 90,
          rhrDev: 0,
          bucket: bucket,
          compositeScore: bucket == ReadinessBucket.green ? 80 : 40,
        ),
        candidates: const [],
        firedRules: firedRules,
        plan: plan,
        queue: const QueueTraceInfo(
          pointerBefore: SessionTypeId.s1,
          servedBefore: {},
        ),
      );

  Future<AppController> controllerAfterStrength({
    int plannedSets = 4,
    int completedSets = 4,
    bool painFlag = false,
    bool endedEarly = false,
    SessionTypeId id = SessionTypeId.s1,
    CardioCompletion? rehitFinisherCompletion,
  }) async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final now = DateTime.now();
    final plan = strengthPlan(
      id: id,
      sets: plannedSets,
      tier: rehitFinisherCompletion == null
          ? SessionTier.full
          : SessionTier.extended,
    );
    controller.todayTrace = traceFor(now, plan);
    await controller.completeSession(
      plan,
      workSets(completedSets, painFlag: painFlag),
      durationMinutes: 35,
      rehitFinisherCompletion: rehitFinisherCompletion,
      endedEarly: endedEarly,
    );
    return controller;
  }

  test('manual swap records override but travel refresh preservation does not',
      () async {
    final now = DateTime.now();
    final manualController = AppController(Repository(_MemoryDatabase()))
      ..todayTrace = traceFor(now, strengthPlan());

    final swapped = await manualController.swapToSession(SessionTypeId.s5);
    expect(swapped.plan!.sessionId, SessionTypeId.s5);
    expect(swapped.firedRuleCodes, contains('MANUAL_SESSION_OVERRIDE'));

    final refreshController = AppController(Repository(_MemoryDatabase()))
      ..todayTrace = traceFor(now, strengthPlan());
    final refreshed = await refreshController.setTravelMode(true);

    expect(refreshed!.plan!.sessionId, SessionTypeId.s1);
    expect(
      refreshed.firedRuleCodes,
      isNot(contains('MANUAL_SESSION_OVERRIDE')),
    );
  });

  test('resetToday restores rest/cardio pain persistence and deletes new tracks',
      () async {
    for (final minutes in [0, 35]) {
      final db = _MemoryDatabase();
      final repo = Repository(db);
      final originalHinge = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 90,
      );
      final controller = AppController(repo)
        ..exerciseStates = {'hinge': originalHinge};
      await repo.saveExerciseStates(controller.exerciseStates);
      final date = controller.today();

      var trace = await controller.submitCheckIn(
        timeMinutes: minutes,
        subjective: 4,
        pain: [
          PainFlag(
            region: BodyRegion.kneeLeft,
            severity: PainSeverity.sharp,
            flaggedDate: date,
          ),
        ],
      );
      if (minutes == 35) {
        trace = await controller.swapToSession(SessionTypeId.s3);
        expect(trace.plan!.sessionId, SessionTypeId.s6);
      } else {
        expect(trace.plan, isNull);
      }
      expect(controller.exerciseStates['squat']!.painFrozen, isTrue);

      await controller.resetToday();

      expect(controller.exerciseStates.keys.toSet(), {'hinge'});
      expect(controller.exerciseStates['hinge'], same(originalHinge));
      final persisted = await repo.loadExerciseStates();
      expect(persisted.keys.toSet(), {'hinge'});
      expect(persisted['hinge']!.currentLoad, 90);
      expect(persisted['hinge']!.painFrozen, isFalse);
    }
  });

  test('partial cardio persists without category/queue credit; full dose earns both', () async {
    final db = _MemoryDatabase();
    final repo = Repository(db);
    final controller = AppController(repo)
      ..queueState = const QueueState(pointer: SessionTypeId.s3);
    final plan = cardioPlan(SessionTypeId.s3, 35);
    controller.todayTrace = traceFor(DateTime.now(), plan);
    final partial = cardio.completionFromEntry(
      prescription: plan.cardioPrescription!,
      completedWorkIntervals: 3,
      completedDurationMinutes: 35,
    );

    await controller.logCardioSession(
      SessionTypeId.s3,
      completion: partial,
      plan: plan,
    );
    var logs = await repo.loadSessionLogsSince(
      DateTime.now().subtract(const Duration(days: 1)),
    );
    expect(logs, hasLength(1));
    expect(logs.single.cardioCompletion!.completedWorkIntervals, 3);
    expect(logs.single.countsAs, isEmpty);
    expect(logs.single.countsTowardQueueAndFloor, isFalse);
    expect(controller.queueState.pointer, SessionTypeId.s3);
    expect(controller.queueState.served, isEmpty);

    final beforeFull = DateTime.now();
    // Use a fresh isolated store for the full-dose persistence branch; the
    // first store is now locked after its partial primary attempt.
    final fullRepo = Repository(_MemoryDatabase());
    final fullController = AppController(fullRepo)
      ..queueState = controller.queueState;
    fullController.todayTrace = traceFor(DateTime.now(), plan);
    final full = cardio.completionFromEntry(
      prescription: plan.cardioPrescription!,
      completedWorkIntervals: 4,
      completedDurationMinutes: 35,
      averageHeartRateBpm: 156,
      peakHeartRateBpm: 174,
      rpe: 8.5,
    );
    await fullController.logCardioSession(
      SessionTypeId.s3,
      completion: full,
      plan: plan,
    );
    logs = await fullRepo.loadSessionLogsSince(
      DateTime.now().subtract(const Duration(days: 1)),
    );
    expect(logs, hasLength(1));
    final fullLog = logs.single;
    expect(fullLog.countsAs, {FloorCategory.intensity});
    expect(fullLog.countsTowardQueueAndFloor, isTrue);
    expect(fullLog.completedAt.isBefore(beforeFull), isFalse);
    expect(fullLog.completedAtPrecision, CompletionTimePrecision.exact);
    expect(fullController.queueState.pointer, SessionTypeId.s4);
    expect(fullController.queueState.served, contains(SessionTypeId.s3));
    await fullController.syncNotifications();
  });

  test(
      'a partial strength attempt locks completion, reset, re-check-in, swap, and a restored controller',
      () async {
    final db = _MemoryDatabase();
    final repo = Repository(db);
    final controller = AppController(repo);
    final plan = strengthPlan(sets: 4);
    final originalTrace = traceFor(DateTime.now(), plan);
    controller.todayTrace = originalTrace;
    await repo.saveCheckIn(originalTrace.checkin);
    await repo.saveDecisionTrace(originalTrace);

    await controller.completeSession(
      plan,
      workSets(1),
      durationMinutes: 10,
      endedEarly: true,
    );

    expect(controller.sessionLoggedToday, isTrue);
    expect(controller.sessionDoneToday, isFalse);
    await expectLater(
      controller.completeSession(
        plan,
        workSets(4),
        durationMinutes: 35,
      ),
      throwsStateError,
    );
    await expectLater(controller.resetToday(), throwsStateError);
    await expectLater(
      controller.submitCheckIn(timeMinutes: 35, subjective: 5),
      throwsStateError,
    );
    await expectLater(
      controller.swapToSession(SessionTypeId.s2),
      throwsStateError,
    );

    // The repository check is intentional: a newly constructed controller
    // must not rely on an empty in-memory recent-log cache.
    final restoredController = AppController(repo)
      ..todayTrace = originalTrace;
    await expectLater(
      restoredController.completeSession(
        plan,
        workSets(4),
        durationMinutes: 35,
      ),
      throwsStateError,
    );

    expect(await repo.loadSessionLogsSince(DateTime(2000)), hasLength(1));
    expect(await repo.loadCheckInsSince(controller.today()), hasLength(1));
    expect(
      await repo.loadDecisionTraceForDate(controller.today()),
      isNotNull,
    );
  });

  test('a partial primary cardio attempt cannot be logged or completed again',
      () async {
    final repo = Repository(_MemoryDatabase());
    final controller = AppController(repo);
    final plan = cardioPlan(SessionTypeId.s6, 35);
    controller.todayTrace = traceFor(DateTime.now(), plan);
    final partial = cardio.completionFromEntry(
      prescription: plan.cardioPrescription!,
      completedWorkIntervals: 1,
      completedDurationMinutes: 20,
    );

    await controller.logCardioSession(
      SessionTypeId.s6,
      completion: partial,
      plan: plan,
    );

    await expectLater(
      controller.logCardioSession(
        SessionTypeId.s6,
        completion: partial,
        plan: plan,
      ),
      throwsStateError,
    );
    await expectLater(
      controller.completeSession(
        plan,
        const [],
        durationMinutes: 20,
        cardioCompletion: partial,
      ),
      throwsStateError,
    );
    expect(await repo.loadSessionLogsSince(DateTime(2000)), hasLength(1));
  });

  test('the explicitly eligible later-day REHIT bypasses only the primary lock',
      () async {
    final controller = await controllerAfterStrength(
      plannedSets: 4,
      completedSets: 2,
    );
    expect(controller.secondRehitEligibility.eligible, isTrue);
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 10,
      heartRateMaxBpm: controller.settings.hrMax,
    );
    final completion = cardio.completionFromEntry(
      prescription: prescription,
      completedWorkIntervals: 2,
      completedDurationMinutes: 10,
    );

    await controller.logCardioSession(
      SessionTypeId.s7,
      completion: completion,
    );

    final logs = await controller.repo.loadSessionLogsSince(DateTime(2000));
    expect(logs, hasLength(2));
    final rehitLog = logs.singleWhere(
      (log) => log.templateId == SessionTypeId.s7,
    );
    expect(rehitLog.countsAs, contains(FloorCategory.intensity));
    expect(rehitLog.isSupplemental, isTrue);
    expect(rehitLog.isUnplanned, isFalse);
    expect(rehitLog.completesTodaysPlan, isFalse);
  });

  test(
      'retrospective REHIT bypasses prospective gates and preserves partial/full dose semantics',
      () async {
    final repo = Repository(_MemoryDatabase());
    final controller = AppController(repo)
      ..settings = const UserSettings(travelMode: true)
      ..queueState = const QueueState(
        pointer: SessionTypeId.s3,
        served: {SessionTypeId.s1},
      );
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 9,
      heartRateMaxBpm: controller.settings.hrMax,
    );
    final partial = cardio.completionFromEntry(
      prescription: prescription,
      completedWorkIntervals: 1,
      completedDurationMinutes: 5,
    );
    final full = cardio.completionFromElapsedSeconds(
      prescription: prescription,
      completedWorkIntervals: 2,
      completedDurationSeconds: 520,
    );

    expect(controller.secondRehitEligibility.eligible, isFalse);
    await expectLater(
      controller.logCardioSession(
        SessionTypeId.s7,
        completion: partial,
      ),
      throwsStateError,
    );

    await controller.logUnplannedRehit(completion: partial);
    await controller.logUnplannedRehit(completion: full);

    final logs = await repo.loadSessionLogsSince(DateTime(2000));
    expect(logs, hasLength(2));
    final partialLog = logs.singleWhere(
      (log) => !log.cardioCompletion!.meetsCreditableDose,
    );
    final fullLog = logs.singleWhere(
      (log) => log.cardioCompletion!.meetsCreditableDose,
    );
    expect(partialLog.countsAs, isEmpty);
    expect(recoveryPolicy.isRecoveryRelevant(partialLog), isTrue);
    expect(fullLog.countsAs, {FloorCategory.intensity});
    expect(
      logs,
      everyElement(
        isA<SessionLog>()
            .having((log) => log.isSupplemental, 'supplemental', isTrue)
            .having((log) => log.isUnplanned, 'unplanned', isTrue)
            .having(
              (log) => log.completesTodaysPlan,
              'primary completion',
              isFalse,
            ),
      ),
    );
    expect(controller.sessionLoggedToday, isFalse);
    expect(controller.sessionDoneToday, isFalse);
    expect(controller.queueState.pointer, SessionTypeId.s3);
    expect(controller.queueState.served, {SessionTypeId.s1});
  });

  test('persisted supplemental-only work leaves every primary action unlocked',
      () async {
    final repo = Repository(_MemoryDatabase());
    final writer = AppController(repo);
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 9,
      heartRateMaxBpm: writer.settings.hrMax,
    );
    final partial = cardio.completionFromEntry(
      prescription: prescription,
      completedWorkIntervals: 1,
      completedDurationMinutes: 5,
    );
    await writer.logUnplannedRehit(completion: partial);

    // Start from an empty in-memory cache to exercise the persistence merge,
    // not merely the writer controller's newly appended log.
    final controller = AppController(repo);
    final submitted = await controller.submitCheckIn(
      timeMinutes: 35,
      subjective: 4,
    );
    expect(controller.sessionLoggedToday, isFalse);
    expect(controller.sessionDoneToday, isFalse);
    expect(
      controller.rehitEligibilityAt(DateTime.now()).closedReasons,
      contains(RehitClosedReason.intensityWithinTrailing48Hours),
    );

    final swapped = await controller.swapToSession(SessionTypeId.s1);
    expect(swapped.plan!.sessionId, SessionTypeId.s1);
    await controller.resetToday();
    expect(controller.todayTrace, isNull);

    final primaryPlan = strengthPlan();
    controller.todayTrace = traceFor(DateTime.now(), primaryPlan);
    await controller.completeSession(
      primaryPlan,
      workSets(4),
      durationMinutes: 35,
    );

    final logs = await repo.loadSessionLogsSince(DateTime(2000));
    expect(logs, hasLength(2));
    expect(logs.where((log) => log.isSupplemental), hasLength(1));
    expect(logs.where((log) => !log.isSupplemental), hasLength(1));
    expect(controller.sessionLoggedToday, isTrue);
    expect(controller.sessionDoneToday, isTrue);
    expect(submitted.date, controller.today());
  });

  test('retrospective REHIT bypasses an existing primary lock without queue credit',
      () async {
    final controller = await controllerAfterStrength();
    final pointerBefore = controller.queueState.pointer;
    final servedBefore = controller.queueState.served;
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 9,
      heartRateMaxBpm: controller.settings.hrMax,
    );
    final completion = cardio.completionFromElapsedSeconds(
      prescription: prescription,
      completedWorkIntervals: 2,
      completedDurationSeconds: 520,
    );

    await controller.logUnplannedRehit(completion: completion);

    final logs = await controller.repo.loadSessionLogsSince(DateTime(2000));
    expect(logs, hasLength(2));
    final unplanned = logs.singleWhere((log) => log.isUnplanned);
    expect(unplanned.isSupplemental, isTrue);
    expect(unplanned.countsAs, {FloorCategory.intensity});
    expect(controller.queueState.pointer, pointerBefore);
    expect(controller.queueState.served, servedBefore);
  });

  test('retrospective REHIT rejects a non-REHIT completion', () async {
    final repo = Repository(_MemoryDatabase());
    final controller = AppController(repo);
    final zone2Prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s6,
      durationMinutes: 20,
      heartRateMaxBpm: controller.settings.hrMax,
    );
    final zone2 = cardio.completionFromEntry(
      prescription: zone2Prescription,
      completedWorkIntervals: 1,
      completedDurationMinutes: 20,
    );

    await expectLater(
      controller.logUnplannedRehit(completion: zone2),
      throwsArgumentError,
    );
    expect(await repo.loadSessionLogsSince(DateTime(2000)), isEmpty);
  });

  test('high intensity requires an authoritative current GREEN trace', () {
    final controller = AppController(Repository(_MemoryDatabase()));
    final now = DateTime.now();
    final plan = cardioPlan(SessionTypeId.s3, 35);

    expect(
      controller.isHighIntensityUsableNow(nowLocal: now),
      isFalse,
    );

    final yesterday = now.subtract(const Duration(days: 1));
    controller.todayTrace = traceFor(yesterday, plan);
    expect(
      controller.isHighIntensityUsableNow(nowLocal: now),
      isFalse,
    );

    controller.todayTrace = traceFor(now, plan);
    expect(
      controller.isHighIntensityUsableNow(nowLocal: now),
      isTrue,
    );
  });

  test(
      '20-minute S6 completes its exact recovery plan without base or queue credit',
      () async {
    final db = _MemoryDatabase();
    final repo = Repository(db);
    final controller = AppController(repo)
      ..queueState = const QueueState(pointer: SessionTypeId.s1);
    final recoveryPlan = cardioPlan(SessionTypeId.s6, 20);
    final recoveryCompletion = cardio.completionFromEntry(
      prescription: recoveryPlan.cardioPrescription!,
      completedWorkIntervals: 1,
      completedDurationMinutes: 20,
    );

    await controller.logCardioSession(
      SessionTypeId.s6,
      completion: recoveryCompletion,
      plan: recoveryPlan,
    );

    final recoveryLog =
        (await repo.loadSessionLogsSince(DateTime(2000))).single;
    expect(recoveryLog.cardioCompletedAsPrescribed, isTrue);
    expect(recoveryLog.completesTodaysPlan, isTrue);
    expect(recoveryLog.cardioDoseQualifies, isFalse);
    expect(recoveryLog.countsAs, isEmpty);
    expect(recoveryLog.countsTowardQueueAndFloor, isFalse);
    expect(controller.sessionDoneToday, isTrue);
    expect(controller.sessionLoggedToday, isTrue);
    expect(controller.queueState.pointer, SessionTypeId.s1);
    expect(controller.queueState.served, isEmpty);

    for (final plannedMinutes in [35, 60]) {
      final partialRepo = Repository(_MemoryDatabase());
      final partialController = AppController(partialRepo);
      final longPlan = cardioPlan(SessionTypeId.s6, plannedMinutes);
      final twentyMinutePartial = cardio.completionFromEntry(
        prescription: longPlan.cardioPrescription!,
        completedWorkIntervals: 1,
        completedDurationMinutes: 20,
      );
      await partialController.logCardioSession(
        SessionTypeId.s6,
        completion: twentyMinutePartial,
        plan: longPlan,
      );

      final partialLog =
          (await partialRepo.loadSessionLogsSince(DateTime(2000))).single;
      expect(
        partialLog.cardioCompletedAsPrescribed,
        isFalse,
        reason: '$plannedMinutes-minute prescription',
      );
      expect(partialLog.completesTodaysPlan, isFalse);
      expect(partialLog.countsTowardQueueAndFloor, isFalse);
      expect(partialController.sessionDoneToday, isFalse);
      expect(partialController.sessionLoggedToday, isTrue);
    }
  });

  test('stale CAROL plans cannot be logged while travel mode is active',
      () async {
    final db = _MemoryDatabase();
    final repo = Repository(db);
    final controller = AppController(repo)
      ..settings = const UserSettings(travelMode: true);
    final plan = cardioPlan(SessionTypeId.s3, 35);
    controller.todayTrace = traceFor(DateTime.now(), plan);
    final completion = cardio.completionFromEntry(
      prescription: plan.cardioPrescription!,
      completedWorkIntervals: 4,
      completedDurationMinutes: 35,
    );

    expect(controller.isPlanUsableNow(plan), isFalse);
    await expectLater(
      controller.logCardioSession(
        SessionTypeId.s3,
        completion: completion,
        plan: plan,
      ),
      throwsStateError,
    );
    expect(await repo.loadSessionLogsSince(DateTime(2000)), isEmpty);
  });

  test('controller rejects a mismatched completion before persistence', () async {
    final db = _MemoryDatabase();
    final repo = Repository(db);
    final controller = AppController(repo);
    final plan = cardioPlan(SessionTypeId.s3, 35);
    controller.todayTrace = traceFor(DateTime.now(), plan);
    final rehitPrescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 10,
      heartRateMaxBpm: 180,
    );
    final rehit = cardio.completionFromEntry(
      prescription: rehitPrescription,
      completedWorkIntervals: 2,
      completedDurationMinutes: 10,
    );

    await expectLater(
      controller.logCardioSession(
        SessionTypeId.s3,
        completion: rehit,
        plan: plan,
      ),
      throwsArgumentError,
    );
    expect(
      await repo.loadSessionLogsSince(DateTime(2000)),
      isEmpty,
    );
  });

  test('controller keeps CAROL dose credit separate from preset adherence',
      () async {
    for (final id in [SessionTypeId.s3, SessionTypeId.s7]) {
      final db = _MemoryDatabase();
      final repo = Repository(db);
      final controller = AppController(repo);
      final plan = cardioPlan(id, id == SessionTypeId.s3 ? 30 : 9);
      controller.todayTrace = traceFor(DateTime.now(), plan);
      final completion = cardio.completionFromEntry(
        prescription: plan.cardioPrescription!,
        completedWorkIntervals:
            plan.cardioPrescription!.plannedWorkIntervals,
        completedDurationMinutes: id == SessionTypeId.s3 ? 25 : 1,
      );

      await controller.logCardioSession(
        id,
        completion: completion,
        plan: plan,
      );

      final log = (await repo.loadSessionLogsSince(DateTime(2000))).single;
      expect(log.cardioDoseQualifies, isTrue, reason: id.name);
      expect(log.cardioCompletedAsPrescribed, isFalse, reason: id.name);
      expect(log.completesTodaysPlan, isFalse, reason: id.name);
    }
  });

  test('controller canonicalizes restored legacy CAROL prescriptions',
      () async {
    final cases = <(SessionTypeId, CardioPrescription, int)>[
      (
        SessionTypeId.s3,
        const CardioPrescription(
          protocol: CardioProtocol.norwegian4x4,
          plannedWorkIntervals: 4,
          plannedWorkSeconds: 960,
          plannedRecoveryIntervals: 3,
          plannedRecoverySeconds: 540,
          plannedDurationSeconds: 35 * 60,
        ),
        30 * 60,
      ),
      (
        SessionTypeId.s7,
        const CardioPrescription(
          protocol: CardioProtocol.rehit,
          plannedWorkIntervals: 2,
          plannedWorkSeconds: 40,
          plannedRecoveryIntervals: 1,
          plannedRecoverySeconds: 180,
          plannedDurationSeconds: 10 * 60,
        ),
        8 * 60 + 40,
      ),
    ];

    for (final (id, legacyPrescription, observedSeconds) in cases) {
      final db = _MemoryDatabase();
      final repo = Repository(db);
      final controller = AppController(repo);
      final plan = SessionPlan(
        sessionId: id,
        sessionName: 'restored legacy CAROL plan',
        tier: SessionTier.full,
        exercises: const [],
        estimatedDurationMin: id == SessionTypeId.s3 ? 35 : 10,
        cardioPrescription: legacyPrescription,
      );
      controller.todayTrace = traceFor(DateTime.now(), plan);
      final canonical = cardio.prescriptionFor(
        sessionId: id,
        durationMinutes: sessionTypes[id]!.fullDurationMin,
        heartRateMaxBpm: controller.settings.hrMax,
      );
      final completion = cardio.completionFromElapsedSeconds(
        prescription: canonical,
        completedWorkIntervals: canonical.plannedWorkIntervals,
        completedDurationSeconds: observedSeconds,
      );

      await controller.logCardioSession(
        id,
        completion: completion,
        plan: plan,
      );

      final log = (await repo.loadSessionLogsSince(DateTime(2000))).single;
      expect(log.cardioCompletedAsPrescribed, isTrue, reason: id.name);
      expect(
        log.cardioCompletion!.completedDurationSeconds,
        observedSeconds,
        reason: id.name,
      );
      expect(
        log.durationMinutes,
        (observedSeconds + 59) ~/ 60,
        reason: id.name,
      );
      expect(log.cardioCompletion!.completedRecoverySeconds,
          canonical.plannedRecoverySeconds,
          reason: id.name);
    }
  });

  test('legacy cardio plan derives a prescription but still requires completion', () async {
    final db = _MemoryDatabase();
    final repo = Repository(db);
    final controller = AppController(repo);
    const legacyPlan = SessionPlan(
      sessionId: SessionTypeId.s6,
      sessionName: 'Zone 2',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 35,
    );
    final derived = cardio.prescriptionFor(
      sessionId: SessionTypeId.s6,
      durationMinutes: 35,
      heartRateMaxBpm: controller.settings.hrMax,
    );
    final completion = cardio.completionFromEntry(
      prescription: derived,
      completedWorkIntervals: 1,
      completedDurationMinutes: 35,
    );

    await expectLater(
      controller.completeSession(
        legacyPlan,
        const [],
        durationMinutes: 35,
      ),
      throwsArgumentError,
    );
    expect(await repo.loadSessionLogsSince(DateTime(2000)), isEmpty);

    await controller.logCardioSession(
      SessionTypeId.s6,
      completion: completion,
      plan: legacyPlan,
    );
    final log = (await repo.loadSessionLogsSince(DateTime(2000))).single;
    expect(log.cardioCompletion!.protocol.type, CardioProtocolType.zone2Base);
    expect(log.countsAs, {FloorCategory.aerobic});
    expect(log.countsTowardQueueAndFloor, isTrue);
    await controller.syncNotifications();
  });

  test('zero-value work is persisted for pain context but earns no completion or queue credit', () async {
    final db = _MemoryDatabase();
    final repo = Repository(db);
    final controller = AppController(repo)
      ..queueState = const QueueState(pointer: SessionTypeId.s1);
    final plan = strengthPlan(sets: 4);
    controller.todayTrace = traceFor(DateTime.now(), plan);

    await controller.completeSession(
      plan,
      workSets(4, value: 0, painFlag: true),
      durationMinutes: 5,
    );

    final log = (await repo.loadSessionLogsSince(DateTime(2000))).single;
    expect(log.setLogs, hasLength(4));
    expect(log.setLogs.any((setLog) => setLog.painFlag), isTrue);
    expect(log.completedWorkSets, 0);
    expect(log.completionRatio, 0);
    expect(log.countsTowardQueueAndFloor, isFalse);
    expect(controller.queueState.pointer, SessionTypeId.s1);
    expect(controller.queueState.served, isEmpty);

    final reasons = controller.rehitEligibilityAt(DateTime.now()).closedReasons;
    expect(
      reasons,
      contains(RehitClosedReason.firstSessionBelowMinimumCompletion),
    );
    expect(reasons, contains(RehitClosedReason.firstSessionPainEvent));
  });

  test(
      'progression requires every prescribed set for that track, independent of later tracks',
      () async {
    Future<AppController> completePushTrack(int completedPushSets) async {
      final controller = AppController(Repository(_MemoryDatabase()));
      const pushKey = 'push';
      controller.exerciseStates[pushKey] = ExerciseState(
        trackKey: pushKey,
        pattern: MovementPattern.pushHorizontal,
        currentLoad: 5,
      );
      const plan = SessionPlan(
        sessionId: SessionTypeId.s1,
        sessionName: 'Per-track completion',
        tier: SessionTier.full,
        estimatedDurationMin: 35,
        exercises: [
          PlannedExercise(
            trackKey: pushKey,
            pattern: MovementPattern.pushHorizontal,
            name: 'Push-up',
            sets: 3,
            targetRange: (6, 10),
            rirTarget: Rir.rir2,
          ),
          PlannedExercise(
            trackKey: 'row',
            pattern: MovementPattern.pullHorizontal,
            name: 'DB row',
            sets: 3,
            targetRange: (6, 10),
            rirTarget: Rir.rir2,
          ),
        ],
      );
      controller.todayTrace = traceFor(DateTime.now(), plan);
      final sets = List.generate(
        completedPushSets,
        (_) => SetLog(
          trackKey: pushKey,
          pattern: MovementPattern.pushHorizontal,
          exerciseName: 'Push-up',
          weight: 0,
          value: 10,
          rir: Rir.rir2,
          timestamp: DateTime.now(),
        ),
      );
      await controller.completeSession(
        plan,
        sets,
        durationMinutes: 20,
        endedEarly: true,
      );
      return controller;
    }

    final oneOfThree = await completePushTrack(1);
    final partialState = oneOfThree.exerciseStates['push']!;
    expect(partialState.microStepStage, 0);
    expect(partialState.ladderStepIndex, 0);
    expect(partialState.currentLoad, 5);
    expect(partialState.lastTrainedDate, oneOfThree.today());

    final threeOfThree = await completePushTrack(3);
    final completedState = threeOfThree.exerciseStates['push']!;
    expect(completedState.microStepStage, 1);
    expect(completedState.ladderStepIndex, 0);
    expect(completedState.currentLoad, 5);
    expect(completedState.lastTrainedDate, threeOfThree.today());
  });

  test('S2 finisher persists structured REHIT and intensity only at full dose', () async {
    Future<SessionLogSnapshot> logFinisher(int intervals) async {
      final db = _MemoryDatabase();
      final repo = Repository(db);
      final controller = AppController(repo);
      final plan = strengthPlan(
        id: SessionTypeId.s2,
        sets: 2,
        tier: SessionTier.extended,
      );
      controller.todayTrace = traceFor(DateTime.now(), plan);
      final prescription = cardio.prescriptionFor(
        sessionId: SessionTypeId.s7,
        durationMinutes: 10,
        heartRateMaxBpm: 180,
      );
      final completion = cardio.completionFromEntry(
        prescription: prescription,
        completedWorkIntervals: intervals,
        completedDurationMinutes: 10,
      );
      await controller.completeSession(
        plan,
        workSets(2),
        durationMinutes: 60,
        rehitFinisherCompletion: completion,
      );
      final log = (await repo.loadSessionLogsSince(DateTime(2000))).single;
      await controller.syncNotifications();
      return SessionLogSnapshot(
        cardioCompletion: log.cardioCompletion,
        countsAs: log.countsAs,
        legacyFlag: log.rehitFinisherCompleted,
      );
    }

    final partial = await logFinisher(1);
    expect(partial.cardioCompletion, isNotNull);
    expect(partial.countsAs, isNot(contains(FloorCategory.intensity)));
    expect(partial.legacyFlag, isFalse);

    final full = await logFinisher(2);
    expect(full.cardioCompletion!.protocol.type, CardioProtocolType.rehit);
    expect(full.countsAs, contains(FloorCategory.intensity));
    expect(full.legacyFlag, isTrue);
  });

  group('immediate S2 finisher safety', () {
    CardioCompletion completedFinisher() {
      final prescription = cardio.prescriptionFor(
        sessionId: SessionTypeId.s7,
        durationMinutes: 10,
        heartRateMaxBpm: 180,
      );
      return cardio.completionFromEntry(
        prescription: prescription,
        completedWorkIntervals: 2,
        completedDurationMinutes: 10,
      );
    }

    test('controller rejects a finisher on non-GREEN readiness', () async {
      final db = _MemoryDatabase();
      final repo = Repository(db);
      final controller = AppController(repo);
      final plan = strengthPlan(
        id: SessionTypeId.s2,
        sets: 2,
        tier: SessionTier.extended,
      );
      controller.todayTrace = traceFor(
        DateTime.now(),
        plan,
        bucket: ReadinessBucket.yellow,
      );

      await expectLater(
        controller.completeSession(
          plan,
          workSets(2),
          durationMinutes: 60,
          rehitFinisherCompletion: completedFinisher(),
        ),
        throwsStateError,
      );
      expect(await repo.loadSessionLogsSince(DateTime(2000)), isEmpty);
    });

    test('exactly 50% qualifies unless the session explicitly ended early', () {
      final controller = AppController(Repository(_MemoryDatabase()));
      final plan = strengthPlan(
        id: SessionTypeId.s2,
        sets: 4,
        tier: SessionTier.extended,
      );
      controller.todayTrace = traceFor(DateTime.now(), plan);

      final exactHalf = controller.rehitFinisherEligibility(
        plan,
        workSets(2),
      );
      expect(exactHalf.eligible, isTrue);
      expect(
        exactHalf.closedReasons,
        isNot(contains(RehitClosedReason.firstSessionBelowMinimumCompletion)),
      );

      final exactHalfWithZeroAttempts = controller.rehitFinisherEligibility(
        plan,
        [
          ...workSets(2),
          ...workSets(2, value: 0),
        ],
      );
      expect(exactHalfWithZeroAttempts.eligible, isTrue);

      final zeroOnly = controller.rehitFinisherEligibility(
        plan,
        workSets(4, value: 0),
      );
      expect(
        zeroOnly.closedReasons,
        contains(RehitClosedReason.firstSessionBelowMinimumCompletion),
      );

      final explicitlyEndedEarly = controller.rehitFinisherEligibility(
        plan,
        workSets(2),
        endedEarly: true,
      );
      expect(
        explicitlyEndedEarly.closedReasons,
        contains(RehitClosedReason.firstSessionEarlyAbort),
      );
      expect(
        explicitlyEndedEarly.closedReasons,
        isNot(contains(RehitClosedReason.firstSessionBelowMinimumCompletion)),
      );
    });

    test('pain, incomplete work, deload, and travel close the shared gate', () {
      final controller = AppController(Repository(_MemoryDatabase()));
      final plan = strengthPlan(
        id: SessionTypeId.s2,
        sets: 2,
        tier: SessionTier.extended,
      );
      controller.todayTrace = traceFor(DateTime.now(), plan);

      expect(
        controller
            .rehitFinisherEligibility(
              plan,
              workSets(2, painFlag: true),
            )
            .closedReasons,
        contains(RehitClosedReason.firstSessionPainEvent),
      );
      final incompletePlan = strengthPlan(
        id: SessionTypeId.s2,
        sets: 3,
        tier: SessionTier.extended,
      );
      final incomplete = controller.rehitFinisherEligibility(
        incompletePlan,
        workSets(1),
        endedEarly: true,
      );
      expect(
        incomplete.closedReasons,
        contains(RehitClosedReason.firstSessionEarlyAbort),
      );
      expect(
        incomplete.closedReasons,
        contains(RehitClosedReason.firstSessionBelowMinimumCompletion),
      );

      controller.exerciseStates['deload'] = ExerciseState(
        trackKey: 'deload',
        pattern: MovementPattern.pushHorizontal,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 1,
      );
      expect(
        controller.rehitFinisherEligibility(plan, workSets(2)).closedReasons,
        contains(RehitClosedReason.patternDeloadActive),
      );
      controller.exerciseStates.clear();
      controller.settings = controller.settings.copyWith(travelMode: true);
      expect(
        controller.rehitFinisherEligibility(plan, workSets(2)).closedReasons,
        contains(RehitClosedReason.rehitUnavailableDueToTravel),
      );
    });

    test('controller accepts finisher only for extended S2', () async {
      final controller = AppController(Repository(_MemoryDatabase()));
      final fullTier = strengthPlan(
        id: SessionTypeId.s2,
        sets: 2,
        tier: SessionTier.full,
      );
      controller.todayTrace = traceFor(DateTime.now(), fullTier);

      await expectLater(
        controller.completeSession(
          fullTier,
          workSets(2),
          durationMinutes: 35,
          rehitFinisherCompletion: completedFinisher(),
        ),
        throwsArgumentError,
      );

      final unreservedController =
          AppController(Repository(_MemoryDatabase()));
      final unreservedExtended = strengthPlan(
        id: SessionTypeId.s2,
        sets: 2,
        tier: SessionTier.extended,
        reserveRehitFinisher: false,
      );
      unreservedController.todayTrace =
          traceFor(DateTime.now(), unreservedExtended);
      await expectLater(
        unreservedController.completeSession(
          unreservedExtended,
          workSets(2),
          durationMinutes: 60,
          rehitFinisherCompletion: completedFinisher(),
        ),
        throwsArgumentError,
      );
    });
  });

  test('manual deload from empty state immediately replaces stale intensity',
      () async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final observedAt = DateTime.now();
    final staleIntensity = cardioPlan(SessionTypeId.s3, 35);
    controller.todayTrace = traceFor(observedAt, staleIntensity);

    expect(controller.exerciseStates, isEmpty);
    await controller.triggerManualDeload();

    expect(
      controller.exerciseStates['squat']!.status,
      ExerciseStatus.deload,
    );
    expect(
      controller.exerciseStates[dbCurl.trackKey]!.deloadSessionsRemaining,
      2,
    );
    expect(
      controller.isHighIntensityUsableNow(nowLocal: observedAt),
      isFalse,
    );
    expect(controller.todayTrace!.plan!.sessionId, SessionTypeId.s6);

    final nextStrength = await controller.swapToSession(SessionTypeId.s1);
    final work = nextStrength.plan!.exercises
        .where((exercise) => !exercise.isWarmup)
        .toList();
    expect(work, isNotEmpty);
    expect(
      work,
      everyElement(
        isA<PlannedExercise>()
            .having((exercise) => exercise.sets, 'sets', 1)
            .having(
              (exercise) => exercise.rirTarget,
              'RIR target',
              Rir.rir4plus,
            ),
      ),
    );
    expect(
      nextStrength.firedRuleCodes,
      containsAll(['DELOAD_ACTIVE_SQUAT', 'DELOAD_ACTIVE_HINGE']),
    );
  });

  group('shared second-session REHIT controller integration', () {
    test('qualifying REHIT recognition handles S2 and preserves S7 semantics',
        () {
      final controller = AppController(Repository(_MemoryDatabase()));
      final now = DateTime.now();
      const fullRehit = CardioCompletion(
        protocol: CardioProtocol.rehit,
        completedWorkIntervals: 2,
        completedWorkSeconds: 40,
        completedRecoveryIntervals: 1,
        completedRecoverySeconds: 180,
        completedDurationSeconds: 600,
      );
      const partialRehit = CardioCompletion(
        protocol: CardioProtocol.rehit,
        completedWorkIntervals: 1,
        completedWorkSeconds: 20,
        completedRecoveryIntervals: 0,
        completedRecoverySeconds: 0,
        completedDurationSeconds: 600,
      );
      SessionLog log({
        required String id,
        required SessionTypeId templateId,
        CardioCompletion? completion,
        bool legacyS2Flag = false,
        Set<FloorCategory> countsAs = const {},
      }) =>
          SessionLog(
            id: id,
            templateId: templateId,
            tier: SessionTier.full,
            date: now,
            completedAt: now,
            setLogs: const [],
            plannedWorkSets: 0,
            completedWorkSets: 0,
            durationMinutes: 10,
            countsAs: countsAs,
            cardioCompletion: completion,
            rehitFinisherCompleted: legacyS2Flag,
          );

      expect(
        controller.isQualifyingRehitForTesting(
          log(
            id: 's2-legacy-flag',
            templateId: SessionTypeId.s2,
            legacyS2Flag: true,
          ),
        ),
        isTrue,
      );
      expect(
        controller.isQualifyingRehitForTesting(
          log(
            id: 's2-structured-full',
            templateId: SessionTypeId.s2,
            completion: fullRehit,
          ),
        ),
        isTrue,
      );
      expect(
        controller.isQualifyingRehitForTesting(
          log(
            id: 's2-structured-partial',
            templateId: SessionTypeId.s2,
            completion: partialRehit,
          ),
        ),
        isFalse,
      );

      expect(
        controller.isQualifyingRehitForTesting(
          log(
            id: 's7-structured-full',
            templateId: SessionTypeId.s7,
            completion: fullRehit,
          ),
        ),
        isTrue,
      );
      expect(
        controller.isQualifyingRehitForTesting(
          log(
            id: 's7-structured-partial',
            templateId: SessionTypeId.s7,
            completion: partialRehit,
          ),
        ),
        isFalse,
      );
      expect(
        controller.isQualifyingRehitForTesting(
          log(
            id: 's7-legacy-credit',
            templateId: SessionTypeId.s7,
            countsAs: const {FloorCategory.intensity},
          ),
        ),
        isTrue,
      );
    });

    test('GREEN strength at exactly 50% exposes the shared eligible result', () async {
      final controller = await controllerAfterStrength(completedSets: 2);
      final result = controller.rehitEligibilityAt(DateTime.now());

      expect(result.eligible, isTrue);
      expect(result.closedReasons, isEmpty);
      expect(controller.canOfferSecondRehit, isTrue);
      expect(controller.queueState.served, contains(SessionTypeId.s1));
      expect(controller.queueState.pointer, SessionTypeId.s2);
    });

    test('controller closes optional REHIT at three cached distinct intensity days but leaves two days eligible', () async {
      SessionLog qualifyingRehit(String id, DateTime completedAt) => SessionLog(
            id: id,
            templateId: SessionTypeId.s7,
            tier: SessionTier.full,
            date: DateTime(
              completedAt.year,
              completedAt.month,
              completedAt.day,
            ),
            completedAt: completedAt,
            setLogs: const [],
            plannedWorkSets: 0,
            completedWorkSets: 0,
            durationMinutes: 10,
            countsAs: const {FloorCategory.intensity},
          );

      final controller = await controllerAfterStrength(completedSets: 2);
      final now = DateTime.now();
      final strengthLog = await controller.repo.loadSessionLogsSince(
        now.subtract(const Duration(days: 1)),
      );
      final threeDays = [
        ...strengthLog,
        qualifyingRehit('rehit-three', now.subtract(const Duration(days: 3))),
        qualifyingRehit('rehit-five', now.subtract(const Duration(days: 5))),
        qualifyingRehit('rehit-six', now.subtract(const Duration(days: 6))),
      ];
      controller.replaceRecentLogsForTesting(threeDays);
      expect(
        controller.rehitEligibilityAt(now).closedReasons,
        contains(RehitClosedReason.highIntensityTargetMet),
      );

      controller.replaceRecentLogsForTesting([
        ...strengthLog,
        qualifyingRehit('rehit-three', now.subtract(const Duration(days: 3))),
        qualifyingRehit('rehit-six', now.subtract(const Duration(days: 6))),
      ]);
      final due = controller.rehitEligibilityAt(now);
      expect(
        due.closedReasons,
        isNot(contains(RehitClosedReason.highIntensityTargetMet)),
      );
      expect(due.eligible, isTrue);
    });

    test('an explicit early end blocks later-day REHIT at exactly 50%', () async {
      final controller = await controllerAfterStrength(
        completedSets: 2,
        endedEarly: true,
      );
      final reasons =
          controller.rehitEligibilityAt(DateTime.now()).closedReasons;

      expect(reasons, contains(RehitClosedReason.firstSessionEarlyAbort));
      expect(
        reasons,
        isNot(contains(RehitClosedReason.firstSessionBelowMinimumCompletion)),
      );
    });

    test('YELLOW, RED, and illness guard close an otherwise qualifying day', () async {
      final controller = await controllerAfterStrength();
      final now = DateTime.now();
      final plan = strengthPlan();

      controller.todayTrace = traceFor(
        now,
        plan,
        bucket: ReadinessBucket.yellow,
      );
      expect(
        controller.rehitEligibilityAt(now).closedReasons,
        contains(RehitClosedReason.readinessNotGreen),
      );
      controller.todayTrace = traceFor(
        now,
        plan,
        bucket: ReadinessBucket.red,
      );
      expect(
        controller.rehitEligibilityAt(now).closedReasons,
        contains(RehitClosedReason.readinessNotGreen),
      );
      controller.todayTrace = traceFor(
        now,
        plan,
        firedRules: const [FiredRule(RuleKey.illnessGuard)],
      );
      expect(
        controller.rehitEligibilityAt(now).closedReasons,
        contains(RehitClosedReason.illnessGuardActive),
      );
    });

    test('lower-body pain and escalation anywhere block the offer', () async {
      final controller = await controllerAfterStrength();
      final now = DateTime.now();
      final plan = strengthPlan();

      controller.todayTrace = traceFor(
        now,
        plan,
        pain: [
          PainFlag(
            region: BodyRegion.kneeLeft,
            severity: PainSeverity.mild,
            flaggedDate: now,
          ),
        ],
      );
      expect(
        controller.rehitEligibilityAt(now).closedReasons,
        contains(RehitClosedReason.contraindicatingPainActive),
      );

      controller.todayTrace = traceFor(
        now,
        plan,
        pain: [
          PainFlag(
            region: BodyRegion.shoulderLeft,
            severity: PainSeverity.mild,
            flaggedDate: now,
            tags: const {PainTag.tingling},
          ),
        ],
      );
      expect(
        controller.rehitEligibilityAt(now).closedReasons,
        contains(RehitClosedReason.painEscalationActive),
      );
    });

    test('pain during first session and a below-50% partial both block', () async {
      final painful = await controllerAfterStrength(painFlag: true);
      expect(
        painful.rehitEligibilityAt(DateTime.now()).closedReasons,
        contains(RehitClosedReason.firstSessionPainEvent),
      );

      final partial = await controllerAfterStrength(
        plannedSets: 4,
        completedSets: 1,
      );
      final reasons = partial.rehitEligibilityAt(DateTime.now()).closedReasons;
      expect(
        reasons,
        contains(RehitClosedReason.firstSessionBelowMinimumCompletion),
      );
      expect(
        reasons,
        isNot(contains(RehitClosedReason.firstSessionEarlyAbort)),
        reason: 'dose failure is not an implicit early-abort fact',
      );
    });

    test('active exercise deload and travel/no-equipment mode block', () async {
      final controller = await controllerAfterStrength();
      controller.exerciseStates['unrelated-deload'] = ExerciseState(
        trackKey: 'unrelated-deload',
        pattern: MovementPattern.pushHorizontal,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 1,
      );
      expect(
        controller.rehitEligibilityAt(DateTime.now()).closedReasons,
        contains(RehitClosedReason.patternDeloadActive),
      );

      controller.exerciseStates.clear();
      controller.settings = controller.settings.copyWith(travelMode: true);
      expect(
        controller.rehitEligibilityAt(DateTime.now()).closedReasons,
        contains(RehitClosedReason.rehitUnavailableDueToTravel),
      );
    });

    test('qualifying S2 structured finisher prevents a duplicate REHIT', () async {
      final prescription = cardio.prescriptionFor(
        sessionId: SessionTypeId.s7,
        durationMinutes: 10,
        heartRateMaxBpm: 180,
      );
      final finisher = cardio.completionFromEntry(
        prescription: prescription,
        completedWorkIntervals: 2,
        completedDurationMinutes: 10,
      );
      final controller = await controllerAfterStrength(
        id: SessionTypeId.s2,
        rehitFinisherCompletion: finisher,
      );
      final reasons =
          controller.rehitEligibilityAt(DateTime.now()).closedReasons;

      expect(
        reasons,
        contains(RehitClosedReason.rehitAlreadyCompletedToday),
      );
      expect(
        reasons,
        contains(RehitClosedReason.intensityWithinTrailing48Hours),
      );
    });

    test('partial S2 finisher blocks next day without earning intensity credit',
        () async {
      final prescription = cardio.prescriptionFor(
        sessionId: SessionTypeId.s7,
        durationMinutes: 10,
        heartRateMaxBpm: 180,
      );
      final finisher = cardio.completionFromEntry(
        prescription: prescription,
        completedWorkIntervals: 1,
        completedDurationMinutes: 10,
      );
      final controller = await controllerAfterStrength(
        id: SessionTypeId.s2,
        rehitFinisherCompletion: finisher,
      );

      final log = (await controller.repo.loadSessionLogsSince(DateTime(2000)))
          .single;
      expect(log.countsAs, isNot(contains(FloorCategory.intensity)));

      final nextDay = DateTime.now().add(const Duration(days: 1));
      expect(
        controller.rehitEligibilityAt(nextDay).closedReasons,
        contains(RehitClosedReason.intensityWithinTrailing48Hours),
        reason: 'recovery safety is independent of category/queue credit',
      );
    });

    test('recovery guard rejects malformed legacy intensity records', () {
      final now = DateTime.now();
      SessionLog legacy({
        required int durationMinutes,
        Set<FloorCategory> countsAs = const {FloorCategory.intensity},
      }) =>
          SessionLog(
            id: 'legacy-$durationMinutes-${countsAs.length}',
            templateId: SessionTypeId.s7,
            tier: SessionTier.full,
            date: now,
            completedAt: now,
            setLogs: const [],
            plannedWorkSets: 0,
            completedWorkSets: 0,
            durationMinutes: durationMinutes,
            countsAs: countsAs,
          );

      expect(
        recoveryPolicy.isRecoveryRelevant(legacy(durationMinutes: 0)),
        isFalse,
      );
      expect(
        recoveryPolicy.isRecoveryRelevant(
          legacy(durationMinutes: 10, countsAs: const {}),
        ),
        isFalse,
      );
      expect(
        recoveryPolicy.isRecoveryRelevant(legacy(durationMinutes: 10)),
        isTrue,
      );

      final structuredPartial = SessionLog(
        id: 'structured-partial',
        templateId: SessionTypeId.s7,
        tier: SessionTier.full,
        date: now,
        completedAt: now,
        setLogs: const [],
        plannedWorkSets: 0,
        completedWorkSets: 0,
        durationMinutes: 10,
        countsAs: const {},
        cardioCompletion: const CardioCompletion(
          protocol: CardioProtocol.rehit,
          completedWorkIntervals: 1,
          completedWorkSeconds: 20,
          completedRecoveryIntervals: 0,
          completedRecoverySeconds: 0,
          completedDurationSeconds: 600,
        ),
      );
      expect(recoveryPolicy.isRecoveryRelevant(structuredPartial), isTrue);

      final intervalOnly = SessionLog(
        id: 'structured-interval-only',
        templateId: SessionTypeId.s7,
        tier: SessionTier.full,
        date: now,
        completedAt: now,
        setLogs: const [],
        plannedWorkSets: 0,
        completedWorkSets: 0,
        durationMinutes: 0,
        countsAs: const {},
        cardioCompletion: const CardioCompletion(
          protocol: CardioProtocol.rehit,
          completedWorkIntervals: 1,
          completedWorkSeconds: 0,
          completedRecoveryIntervals: 0,
          completedRecoverySeconds: 0,
          completedDurationSeconds: 0,
        ),
      );
      expect(recoveryPolicy.isRecoveryRelevant(intervalOnly), isTrue);

      final secondsOnly = SessionLog(
        id: 'structured-seconds-only',
        templateId: SessionTypeId.s3,
        tier: SessionTier.full,
        date: now,
        completedAt: now,
        setLogs: const [],
        plannedWorkSets: 0,
        completedWorkSets: 0,
        durationMinutes: 1,
        countsAs: const {},
        cardioCompletion: const CardioCompletion(
          protocol: CardioProtocol.norwegian4x4,
          completedWorkIntervals: 0,
          completedWorkSeconds: 20,
          completedRecoveryIntervals: 0,
          completedRecoverySeconds: 0,
          completedDurationSeconds: 20,
        ),
      );
      expect(recoveryPolicy.isRecoveryRelevant(secondsOnly), isTrue);
    });
  });
}

class SessionLogSnapshot {
  final CardioCompletion? cardioCompletion;
  final Set<FloorCategory> countsAs;
  final bool legacyFlag;

  const SessionLogSnapshot({
    required this.cardioCompletion,
    required this.countsAs,
    required this.legacyFlag,
  });
}

class _MemoryDatabase extends AppDatabase {
  final Map<String, Map<String, Map<String, dynamic>>> _rows = {};
  final Map<String, Map<String, DateTime>> _dates = {};

  @override
  Future<void> putJson(
    String table,
    String keyColumn,
    String key,
    Map<String, dynamic> json,
  ) async {
    _rows.putIfAbsent(table, () => {})[key] = Map<String, dynamic>.from(json);
  }

  @override
  Future<void> putJsonWithDate(
    String table,
    String key,
    DateTime date,
    Map<String, dynamic> json,
  ) async {
    _rows.putIfAbsent(table, () => {})[key] = Map<String, dynamic>.from(json);
    _dates.putIfAbsent(table, () => {})[key] = date;
  }

  @override
  Future<Map<String, dynamic>?> getJson(
    String table,
    String keyColumn,
    String key,
  ) async {
    final row = _rows[table]?[key];
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  @override
  Future<List<Map<String, dynamic>>> getAllJson(String table) async =>
      _rows[table]?.values
          .map((row) => Map<String, dynamic>.from(row))
          .toList() ??
      const [];

  @override
  Future<void> delete(String table, String keyColumn, String key) async {
    _rows[table]?.remove(key);
    _dates[table]?.remove(key);
  }

  @override
  Future<List<Map<String, dynamic>>> getJsonSince(
    String table,
    String dateColumn,
    DateTime since,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (final entry
        in (_rows[table] ?? const <String, Map<String, dynamic>>{}).entries) {
      final date = _dates[table]?[entry.key] ??
          DateTime.tryParse(entry.value[dateColumn]?.toString() ?? '');
      if (date != null && !date.isBefore(since)) {
        rows.add(Map<String, dynamic>.from(entry.value));
      }
    }
    rows.sort((a, b) =>
        (a[dateColumn]?.toString() ?? '').compareTo(b[dateColumn]?.toString() ?? ''));
    return rows;
  }
}
