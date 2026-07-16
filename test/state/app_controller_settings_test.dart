import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
