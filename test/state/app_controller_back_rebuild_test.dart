import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/cardio_engine.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/user_settings.dart';
import 'package:morningcoach/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final yesterday = day.subtract(const Duration(days: 1));

  Map<String, ExerciseState> baseStates() => {
    'hinge': ExerciseState(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      ladderStepIndex: 2,
      currentLoad: 90,
      lastTrainedDate: day.subtract(const Duration(days: 30)),
    ),
    'squat': ExerciseState(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      currentLoad: 24,
      lastTrainedDate: day.subtract(const Duration(days: 2)),
    ),
  };

  LowerBackRecoveryState rebuild({
    BackRebuildStage stage = BackRebuildStage.bridges,
    int goodMornings = 0,
    BikeReturnStep bike = BikeReturnStep.walkOnly,
    DateTime? pendingDate,
    BackRebuildExposure exposure = BackRebuildExposure.none,
    BikeExposure bikeExposure = BikeExposure.none,
  }) => LowerBackRecoveryState(
    active: true,
    activatedAt: day.subtract(const Duration(days: 10)),
    preRecoveryHingeLoad: 90,
    preRecoveryHingeLadderStepIndex: 2,
    rebuildStage: stage,
    rebuildGoodMornings: goodMornings,
    bikeReturnStep: bike,
    pendingNextMorningSessionDate: pendingDate,
    pendingSameDayResponse: pendingDate == null
        ? null
        : LowerBackSymptomResponse.unchanged,
    pendingRebuildExposure: exposure,
    pendingBikeExposure: bikeExposure,
  );

  AppController controllerWith(
    LowerBackRecoveryState state, {
    Map<String, ExerciseState>? states,
  }) => AppController(Repository(_MemoryDatabase()))
    ..settings = UserSettings(lowerBackRecovery: state)
    ..exerciseStates = states ?? baseStates();

  SessionPlan planFor(AppController controller, SessionTypeId id) {
    final output = const DecisionEngine().decide(
      DecisionEngineInput(
        checkinHistory: const [],
        checkin: CheckIn(
          date: day,
          timeMinutes: 35,
          subjective: 4,
          timestamp: now,
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
        exerciseStates: controller.exerciseStates,
        queueState: const QueueState(),
        settings: controller.settings,
        today: day,
        forcedSessionId: id,
      ),
    );
    controller
      ..exerciseStates = output.patchedExerciseStates
      ..todayTrace = output.trace;
    return output.trace.plan!;
  }

  List<SetLog> allSets(SessionPlan plan, {String? painTrack}) => [
    for (final e in plan.exercises.where((e) => !e.isWarmup))
      for (var i = 0; i < e.sets; i++)
        SetLog(
          trackKey: e.trackKey,
          pattern: e.pattern,
          exerciseName: e.name,
          weight: e.loadTotal ?? 0,
          value: e.targetRange.$2,
          metric: e.metric,
          rir: e.rirTarget,
          painFlag: e.trackKey == painTrack,
          timestamp: now,
        ),
  ];

  test('the check-in answer moves the stage before today is planned', () async {
    final controller = controllerWith(
      rebuild(
        goodMornings: 1,
        pendingDate: yesterday,
        exposure: BackRebuildExposure.accessory,
      ),
    );
    expect(controller.lowerBackMorningResponseDue, isTrue);
    await expectLater(
      controller.submitCheckIn(timeMinutes: 35, subjective: 4),
      throwsArgumentError,
    );

    await controller.submitCheckIn(
      timeMinutes: 35,
      subjective: 4,
      backCheck: LowerBackSymptomResponse.better,
    );
    expect(
      controller.lowerBackRecovery.rebuildStage,
      BackRebuildStage.blockDeadlift,
    );
    expect(controller.lowerBackMorningResponseDue, isFalse);

    final trace = await controller.swapToSession(SessionTypeId.s1);
    final work = trace.plan!.exercises.where((e) => !e.isWarmup).toList();
    expect(work.last.trackKey, backRebuildBlockDeadlift.trackKey);
    expect(work.last.loadTotal, 42);
  });

  test(
    'completed rebuild work waits for tomorrow; pain makes it a setback',
    () async {
      for (final painful in [false, true]) {
        final controller = controllerWith(
          rebuild(stage: BackRebuildStage.blockDeadlift),
        );
        final plan = planFor(controller, SessionTypeId.s1);
        await controller.completeSession(
          plan,
          allSets(
            plan,
            painTrack: painful ? backRebuildBlockDeadlift.trackKey : null,
          ),
          durationMinutes: 30,
        );
        final state = controller.lowerBackRecovery;
        expect(state.pendingNextMorningSessionDate, day);
        expect(state.pendingRebuildExposure, BackRebuildExposure.loaded);
        expect(state.recoverySessionDates, [day]);
        expect(state.rebuildStage, BackRebuildStage.blockDeadlift);
        expect(
          state.pendingSameDayResponse,
          painful
              ? LowerBackSymptomResponse.worse
              : LowerBackSymptomResponse.unchanged,
        );
        final saved = await controller.repo.loadSettings();
        expect(saved.lowerBackRecovery, state);
      }
    },
  );

  test('a worse morning eases both stage lifts by one load step', () async {
    final controller = controllerWith(
      rebuild(
        stage: BackRebuildStage.blockDeadlift,
        pendingDate: yesterday,
        exposure: BackRebuildExposure.loaded,
      ),
      states: {
        ...baseStates(),
        backRebuildBlockDeadlift.trackKey: ExerciseState(
          trackKey: backRebuildBlockDeadlift.trackKey,
          pattern: MovementPattern.hinge,
          currentLoad: 60,
          lastTrainedDate: yesterday,
        ),
        backRebuildBoxSquat.trackKey: ExerciseState(
          trackKey: backRebuildBoxSquat.trackKey,
          pattern: MovementPattern.squat,
          currentLoad: 18,
          lastTrainedDate: yesterday,
        ),
      },
    );
    await controller.recordLowerBackNextMorningResponse(
      LowerBackSymptomResponse.worse,
    );
    expect(controller.lowerBackRecovery.rebuildStage, BackRebuildStage.bridges);
    expect(
      controller.exerciseStates[backRebuildBlockDeadlift.trackKey]!.currentLoad,
      50,
    );
    // One single-dumbbell step lighter, above the 12 lb floor.
    expect(
      controller.exerciseStates[backRebuildBoxSquat.trackKey]!.currentLoad,
      15,
    );
    expect(controller.exerciseStates['hinge']!.currentLoad, 90);
    expect(controller.exerciseStates['squat']!.currentLoad, 24);
  });

  test('finishing hands the hinge to the normal ladder at the RDL', () async {
    final controller = controllerWith(
      rebuild(
        stage: BackRebuildStage.romanianDeadlift,
        goodMornings: 1,
        bike: BikeReturnStep.zone2Ride,
        pendingDate: yesterday,
        exposure: BackRebuildExposure.loaded,
      ),
      states: {
        ...baseStates(),
        // One progression step past the cap after a capped session.
        backRebuildRomanianDeadlift.trackKey: ExerciseState(
          trackKey: backRebuildRomanianDeadlift.trackKey,
          pattern: MovementPattern.hinge,
          currentLoad: 100,
          lastTrainedDate: yesterday,
        ),
        backRebuildGobletSquat.trackKey: ExerciseState(
          trackKey: backRebuildGobletSquat.trackKey,
          pattern: MovementPattern.squat,
          currentLoad: 25,
          lastTrainedDate: yesterday,
        ),
      },
    );
    await controller.recordLowerBackNextMorningResponse(
      LowerBackSymptomResponse.unchanged,
    );
    expect(controller.lowerBackRecovery.active, isFalse);
    expect(
      controller.lowerBackRecovery.bikeReturnStep,
      BikeReturnStep.zone2Ride,
    );
    final hinge = controller.exerciseStates['hinge']!;
    expect(hinge.ladderStepIndex, 2);
    expect(hinge.currentLoad, 90);
    expect(hinge.lastTrainedDate, yesterday);
    expect(hinge.lastPrescriptionChange, contains('Back rebuild complete'));
    expect((await controller.repo.loadExerciseStates())['hinge'], isNotNull);
    // The squat continues as a normal goblet squat, capped at its old load.
    final squat = controller.exerciseStates['squat']!;
    expect(squat.ladderStepIndex, 0);
    expect(squat.currentLoad, 24);
    expect(squat.lastPrescriptionChange, contains('Back rebuild complete'));
    expect(
      (await controller.repo.loadExerciseStates())['squat']!.currentLoad,
      24,
    );
  });

  test(
    'stage 3 does not finish until the squat also reaches its cap',
    () async {
      final controller = controllerWith(
        rebuild(
          stage: BackRebuildStage.romanianDeadlift,
          goodMornings: 1,
          pendingDate: yesterday,
          exposure: BackRebuildExposure.loaded,
        ),
        states: {
          ...baseStates(),
          backRebuildRomanianDeadlift.trackKey: ExerciseState(
            trackKey: backRebuildRomanianDeadlift.trackKey,
            pattern: MovementPattern.hinge,
            currentLoad: 90,
            lastTrainedDate: yesterday,
          ),
          backRebuildGobletSquat.trackKey: ExerciseState(
            trackKey: backRebuildGobletSquat.trackKey,
            pattern: MovementPattern.squat,
            currentLoad: 20,
            lastTrainedDate: yesterday,
          ),
        },
      );
      await controller.recordLowerBackNextMorningResponse(
        LowerBackSymptomResponse.better,
      );
      expect(controller.lowerBackRecovery.active, isTrue);
      expect(
        controller.lowerBackRecovery.rebuildStage,
        BackRebuildStage.romanianDeadlift,
      );
      expect(controller.lowerBackRecovery.rebuildGoodMornings, 2);
      expect(
        controller.backRebuildNextStepLabel,
        'Next: normal deadlifts and squats once the squat reaches your old '
        'load',
      );
      expect(controller.exerciseStates['hinge']!.ladderStepIndex, 2);
      expect(controller.exerciseStates['hinge']!.currentLoad, 90);
    },
  );

  test(
    'ending early resumes the deadlift at the rebuild level, not the old load',
    () async {
      final atBlocks = controllerWith(
        rebuild(stage: BackRebuildStage.blockDeadlift),
        states: {
          ...baseStates(),
          backRebuildBlockDeadlift.trackKey: ExerciseState(
            trackKey: backRebuildBlockDeadlift.trackKey,
            pattern: MovementPattern.hinge,
            currentLoad: 48,
            lastTrainedDate: day.subtract(const Duration(days: 2)),
          ),
        },
      );
      await atBlocks.deactivateLowerBackRecovery();
      final hinge = atBlocks.exerciseStates['hinge']!;
      expect(hinge.ladderStepIndex, 0);
      expect(hinge.currentLoad, 48);
      expect(atBlocks.lowerBackRecovery.active, isFalse);
      expect(atBlocks.cyclingAccess.rehit, isTrue);
      // No box squat trained yet: the goblet squat resumes at the 60% floor
      // of its old 24 lb (14.4, rounded down to 12), never at 24.
      expect(atBlocks.exerciseStates['squat']!.ladderStepIndex, 0);
      expect(atBlocks.exerciseStates['squat']!.currentLoad, 12);

      final atBridges = controllerWith(
        rebuild(),
        states: {
          ...baseStates(),
          backRebuildBoxSquat.trackKey: ExerciseState(
            trackKey: backRebuildBoxSquat.trackKey,
            pattern: MovementPattern.squat,
            currentLoad: 15,
            lastTrainedDate: day.subtract(const Duration(days: 5)),
          ),
        },
      );
      await atBridges.deactivateLowerBackRecovery();
      expect(atBridges.exerciseStates['hinge']!.ladderStepIndex, 0);
      expect(atBridges.exerciseStates['hinge']!.currentLoad, 42);
      expect(atBridges.exerciseStates['squat']!.currentLoad, 15);
    },
  );

  test(
    'staged squat work alone opens the check; a flagged set is a setback',
    () async {
      for (final painful in [false, true]) {
        final controller = controllerWith(rebuild());
        final plan = planFor(controller, SessionTypeId.s1);
        final squatOnly =
            allSets(
                  plan,
                  painTrack: painful ? backRebuildSplitSquat.trackKey : null,
                )
                .where((set) => set.trackKey == backRebuildSplitSquat.trackKey)
                .toList();
        expect(squatOnly, isNotEmpty);
        await controller.completeSession(plan, squatOnly, durationMinutes: 20);
        final state = controller.lowerBackRecovery;
        expect(state.pendingNextMorningSessionDate, day);
        expect(state.pendingRebuildExposure, BackRebuildExposure.accessory);
        expect(
          state.pendingSameDayResponse,
          painful
              ? LowerBackSymptomResponse.worse
              : LowerBackSymptomResponse.unchanged,
        );
        // The normal squat ladder never moves during the rebuild.
        final saved = await controller.repo.loadExerciseStates();
        expect(saved['squat']?.currentLoad ?? 24, 24);
      }
    },
  );

  test('stale plans with normal squats or back-loading lifts are refused', () {
    final controller = controllerWith(
      rebuild(),
      states: {
        ...baseStates(),
        MovementPattern.pullHorizontal.name: ExerciseState(
          trackKey: MovementPattern.pullHorizontal.name,
          pattern: MovementPattern.pullHorizontal,
          currentLoad: 20,
        ),
        MovementPattern.pushVertical.name: ExerciseState(
          trackKey: MovementPattern.pushVertical.name,
          pattern: MovementPattern.pushVertical,
          currentLoad: 20,
        ),
      },
    );
    SessionPlan planWith(String trackKey, MovementPattern pattern) =>
        SessionPlan(
          sessionId: SessionTypeId.s4,
          sessionName: 'Full Body',
          tier: SessionTier.full,
          exercises: [
            PlannedExercise(
              trackKey: trackKey,
              pattern: pattern,
              name: trackKey,
              sets: 3,
              targetRange: (8, 10),
              loadTotal: 20,
              rirTarget: Rir.rir2,
            ),
          ],
          estimatedDurationMin: 35,
          lowerBackRecoveryMode: true,
        );
    // Built before the staged squat or while the row was still bent-over.
    expect(
      controller.isPlanUsableNow(
        planWith(MovementPattern.squat.name, MovementPattern.squat),
      ),
      isFalse,
    );
    expect(
      controller.isPlanUsableNow(
        planWith(
          MovementPattern.pullHorizontal.name,
          MovementPattern.pullHorizontal,
        ),
      ),
      isFalse,
    );
    // A seated press (step 0) is already supported.
    expect(
      controller.isPlanUsableNow(
        planWith(
          MovementPattern.pushVertical.name,
          MovementPattern.pushVertical,
        ),
      ),
      isTrue,
    );
    // Stage 1 only allows the split squat; a box squat is from stage 2.
    expect(
      controller.isPlanUsableNow(
        planWith(backRebuildBoxSquat.trackKey, MovementPattern.squat),
      ),
      isFalse,
    );
    expect(
      controller.isPlanUsableNow(
        planWith(backRebuildSplitSquat.trackKey, MovementPattern.squat),
      ),
      isTrue,
    );
    controller.settings = controller.settings.copyWith(
      lowerBackRecovery: rebuild(stage: BackRebuildStage.blockDeadlift),
    );
    expect(
      controller.isPlanUsableNow(
        planWith(backRebuildBoxSquat.trackKey, MovementPattern.squat),
      ),
      isTrue,
    );
    // A flag day at stage 2 falls back to split squats: still usable.
    expect(
      controller.isPlanUsableNow(
        planWith(backRebuildSplitSquat.trackKey, MovementPattern.squat),
      ),
      isTrue,
    );
  });

  test('rides open the bike return step by step; walks never count', () async {
    const cardio = CardioEngine();
    CardioCompletion zone2(int minutes, {bool walk = false}) =>
        cardio.completionFromEntry(
          prescription: cardio.prescriptionFor(
            sessionId: SessionTypeId.s6,
            durationMinutes: minutes,
            heartRateMaxBpm: 190,
            walk: walk,
          ),
          completedWorkIntervals: 1,
          completedDurationMinutes: minutes,
        );

    final walking = controllerWith(rebuild());
    await walking.logUnplannedZone2(completion: zone2(40, walk: true));
    expect(walking.lowerBackRecovery.awaitingNextMorningResponse, isFalse);

    final testRide = controllerWith(rebuild());
    await testRide.logUnplannedZone2(completion: zone2(15));
    expect(
      testRide.lowerBackRecovery.pendingBikeExposure,
      BikeExposure.easyRide,
    );
    expect(testRide.lowerBackRecovery.pendingNextMorningSessionDate, day);

    final answered = controllerWith(
      rebuild(pendingDate: yesterday, bikeExposure: BikeExposure.easyRide),
    );
    await answered.recordLowerBackNextMorningResponse(
      LowerBackSymptomResponse.unchanged,
    );
    expect(answered.lowerBackRecovery.bikeReturnStep, BikeReturnStep.zone2Ride);
    expect(answered.cyclingAccess.zone2Ride, isTrue);
    expect(answered.cyclingAccess.fourByFour, isFalse);
  });

  test('plans are rechecked against the bike return and the current stage', () {
    final controller = controllerWith(rebuild());
    const cardio = CardioEngine();
    SessionPlan zone2Plan({required bool walk}) => SessionPlan(
      sessionId: SessionTypeId.s6,
      sessionName: 'Zone 2',
      tier: SessionTier.full,
      exercises: const [],
      estimatedDurationMin: 60,
      cardioPrescription: cardio.prescriptionFor(
        sessionId: SessionTypeId.s6,
        durationMinutes: 60,
        heartRateMaxBpm: 190,
        walk: walk,
      ),
      lowerBackRecoveryMode: true,
    );
    expect(controller.isPlanUsableNow(zone2Plan(walk: true)), isTrue);
    expect(controller.isPlanUsableNow(zone2Plan(walk: false)), isFalse);

    final staleStage = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Lower Strength',
      tier: SessionTier.full,
      exercises: const [
        PlannedExercise(
          trackKey: 'sub:hinge:back_rebuild_romanian_deadlift',
          pattern: MovementPattern.hinge,
          name: 'DB Romanian deadlift',
          sets: 3,
          targetRange: (8, 10),
          loadTotal: 60,
          rirTarget: Rir.rir2,
        ),
      ],
      estimatedDurationMin: 30,
      lowerBackRecoveryMode: true,
    );
    expect(controller.isPlanUsableNow(staleStage), isFalse);
  });

  test('the back routine is offered on days without lifting', () async {
    DecisionTrace traceWith(SessionPlan? plan) => DecisionTrace(
      date: day,
      checkin: CheckIn(
        date: day,
        timeMinutes: plan == null ? 0 : 35,
        subjective: 4,
        timestamp: now,
      ),
      recovery: const RecoveryTrace(
        hrvZToday: 0,
        hrvTrend3: 0,
        sleepScore: 90,
        rhrDev: 0,
        bucket: ReadinessBucket.green,
        compositeScore: 1,
      ),
      candidates: const [],
      firedRules: const [],
      plan: plan,
      restReason: plan == null ? 'Rest day' : null,
      queue: const QueueTraceInfo(
        pointerBefore: SessionTypeId.s1,
        servedBefore: {},
      ),
    );
    final controller = AppController(Repository(_MemoryDatabase()));
    expect(controller.backRoutineOfferedToday, isFalse);

    controller.todayTrace = traceWith(null);
    expect(controller.backRoutineOfferedToday, isTrue);
    expect(controller.backRoutineDoneToday, isFalse);
    await controller.markBackRoutineDone();
    expect(controller.backRoutineDoneToday, isTrue);
    expect(
      (await controller.repo.loadSettings()).backRoutineDoneDay,
      controller.repo.ymd(day),
    );

    controller.todayTrace = traceWith(
      const SessionPlan(
        sessionId: SessionTypeId.s2,
        sessionName: 'Upper Strength',
        tier: SessionTier.full,
        exercises: [],
        estimatedDurationMin: 30,
      ),
    );
    expect(controller.backRoutineOfferedToday, isFalse);

    controller
      ..todayTrace = traceWith(null)
      ..settings = controller.settings.copyWith(bigThreeEnabled: false);
    expect(controller.backRoutineOfferedToday, isFalse);
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
      final date =
          _dates[table]?[entry.key] ??
          DateTime.tryParse(entry.value[dateColumn]?.toString() ?? '');
      if (date != null && !date.isBefore(since)) {
        rows.add(Map<String, dynamic>.from(entry.value));
      }
    }
    rows.sort(
      (a, b) => (a[dateColumn]?.toString() ?? '').compareTo(
        b[dateColumn]?.toString() ?? '',
      ),
    );
    return rows;
  }
}
