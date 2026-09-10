import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/user_settings.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy active recovery keeps cycling paused after exit and reload',
    () async {
      final raw =
          userSettingsToJson(
              const UserSettings(
                lowerBackRecovery: LowerBackRecoveryState(active: true),
              ),
            )
            ..remove('stationaryBikePaused')
            ..remove('recoveryBackExtensionsEnabled');
      final controller = _SettingsController(
        Repository(_SettingsMemoryDatabase()),
      )..settings = userSettingsFromJson(raw);
      expect(controller.stationaryBikePaused, isTrue);
      expect(controller.settings.recoveryBackExtensionsEnabled, isFalse);
      await controller.deactivateLowerBackRecovery();
      expect(controller.lowerBackRecovery.active, isFalse);
      expect(
        (await controller.repo.loadSettings()).stationaryBikePaused,
        isTrue,
      );
    },
  );

  test('optional extension completion cannot auto-resume deadlifts', () async {
    final now = DateTime.now();
    final controller =
        _SettingsController(Repository(_SettingsMemoryDatabase()))
          ..settings = UserSettings(
            lowerBackRecovery: LowerBackRecoveryState(
              active: true,
              stage: LowerBackRecoveryStage.dynamicUnloaded,
              targetDynamicReps: 12,
              consecutiveToleratedSessions: 1,
              pendingNextMorningSessionDate: now.subtract(
                const Duration(days: 1),
              ),
              pendingSameDayResponse: LowerBackSymptomResponse.unchanged,
            ),
          );
    await controller.recordLowerBackNextMorningResponse(
      LowerBackSymptomResponse.unchanged,
    );
    expect(controller.lowerBackRecovery.active, isTrue);
    expect(
      controller.lowerBackRecovery.stage,
      LowerBackRecoveryStage.dynamicUnloaded,
    );
  });

  test('recovery options survive serialization and ordinary saves', () async {
    const settings = UserSettings(
      stationaryBikePaused: true,
      deadliftAlternative: true,
      recoveryBackExtensionsEnabled: true,
    );
    final loaded = userSettingsFromJson(userSettingsToJson(settings));
    expect(loaded.stationaryBikePaused, isTrue);
    expect(loaded.deadliftAlternative, isTrue);
    expect(loaded.recoveryBackExtensionsEnabled, isTrue);
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
