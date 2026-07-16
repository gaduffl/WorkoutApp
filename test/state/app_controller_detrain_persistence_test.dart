import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/progression_engine.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SessionPlan planFor(PlannedExercise exercise) => SessionPlan(
        sessionId: SessionTypeId.s1,
        sessionName: 'Detraining return',
        tier: SessionTier.full,
        exercises: [exercise],
        estimatedDurationMin: 35,
      );

  List<SetLog> completedSets(
    PlannedExercise exercise, {
    required int count,
    required int value,
    Rir rir = Rir.rir2,
    bool painFlag = false,
  }) =>
      List.generate(
        count,
        (_) => SetLog(
          trackKey: exercise.trackKey,
          pattern: exercise.pattern,
          exerciseName: exercise.name,
          weight: exercise.loadTotal ?? 0,
          metric: exercise.metric,
          value: value,
          rir: rir,
          painFlag: painFlag,
          timestamp: DateTime.now(),
        ),
      );

  Future<ExerciseState> persistedState(
    AppController controller,
    String trackKey,
  ) async {
    final persisted = await controller.repo.loadExerciseStates();
    return persisted[trackKey]!;
  }

  test('a fully completed loaded return persists its easier resolved step',
      () async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final oldState = ExerciseState(
      trackKey: MovementPattern.hinge.name,
      pattern: MovementPattern.hinge,
      ladderStepIndex: 3,
      currentLoad: 100,
      status: ExerciseStatus.hold,
      lastTrainedDate: controller.today().subtract(const Duration(days: 25)),
    );
    controller.exerciseStates = {oldState.trackKey: oldState};
    const exercise = PlannedExercise(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      name: 'DB RDL',
      sets: 2,
      targetRange: (6, 10),
      loadTotal: 80,
      rirTarget: Rir.rir2,
      persistLoadOnCompletion: true,
    );

    await controller.completeSession(
      planFor(exercise),
      completedSets(exercise, count: 2, value: 8),
      durationMinutes: 20,
    );

    final state = controller.exerciseStates[oldState.trackKey]!;
    expect(state.ladderStepIndex, 2);
    expect(state.currentLoad, 80);
    expect(state.status, ExerciseStatus.progress);
    final stored = await persistedState(controller, oldState.trackKey);
    expect(stored.ladderStepIndex, 2);
    expect(stored.currentLoad, 80);
  });

  test('a fully completed bodyweight return persists its resolved step',
      () async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final oldState = ExerciseState(
      trackKey: MovementPattern.pushHorizontal.name,
      pattern: MovementPattern.pushHorizontal,
      ladderStepIndex: 1,
      currentLoad: 40,
      lastTrainedDate: controller.today().subtract(const Duration(days: 25)),
    );
    controller.exerciseStates = {oldState.trackKey: oldState};
    const exercise = PlannedExercise(
      trackKey: 'pushHorizontal',
      pattern: MovementPattern.pushHorizontal,
      name: 'Push-up',
      sets: 2,
      targetRange: (6, 10),
      rirTarget: Rir.rir2,
      persistLoadOnCompletion: true,
    );

    await controller.completeSession(
      planFor(exercise),
      completedSets(exercise, count: 2, value: 8),
      durationMinutes: 20,
    );

    final state = await persistedState(controller, oldState.trackKey);
    expect(state.ladderStepIndex, 0);
    expect(
      const ProgressionEngine().ladderStepFor(state).name,
      'Push-up',
    );
  });

  test('partial loaded detraining work retains the emitted safe baseline',
      () async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final oldState = ExerciseState(
      trackKey: MovementPattern.hinge.name,
      pattern: MovementPattern.hinge,
      ladderStepIndex: 3,
      currentLoad: 100,
      lastTrainedDate: controller.today().subtract(const Duration(days: 25)),
    );
    controller.exerciseStates = {oldState.trackKey: oldState};
    const exercise = PlannedExercise(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      name: 'DB RDL',
      sets: 2,
      targetRange: (6, 10),
      loadTotal: 80,
      rirTarget: Rir.rir2,
      persistLoadOnCompletion: true,
    );

    await controller.completeSession(
      planFor(exercise),
      completedSets(exercise, count: 1, value: 8),
      durationMinutes: 10,
      endedEarly: true,
    );

    final state = await persistedState(controller, oldState.trackKey);
    expect(state.ladderStepIndex, 2);
    expect(state.currentLoad, 80);
    expect(state.status, ExerciseStatus.progress);
    expect(state.lastTrainedDate, controller.today());
  });

  test('partial bodyweight detraining work retains the easier emitted step',
      () async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final oldState = ExerciseState(
      trackKey: MovementPattern.pushHorizontal.name,
      pattern: MovementPattern.pushHorizontal,
      ladderStepIndex: 1,
      currentLoad: 40,
      lastTrainedDate: controller.today().subtract(const Duration(days: 25)),
    );
    controller.exerciseStates = {oldState.trackKey: oldState};
    const exercise = PlannedExercise(
      trackKey: 'pushHorizontal',
      pattern: MovementPattern.pushHorizontal,
      name: 'Push-up',
      sets: 2,
      targetRange: (6, 10),
      rirTarget: Rir.rir2,
      persistLoadOnCompletion: true,
    );

    await controller.completeSession(
      planFor(exercise),
      completedSets(exercise, count: 1, value: 8),
      durationMinutes: 10,
      endedEarly: true,
    );

    final state = await persistedState(controller, oldState.trackKey);
    expect(state.ladderStepIndex, 0);
    expect(state.currentLoad, 40);
    expect(state.status, ExerciseStatus.progress);
    expect(state.lastTrainedDate, controller.today());
    expect(const ProgressionEngine().ladderStepFor(state).name, 'Push-up');
  });

  test('zero-work detraining attempt leaves the comeback adjustment due',
      () async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final originalDate =
        controller.today().subtract(const Duration(days: 25));
    final oldState = ExerciseState(
      trackKey: MovementPattern.hinge.name,
      pattern: MovementPattern.hinge,
      ladderStepIndex: 3,
      currentLoad: 100,
      lastTrainedDate: originalDate,
    );
    controller.exerciseStates = {oldState.trackKey: oldState};
    const exercise = PlannedExercise(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      name: 'DB RDL',
      sets: 2,
      targetRange: (6, 10),
      loadTotal: 80,
      rirTarget: Rir.rir2,
      persistLoadOnCompletion: true,
    );

    await controller.completeSession(
      planFor(exercise),
      completedSets(exercise, count: 2, value: 0),
      durationMinutes: 5,
      endedEarly: true,
    );

    final state = await persistedState(controller, oldState.trackKey);
    expect(state.ladderStepIndex, 3);
    expect(state.currentLoad, 100);
    expect(state.lastTrainedDate, originalDate);
  });

  for (final readiness in const [
    ('YELLOW', 80.0, Rir.rir2),
    ('RED', 48.0, Rir.rir4plus),
  ]) {
    test(
        '${readiness.$1} comeback persists its emitted baseline without progression',
        () async {
      final controller = AppController(Repository(_MemoryDatabase()));
      final oldState = ExerciseState(
        trackKey: MovementPattern.hinge.name,
        pattern: MovementPattern.hinge,
        ladderStepIndex: 3,
        currentLoad: 100,
        status: ExerciseStatus.hold,
        lastTrainedDate:
            controller.today().subtract(const Duration(days: 25)),
      );
      controller.exerciseStates = {oldState.trackKey: oldState};
      final exercise = PlannedExercise(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        name: 'DB RDL',
        sets: 2,
        targetRange: const (6, 10),
        loadTotal: readiness.$2,
        rirTarget: readiness.$3,
        persistLoadOnCompletion: true,
        progressionEligible: false,
      );

      await controller.completeSession(
        planFor(exercise),
        completedSets(
          exercise,
          count: 2,
          value: 10,
          rir: Rir.rir3plus,
        ),
        durationMinutes: 20,
      );

      final state = await persistedState(controller, oldState.trackKey);
      expect(state.ladderStepIndex, 2);
      expect(state.currentLoad, readiness.$2);
      expect(state.status, ExerciseStatus.progress);
      expect(state.lastTrainedDate, controller.today());
    });
  }

  test('pain and travel work cannot persist a detraining baseline', () async {
    Future<ExerciseState> guardedAttempt({
      bool painFrozen = false,
      bool painFlag = false,
      bool travel = false,
    }) async {
      final controller = AppController(Repository(_MemoryDatabase()));
      final state = ExerciseState(
        trackKey: MovementPattern.hinge.name,
        pattern: MovementPattern.hinge,
        ladderStepIndex: 3,
        currentLoad: 100,
        lastTrainedDate:
            controller.today().subtract(const Duration(days: 25)),
        painFrozen: painFrozen,
        painSeverity: painFrozen ? PainSeverity.sharp : null,
        painRegion: painFrozen ? BodyRegion.lowerBack : null,
        painFlaggedDate: painFrozen ? controller.today() : null,
      );
      controller.exerciseStates = {state.trackKey: state};
      final exercise = PlannedExercise(
        trackKey: state.trackKey,
        pattern: state.pattern,
        name: 'DB RDL',
        sets: 2,
        targetRange: const (6, 10),
        loadTotal: 80,
        rirTarget: Rir.rir2,
        persistLoadOnCompletion: true,
        isTravel: travel,
      );
      final plan = SessionPlan(
        sessionId: SessionTypeId.s1,
        sessionName: 'Guarded comeback',
        tier: SessionTier.full,
        exercises: [exercise],
        estimatedDurationMin: 20,
        travelMode: travel,
      );

      await controller.completeSession(
        plan,
        completedSets(
          exercise,
          count: 2,
          value: 8,
          painFlag: painFlag,
        ),
        durationMinutes: 20,
      );
      return persistedState(controller, state.trackKey);
    }

    final guarded = <String, ExerciseState>{
      'pain frozen': await guardedAttempt(painFrozen: true),
      'pain event': await guardedAttempt(painFlag: true),
      'travel': await guardedAttempt(travel: true),
    };
    for (final entry in guarded.entries) {
      expect(entry.value.ladderStepIndex, 3, reason: entry.key);
      expect(entry.value.currentLoad, 100, reason: entry.key);
    }
  });

  test('a named accessory never overwrites the underlying pattern ladder',
      () async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final oldState = ExerciseState(
      trackKey: dbCurl.trackKey,
      pattern: dbCurl.pattern,
      ladderStepIndex: 4,
      currentLoad: 24,
      lastTrainedDate: controller.today().subtract(const Duration(days: 25)),
    );
    controller.exerciseStates = {oldState.trackKey: oldState};
    final exercise = PlannedExercise(
      trackKey: dbCurl.trackKey,
      pattern: dbCurl.pattern,
      name: dbCurl.name,
      sets: 2,
      targetRange: const (8, 15),
      loadTotal: 18,
      rirTarget: Rir.rir2,
      persistLoadOnCompletion: true,
    );

    await controller.completeSession(
      planFor(exercise),
      completedSets(exercise, count: 2, value: 12),
      durationMinutes: 20,
    );

    final state = await persistedState(controller, oldState.trackKey);
    expect(state.ladderStepIndex, 4);
    expect(state.currentLoad, 18);
    expect(const ProgressionEngine().ladderStepFor(state).name, dbCurl.name);
  });

  test('top-set progression starts from the emitted easier bodyweight step',
      () async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final oldState = ExerciseState(
      trackKey: MovementPattern.pushHorizontal.name,
      pattern: MovementPattern.pushHorizontal,
      ladderStepIndex: 1,
      currentLoad: 40,
      microStepStage: 3,
      lastTrainedDate: controller.today().subtract(const Duration(days: 25)),
    );
    controller.exerciseStates = {oldState.trackKey: oldState};
    const exercise = PlannedExercise(
      trackKey: 'pushHorizontal',
      pattern: MovementPattern.pushHorizontal,
      name: 'Push-up',
      sets: 2,
      targetRange: (6, 10),
      rirTarget: Rir.rir2,
      persistLoadOnCompletion: true,
    );

    await controller.completeSession(
      planFor(exercise),
      completedSets(exercise, count: 2, value: 10),
      durationMinutes: 20,
    );

    final state = await persistedState(controller, oldState.trackKey);
    expect(state.ladderStepIndex, 1);
    expect(state.microStepStage, 0);
    expect(state.awaitingUndershootCheck, isTrue);
    expect(state.currentLoad, lessThan(40));
    expect(
      const ProgressionEngine().ladderStepFor(state).name,
      'DB bench on bolster',
    );
  });

  test('an arbitrary exercise name cannot seed or evaluate a built-in ladder',
      () async {
    final controller = AppController(Repository(_MemoryDatabase()));
    final oldState = ExerciseState(
      trackKey: MovementPattern.hinge.name,
      pattern: MovementPattern.hinge,
      ladderStepIndex: 3,
      currentLoad: 100,
      lastTrainedDate: controller.today().subtract(const Duration(days: 25)),
    );
    controller.exerciseStates = {oldState.trackKey: oldState};
    const exercise = PlannedExercise(
      trackKey: 'hinge',
      pattern: MovementPattern.hinge,
      name: 'Imported custom hinge',
      sets: 2,
      targetRange: (6, 10),
      loadTotal: 60,
      rirTarget: Rir.rir2,
      persistLoadOnCompletion: true,
    );

    await controller.completeSession(
      planFor(exercise),
      completedSets(exercise, count: 2, value: 8),
      durationMinutes: 20,
    );

    final state = await persistedState(controller, oldState.trackKey);
    expect(state.ladderStepIndex, 3);
    expect(state.currentLoad, 100);
    expect(state.lastTrainedDate, controller.today());
  });

  for (final readiness in const [('YELLOW', 2), ('RED', 1)]) {
    test('${readiness.$1} completed deload work consumes one lifecycle touch',
        () async {
      final controller = AppController(Repository(_MemoryDatabase()));
      final state = ExerciseState(
        trackKey: MovementPattern.hinge.name,
        pattern: MovementPattern.hinge,
        currentLoad: 100,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 2,
        preDeloadLoad: 100,
      );
      controller.exerciseStates = {state.trackKey: state};
      final exercise = PlannedExercise(
        trackKey: state.trackKey,
        pattern: state.pattern,
        name: 'DB RDL',
        sets: readiness.$2,
        targetRange: const (6, 10),
        loadTotal: 60,
        rirTarget: Rir.rir4plus,
        progressionEligible: false,
      );

      await controller.completeSession(
        planFor(exercise),
        completedSets(
          exercise,
          count: exercise.sets,
          value: 8,
          rir: Rir.rir4plus,
        ),
        durationMinutes: 20,
      );

      final updated = await persistedState(controller, state.trackKey);
      expect(updated.status, ExerciseStatus.deload);
      expect(updated.deloadSessionsRemaining, 1);
      expect(updated.lastTrainedDate, controller.today());
    });
  }

  test('partial, incomplete, pain, and travel work cannot consume a deload touch',
      () async {
    Future<ExerciseState> runAttempt({
      int completedCount = 2,
      int value = 8,
      bool painFrozen = false,
      bool painFlag = false,
      bool travel = false,
    }) async {
      final controller = AppController(Repository(_MemoryDatabase()));
      final state = ExerciseState(
        trackKey: MovementPattern.hinge.name,
        pattern: MovementPattern.hinge,
        currentLoad: 100,
        status: ExerciseStatus.deload,
        deloadSessionsRemaining: 2,
        preDeloadLoad: 100,
        painFrozen: painFrozen,
        painSeverity: painFrozen ? PainSeverity.sharp : null,
        painRegion: painFrozen ? BodyRegion.lowerBack : null,
        painFlaggedDate: painFrozen ? controller.today() : null,
      );
      controller.exerciseStates = {state.trackKey: state};
      final exercise = PlannedExercise(
        trackKey: state.trackKey,
        pattern: state.pattern,
        name: travel ? 'Travel hip hinge' : 'DB RDL',
        sets: 2,
        targetRange: const (6, 10),
        loadTotal: travel ? null : 60,
        rirTarget: Rir.rir4plus,
        progressionEligible: false,
        isTravel: travel,
      );
      final plan = SessionPlan(
        sessionId: SessionTypeId.s1,
        sessionName: 'Protected deload attempt',
        tier: SessionTier.full,
        exercises: [exercise],
        estimatedDurationMin: 20,
        travelMode: travel,
      );

      await controller.completeSession(
        plan,
        completedSets(
          exercise,
          count: completedCount,
          value: value,
          rir: Rir.rir4plus,
          painFlag: painFlag,
        ),
        durationMinutes: 20,
        endedEarly: completedCount < exercise.sets || value <= 0,
      );

      return persistedState(controller, state.trackKey);
    }

    final protected = <String, ExerciseState>{
      'partial': await runAttempt(completedCount: 1),
      'incomplete': await runAttempt(value: 0),
      'pain frozen': await runAttempt(painFrozen: true),
      'pain event': await runAttempt(painFlag: true),
      'travel': await runAttempt(travel: true),
    };
    for (final entry in protected.entries) {
      expect(
        entry.value.deloadSessionsRemaining,
        2,
        reason: entry.key,
      );
    }
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
    _rows.putIfAbsent(table, () => {})[key] =
        Map<String, dynamic>.from(json);
  }

  @override
  Future<void> putJsonWithDate(
    String table,
    String key,
    DateTime date,
    Map<String, dynamic> json,
  ) async {
    _rows.putIfAbsent(table, () => {})[key] =
        Map<String, dynamic>.from(json);
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
      _rows[table]
          ?.values
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
    rows.sort(
      (a, b) => (a[dateColumn]?.toString() ?? '')
          .compareTo(b[dateColumn]?.toString() ?? ''),
    );
    return rows;
  }
}
