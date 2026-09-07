import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/models/recovery_program.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/engine/recovery_program_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recovery check persists resolved symptoms and blocks saved prescriptions', () async {
    final controller = _SettingsController(Repository(_SettingsMemoryDatabase()));
    await controller.activateLowerBackRecovery(symptomOnsetDate: controller.today(), confirmedNoRedFlags: true);
    await controller.recordRecoveryObservation(RecoveryObservation(date: DateTime.now(),
      pain: 1, sittingMinutes: 30, function: RecoveryFunction.better));
    final plan = const RecoveryProgramEngine().plan(controller.lowerBackRecovery.program,
      date: controller.today(), minutes: 20, alternative: false, pain: []);
    expect(plan, isNotNull);
    expect(controller.isPlanUsableNow(plan), isTrue);
    await controller.recordRecoveryObservation(RecoveryObservation(date: DateTime.now(),
      pain: 1, sittingMinutes: 30, function: RecoveryFunction.unchanged,
      symptoms: {PainTag.tingling}));
    expect(controller.isPlanUsableNow(plan), isFalse);
    final restored = await controller.repo.loadSettings();
    expect(restored.lowerBackRecovery.program.reviewRequired, isTrue);
    expect(controller.stationaryBikePaused, isTrue);
    await expectLater(controller.deactivateLowerBackRecovery(), throwsStateError);
  });

  test('bike and deadlift preferences invalidate saved work immediately', () async {
    final controller = _SettingsController(Repository(_SettingsMemoryDatabase()));
    const bike = SessionPlan(sessionId: SessionTypeId.s6, sessionName: 'Zone 2',
      tier: SessionTier.full, exercises: [], estimatedDurationMin: 60);
    await controller.saveSettings(controller.settings.copyWith(stationaryBikePaused: true, deadliftAlternative: true));
    expect(controller.isPlanUsableNow(bike), isFalse);
    final restored = await controller.repo.loadSettings();
    expect(restored.stationaryBikePaused, isTrue);
    expect(restored.deadliftAlternative, isTrue);
    expect(controller.isHighIntensityUsableNow(), isFalse);
  });

  test('explicit recovery exit preserves the reviewed load, never the old deadlift', () async {
    final controller = _SettingsController(Repository(_SettingsMemoryDatabase()))
      ..exerciseStates = {'hinge': ExerciseState(trackKey: 'hinge',
        pattern: MovementPattern.hinge, currentLoad: 90, ladderStepIndex: 2)};
    await controller.activateLowerBackRecovery(symptomOnsetDate: controller.today(), confirmedNoRedFlags: true);
    await controller.updateRecoveryProgram(RecoveryProgram(
      phase: RecoveryPhase.returnToTraining, assessedAt: DateTime.now(),
      toleratedExposures: 2, selected: {RecoveryExercise.deadlift},
      doses: {RecoveryExercise.deadlift: const RecoveryDose(load: 12, rangePercent: 100)},
      observations: [RecoveryObservation(date: DateTime.now(), pain: 0, sittingMinutes: 60,
        function: RecoveryFunction.better)],
    ));
    await controller.deactivateLowerBackRecovery();
    expect(controller.lowerBackRecovery.active, isFalse);
    expect(controller.exerciseStates['hinge']!.currentLoad, 12);
    expect(controller.exerciseStates['hinge']!.ladderStepIndex, 0);
    expect(controller.lowerBackRecovery.preRecoveryHingeLoad, 90);
    expect(controller.stationaryBikePaused, isTrue);
  });

  test('controller persists explicitly cleared optional settings', () async {
    final db = _SettingsMemoryDatabase();
    final repository = Repository(db);
    final controller = _SettingsController(repository);

    await controller.saveSettings(
      controller.settings.copyWith(
        age: 40,
        hrMaxOverride: 190,
        anthropicApiKey: 'secret',
      ),
    );
    await controller.saveSettings(
      controller.settings.copyWith(
        age: 50,
        clearHrMaxOverride: true,
        clearAnthropicApiKey: true,
      ),
    );
    expect(controller.settings.hrMaxOverride, isNull);
    expect(controller.settings.hrMax, 208 - 0.7 * 50);
    expect(controller.settings.anthropicApiKey, isNull);
    expect(db.settingsWrites, greaterThanOrEqualTo(2));

    final restored = await repository.loadSettings();
    expect(restored.age, 50);
    expect(restored.hrMaxOverride, isNull);
    expect(restored.hrMax, 208 - 0.7 * 50);
    expect(restored.anthropicApiKey, isNull);
  });

  test('ordinary settings saves cannot overwrite recovery lifecycle state',
      () async {
    final db = _SettingsMemoryDatabase();
    final repository = Repository(db);
    final controller = _SettingsController(repository)
      ..exerciseStates = {
        MovementPattern.hinge.name: ExerciseState(
          trackKey: MovementPattern.hinge.name,
          pattern: MovementPattern.hinge,
          currentLoad: 90,
          ladderStepIndex: 2,
        ),
      };
    final staleDraft = controller.settings;

    await controller.activateLowerBackRecovery(
      symptomOnsetDate: DateTime.now().subtract(const Duration(days: 21)),
      confirmedNoRedFlags: true,
    );
    await controller.saveSettings(staleDraft.copyWith(age: 40));

    expect(controller.lowerBackRecovery.active, isTrue);
    expect(controller.lowerBackRecovery.preRecoveryHingeLoad, 90);
    expect((await repository.loadSettings()).lowerBackRecovery.active, isTrue);
  });

  test('controller refuses activation without the red-flag confirmation',
      () async {
    final controller = _SettingsController(
      Repository(_SettingsMemoryDatabase()),
    );
    await expectLater(
      controller.activateLowerBackRecovery(
        symptomOnsetDate: DateTime.now(),
        confirmedNoRedFlags: false,
      ),
      throwsStateError,
    );
    expect(controller.lowerBackRecovery.active, isFalse);
  });
}

class _SettingsController extends AppController {
  _SettingsController(super.repository);

  @override
  Future<void> syncNotifications() async {}
}

class _SettingsMemoryDatabase extends AppDatabase {
  Map<String, dynamic>? _settings;
  int settingsWrites = 0;

  @override
  Future<void> putJson(
    String table,
    String keyColumn,
    String key,
    Map<String, dynamic> json,
  ) async {
    if (table == 'meta' && key == 'settings') {
      _settings = Map<String, dynamic>.from(json);
      settingsWrites += 1;
    }
  }

  @override
  Future<Map<String, dynamic>?> getJson(
    String table,
    String keyColumn,
    String key,
  ) async {
    if (table != 'meta' || key != 'settings' || _settings == null) return null;
    return Map<String, dynamic>.from(_settings!);
  }
}
