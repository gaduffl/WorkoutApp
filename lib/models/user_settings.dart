import 'equipment.dart';
import 'floor_category.dart';
import 'oura_connection.dart';

enum Units { lb, kg }

enum AppLanguage { en, de }

/// §2.4 User entity + §2.2 weekly floor config + §10 Oura/AI settings.
class UserSettings {
  final EquipmentConfig equipment;
  final Map<FloorCategory, int> weeklyFloor;
  final Units units;
  final Units storageUnit; // equipment's native unit; storage stays lb per §2.5
  final AppLanguage language;
  final int age;
  final double? hrMaxOverride;
  final OuraConnection oura;
  final String? anthropicApiKey;
  final String aiTone;
  final String wakeWindow; // e.g. "07:00"
  final int checkInCutoffHour; // §12 default 10

  const UserSettings({
    this.equipment = const EquipmentConfig(),
    this.weeklyFloor = const {FloorCategory.strength: 2, FloorCategory.intensity: 1},
    this.units = Units.lb,
    this.storageUnit = Units.lb,
    this.language = AppLanguage.en,
    this.age = 35,
    this.hrMaxOverride,
    this.oura = const OuraConnection(),
    this.anthropicApiKey,
    this.aiTone = 'direct, encouraging, no fluff',
    this.wakeWindow = '07:00',
    this.checkInCutoffHour = 10,
  });

  /// §2.5: HRmax default = 208 - 0.7 x age; user-overridable.
  double get hrMax => hrMaxOverride ?? (208 - 0.7 * age);

  UserSettings copyWith({
    EquipmentConfig? equipment,
    Map<FloorCategory, int>? weeklyFloor,
    Units? units,
    AppLanguage? language,
    int? age,
    double? hrMaxOverride,
    OuraConnection? oura,
    String? anthropicApiKey,
    String? aiTone,
    String? wakeWindow,
    int? checkInCutoffHour,
  }) {
    return UserSettings(
      equipment: equipment ?? this.equipment,
      weeklyFloor: weeklyFloor ?? this.weeklyFloor,
      units: units ?? this.units,
      storageUnit: storageUnit,
      language: language ?? this.language,
      age: age ?? this.age,
      hrMaxOverride: hrMaxOverride ?? this.hrMaxOverride,
      oura: oura ?? this.oura,
      anthropicApiKey: anthropicApiKey ?? this.anthropicApiKey,
      aiTone: aiTone ?? this.aiTone,
      wakeWindow: wakeWindow ?? this.wakeWindow,
      checkInCutoffHour: checkInCutoffHour ?? this.checkInCutoffHour,
    );
  }
}
