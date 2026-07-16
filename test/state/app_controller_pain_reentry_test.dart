import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ExerciseState pendingState({
    required String trackKey,
    required MovementPattern pattern,
    required double load,
  }) =>
      ExerciseState(
        trackKey: trackKey,
        pattern: pattern,
        currentLoad: load,
        lastTrainedDate: DateTime.now().subtract(const Duration(days: 2)),
        painFrozen: true,
        painSeverity: PainSeverity.sharp,
        painRegion: pattern == MovementPattern.squat
            ? BodyRegion.kneeLeft
            : BodyRegion.wrist,
        painFlaggedDate: DateTime.now().subtract(const Duration(days: 2)),
        prePainLoad: load,
        painReentryTestOffered: true,
      );

  SessionPlan reentryPlan({
    required String trackKey,
    required MovementPattern pattern,
    required String name,
    required ExerciseMetric metric,
    required int target,
    double? load,
    bool travel = false,
    bool marked = true,
  }) =>
      SessionPlan(
        sessionId: SessionTypeId.s1,
        sessionName: 'Pain re-entry',
        tier: SessionTier.full,
        estimatedDurationMin: 20,
        grantsQueueCredit: false,
        travelMode: travel,
        exercises: [
          PlannedExercise(
            trackKey: trackKey,
            pattern: pattern,
            name: name,
            sets: 1,
            metric: metric,
            targetRange: (target, target),
            loadTotal: load,
            rirTarget: Rir.rir4plus,
            isTravel: travel,
            isPainReentryTest: marked,
          ),
        ],
      );

  SetLog loggedSet({
    required String trackKey,
    required MovementPattern pattern,
    required String name,
    required ExerciseMetric metric,
    required int value,
    required double weight,
    Rir rir = Rir.rir4plus,
    bool pain = false,
  }) =>
      SetLog(
        trackKey: trackKey,
        pattern: pattern,
        exerciseName: name,
        weight: weight,
        metric: metric,
        value: value,
        rir: rir,
        painFlag: pain,
        timestamp: DateTime.now(),
      );

  Future<_PainTestController> controllerWith(
    ExerciseState state,
  ) async {
    final controller = _PainTestController(
      Repository(_PainMemoryDatabase()),
    );
    controller.exerciseStates[state.trackKey] = state;
    return controller;
  }

  test('complete prescribed rep re-entry clears the freeze', () async {
    const trackKey = 'squat';
    final controller = await controllerWith(
      pendingState(
        trackKey: trackKey,
        pattern: MovementPattern.squat,
        load: 24,
      ),
    );
    final plan = reentryPlan(
      trackKey: trackKey,
      pattern: MovementPattern.squat,
      name: 'Goblet squat',
      metric: ExerciseMetric.reps,
      target: 8,
      load: 12,
    );

    await controller.completeSession(
      plan,
      [
        loggedSet(
          trackKey: trackKey,
          pattern: MovementPattern.squat,
          name: 'Goblet squat',
          metric: ExerciseMetric.reps,
          value: 8,
          weight: 12.0000005,
        ),
      ],
      durationMinutes: 10,
    );

    final state = controller.exerciseStates[trackKey]!;
    expect(state.painFrozen, isFalse);
    expect(state.painReentryTestOffered, isFalse);
    expect(state.lastTrainedDate, controller.today());
  });

  test('complete prescribed timed hold clears the freeze', () async {
    const trackKey = 'coreGrip';
    final controller = await controllerWith(
      pendingState(
        trackKey: trackKey,
        pattern: MovementPattern.coreGrip,
        load: 0,
      ),
    );
    final plan = reentryPlan(
      trackKey: trackKey,
      pattern: MovementPattern.coreGrip,
      name: 'Plank',
      metric: ExerciseMetric.seconds,
      target: 10,
    );

    await controller.completeSession(
      plan,
      [
        loggedSet(
          trackKey: trackKey,
          pattern: MovementPattern.coreGrip,
          name: 'Plank',
          metric: ExerciseMetric.seconds,
          value: 10,
          weight: 0,
        ),
      ],
      durationMinutes: 10,
    );

    expect(controller.exerciseStates[trackKey]!.painFrozen, isFalse);
    expect(
      controller.exerciseStates[trackKey]!.painReentryTestOffered,
      isFalse,
    );
  });

  test('underdosed positive work is logged and stamps recency but stays frozen',
      () async {
    const trackKey = 'squat';
    final controller = await controllerWith(
      pendingState(
        trackKey: trackKey,
        pattern: MovementPattern.squat,
        load: 24,
      ),
    );
    final plan = reentryPlan(
      trackKey: trackKey,
      pattern: MovementPattern.squat,
      name: 'Goblet squat',
      metric: ExerciseMetric.reps,
      target: 8,
      load: 12,
    );

    await controller.completeSession(
      plan,
      [
        loggedSet(
          trackKey: trackKey,
          pattern: MovementPattern.squat,
          name: 'Goblet squat',
          metric: ExerciseMetric.reps,
          value: 7,
          weight: 12,
        ),
      ],
      durationMinutes: 10,
    );

    final state = controller.exerciseStates[trackKey]!;
    expect(state.painFrozen, isTrue);
    expect(state.painReentryTestOffered, isTrue);
    expect(state.lastTrainedDate, controller.today());
    final logs = await controller.repo.loadSessionLogsSince(DateTime(2000));
    expect(logs.single.setLogs.single.value, 7);
  });

  final invalidVariants = <({
    String name,
    ExerciseMetric metric,
    Rir rir,
    double weight,
    bool pain,
  })>[
    (
      name: 'wrong metric',
      metric: ExerciseMetric.seconds,
      rir: Rir.rir4plus,
      weight: 12,
      pain: false,
    ),
    (
      name: 'wrong RIR',
      metric: ExerciseMetric.reps,
      rir: Rir.rir3plus,
      weight: 12,
      pain: false,
    ),
    (
      name: 'wrong load',
      metric: ExerciseMetric.reps,
      rir: Rir.rir4plus,
      weight: 13,
      pain: false,
    ),
    (
      name: 'pain event',
      metric: ExerciseMetric.reps,
      rir: Rir.rir4plus,
      weight: 12,
      pain: true,
    ),
  ];

  for (final variant in invalidVariants) {
    test('${variant.name} cannot pass formal re-entry', () async {
      const trackKey = 'squat';
      final controller = await controllerWith(
        pendingState(
          trackKey: trackKey,
          pattern: MovementPattern.squat,
          load: 24,
        ),
      );
      final plan = reentryPlan(
        trackKey: trackKey,
        pattern: MovementPattern.squat,
        name: 'Goblet squat',
        metric: ExerciseMetric.reps,
        target: 8,
        load: 12,
      );

      await controller.completeSession(
        plan,
        [
          loggedSet(
            trackKey: trackKey,
            pattern: MovementPattern.squat,
            name: 'Goblet squat',
            metric: variant.metric,
            value: 8,
            weight: variant.weight,
            rir: variant.rir,
            pain: variant.pain,
          ),
        ],
        durationMinutes: 10,
      );

      final state = controller.exerciseStates[trackKey]!;
      expect(state.painFrozen, isTrue);
      expect(state.painReentryTestOffered, isTrue);
      expect(state.lastTrainedDate, controller.today());
      expect(
        await controller.repo.loadSessionLogsSince(DateTime(2000)),
        hasLength(1),
      );
    });
  }

  test('travel and unmarked lookalike entries cannot pass formal re-entry',
      () async {
    for (final variant in [(travel: true, marked: true), (travel: false, marked: false)]) {
      const trackKey = 'squat';
      final controller = await controllerWith(
        pendingState(
          trackKey: trackKey,
          pattern: MovementPattern.squat,
          load: 24,
        ),
      );
      final plan = reentryPlan(
        trackKey: trackKey,
        pattern: MovementPattern.squat,
        name: variant.travel ? 'Split squat (bodyweight)' : 'Goblet squat',
        metric: ExerciseMetric.reps,
        target: 8,
        load: variant.travel ? null : 12,
        travel: variant.travel,
        marked: variant.marked,
      );

      await controller.completeSession(
        plan,
        [
          loggedSet(
            trackKey: trackKey,
            pattern: MovementPattern.squat,
            name: plan.exercises.single.name,
            metric: ExerciseMetric.reps,
            value: 8,
            weight: variant.travel ? 0 : 12,
          ),
        ],
        durationMinutes: 10,
      );

      final state = controller.exerciseStates[trackKey]!;
      expect(state.painFrozen, isTrue);
      expect(state.painReentryTestOffered, isTrue);
      expect(state.lastTrainedDate, controller.today());
    }
  });
}

class _PainTestController extends AppController {
  _PainTestController(super.repo);

  @override
  Future<void> syncNotifications() async {}
}

class _PainMemoryDatabase extends AppDatabase {
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
  Future<List<Map<String, dynamic>>> getJsonSince(
    String table,
    String dateColumn,
    DateTime since,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (final entry
        in (_rows[table] ?? const <String, Map<String, dynamic>>{}).entries) {
      final date = _dates[table]?[entry.key];
      if (date != null && !date.isBefore(since)) {
        rows.add(Map<String, dynamic>.from(entry.value));
      }
    }
    return rows;
  }
}
