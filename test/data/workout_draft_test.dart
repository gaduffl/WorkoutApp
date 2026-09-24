import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/workout_draft.dart';

void main() {
  test('unfinished workout round-trips its plan, logged sets and timer deadlines', () async {
    final started = DateTime(2026, 9, 24, 7);
    final stepStarted = started.add(const Duration(minutes: 3));
    final draft = WorkoutDraft(
      plan: const SessionPlan(
        sessionId: SessionTypeId.s1,
        sessionName: 'Lower',
        tier: SessionTier.full,
        exercises: [
          PlannedExercise(
            trackKey: 'squat',
            pattern: MovementPattern.squat,
            name: 'Squat',
            sets: 2,
            targetRange: (6, 10),
            rirTarget: Rir.rir2,
            loadTotal: 40,
          ),
        ],
        estimatedDurationMin: 30,
      ),
      startedAt: started,
      stepStartedAt: stepStarted,
      superset: false,
      current: 1,
      logged: [
        SetLog(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          exerciseName: 'Squat',
          weight: 45,
          value: 10,
          rir: Rir.rir2,
          timestamp: stepStarted,
          startedAt: started,
        ),
      ],
      loggedKeys: const ['0:1'],
      weights: const {0: 45},
      value: 8,
      rir: Rir.rir3plus,
      painFlag: true,
      plannedRestIntoStep: 90,
      restEndsAt: stepStarted.add(const Duration(seconds: 90)),
      holdSecondsLeft: 0,
      holdTargetSeconds: 0,
      holdTimerUsed: false,
      warmupSecondsLeft: 0,
    );

    final restored = workoutDraftFromJson(workoutDraftToJson(draft));
    expect(restored.plan.exercises.single.name, 'Squat');
    expect(restored.logged.single.weight, 45);
    expect(restored.loggedKeys, ['0:1']);
    expect(restored.current, 1);
    expect(restored.weights[0], 45);
    expect(restored.rir, Rir.rir3plus);
    expect(restored.painFlag, isTrue);
    expect(restored.restEndsAt, stepStarted.add(const Duration(seconds: 90)));

    final repository = Repository(_MemoryDatabase());
    expect(await repository.loadWorkoutDraft(), isNull);
    await repository.saveWorkoutDraft(draft);
    final reloaded = await repository.loadWorkoutDraft();
    expect(reloaded!.logged.single.value, 10);
    await repository.deleteWorkoutDraft();
    expect(await repository.loadWorkoutDraft(), isNull);
  });
}

class _MemoryDatabase extends AppDatabase {
  Map<String, dynamic>? draft;

  @override
  Future<Map<String, dynamic>?> getJson(
      String table, String keyColumn, String key) async => draft;

  @override
  Future<void> putJson(String table, String keyColumn, String key,
      Map<String, dynamic> json) async {
    draft = json;
  }

  @override
  Future<void> delete(String table, String keyColumn, String key) async {
    draft = null;
  }
}
