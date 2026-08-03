import 'equipment.dart';
import 'floor_category.dart';
import 'onedrive_connection.dart';
import 'oura_connection.dart';

enum Units { lb, kg }

enum AppLanguage { en, de }

/// User settings plus legacy v1 weekly-floor persistence and integrations.
class UserSettings {
  final EquipmentConfig equipment;

  /// Retained only so existing backups/settings round-trip. Decision Engine
  /// v2 uses TrainingTargets and never reads this map.
  final Map<FloorCategory, int> weeklyFloor;
  final Units units;
  final Units storageUnit; // equipment's native unit; storage stays lb per §2.5
  final AppLanguage language;
  final int age;
  final double? hrMaxOverride;
  final OuraConnection oura;
  final OneDriveConnection oneDrive;
  final String? anthropicApiKey;

  /// §9.1: when off, the app always uses the deterministic fallback
  /// templates for the daily "why" text instead of calling the AI layer -
  /// even if an Anthropic API key is configured.
  final bool aiExplanationsEnabled;
  final String aiTone;
  final String wakeWindow; // e.g. "07:00"
  final int checkInCutoffHour; // §12 default 10

  /// §12 travel / no-equipment mode: ladders resolve to bodyweight steps.
  final bool travelMode;

  /// §3.1 wake-window notification + §12 cutoff nudge (opt-in).
  final bool notificationsEnabled;

  /// Opt-in push nudge on days where a second, short REHIT exposure would add
  /// value (§2.1 optional finisher). Independent of [notificationsEnabled] so
  /// the user can take just this reminder, or just the morning ones.
  final bool secondRehitNudgeEnabled;

  /// Internal local-day marker for the optional second-session REHIT nudge.
  /// Persisting it prevents app restarts from scheduling the same nudge twice.
  final String? secondRehitNudgeScheduledDay;

  /// Exact local target paired with [secondRehitNudgeScheduledDay]. Legacy
  /// settings have only the day marker and are treated as already used for
  /// that day rather than risking a duplicate notification.
  final DateTime? secondRehitNudgeScheduledFor;

  /// Opt-in push reminder on days where *nothing* has been trained yet and a
  /// short REHIT would still fit the time the user normally trains. Separate
  /// from [secondRehitNudgeEnabled], which only fires after a first session.
  final bool restDayRehitNudgeEnabled;

  /// Internal local-day / exact-target markers for the rest-day reminder,
  /// mirroring the second-REHIT pair so a restart cannot double-schedule.
  final String? restDayRehitNudgeScheduledDay;
  final DateTime? restDayRehitNudgeScheduledFor;

  /// Earliest and latest local hour a rest-day reminder may be delivered.
  /// The exact minute inside that window comes from observed training times.
  final int restDayRehitNudgeEarliestHour;
  final int restDayRehitNudgeLatestHour;

  const UserSettings({
    this.equipment = const EquipmentConfig(),
    this.weeklyFloor = const {FloorCategory.strength: 2, FloorCategory.intensity: 1},
    this.units = Units.lb,
    this.storageUnit = Units.lb,
    this.language = AppLanguage.en,
    this.age = 35,
    this.hrMaxOverride,
    this.oura = const OuraConnection(),
    this.oneDrive = const OneDriveConnection(),
    this.anthropicApiKey,
    this.aiExplanationsEnabled = true,
    this.aiTone = 'direct, encouraging, no fluff',
    this.wakeWindow = '07:00',
    this.checkInCutoffHour = 10,
    this.travelMode = false,
    this.notificationsEnabled = false,
    this.secondRehitNudgeEnabled = false,
    this.secondRehitNudgeScheduledDay,
    this.secondRehitNudgeScheduledFor,
    this.restDayRehitNudgeEnabled = false,
    this.restDayRehitNudgeScheduledDay,
    this.restDayRehitNudgeScheduledFor,
    this.restDayRehitNudgeEarliestHour = 8,
    this.restDayRehitNudgeLatestHour = 20,
  })  : assert(restDayRehitNudgeEarliestHour >= 0 &&
            restDayRehitNudgeEarliestHour <= 23),
        assert(restDayRehitNudgeLatestHour >= 1 &&
            restDayRehitNudgeLatestHour <= 24);

  /// §2.5: HRmax default = 208 - 0.7 x age; user-overridable.
  double get hrMax => hrMaxOverride ?? (208 - 0.7 * age);

  /// Nullable arguments retain their existing values. The explicit clear
  /// flags distinguish an intentional removal from an omitted update.
  UserSettings copyWith({
    EquipmentConfig? equipment,
    Map<FloorCategory, int>? weeklyFloor,
    Units? units,
    AppLanguage? language,
    int? age,
    double? hrMaxOverride,
    OuraConnection? oura,
    OneDriveConnection? oneDrive,
    String? anthropicApiKey,
    bool? aiExplanationsEnabled,
    String? aiTone,
    String? wakeWindow,
    int? checkInCutoffHour,
    bool? travelMode,
    bool? notificationsEnabled,
    bool? secondRehitNudgeEnabled,
    String? secondRehitNudgeScheduledDay,
    DateTime? secondRehitNudgeScheduledFor,
    bool? restDayRehitNudgeEnabled,
    String? restDayRehitNudgeScheduledDay,
    DateTime? restDayRehitNudgeScheduledFor,
    int? restDayRehitNudgeEarliestHour,
    int? restDayRehitNudgeLatestHour,
    bool clearHrMaxOverride = false,
    bool clearAnthropicApiKey = false,
    bool clearSecondRehitNudgeScheduledDay = false,
    bool clearRestDayRehitNudgeScheduledDay = false,
  }) {
    return UserSettings(
      equipment: equipment ?? this.equipment,
      weeklyFloor: weeklyFloor ?? this.weeklyFloor,
      units: units ?? this.units,
      storageUnit: storageUnit,
      language: language ?? this.language,
      age: age ?? this.age,
      hrMaxOverride:
          clearHrMaxOverride ? null : hrMaxOverride ?? this.hrMaxOverride,
      oura: oura ?? this.oura,
      oneDrive: oneDrive ?? this.oneDrive,
      anthropicApiKey: clearAnthropicApiKey
          ? null
          : anthropicApiKey ?? this.anthropicApiKey,
      aiExplanationsEnabled: aiExplanationsEnabled ?? this.aiExplanationsEnabled,
      aiTone: aiTone ?? this.aiTone,
      wakeWindow: wakeWindow ?? this.wakeWindow,
      checkInCutoffHour: checkInCutoffHour ?? this.checkInCutoffHour,
      travelMode: travelMode ?? this.travelMode,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      secondRehitNudgeEnabled:
          secondRehitNudgeEnabled ?? this.secondRehitNudgeEnabled,
      secondRehitNudgeScheduledDay: clearSecondRehitNudgeScheduledDay
          ? null
          : secondRehitNudgeScheduledDay ?? this.secondRehitNudgeScheduledDay,
      secondRehitNudgeScheduledFor: clearSecondRehitNudgeScheduledDay
          ? null
          : secondRehitNudgeScheduledFor ?? this.secondRehitNudgeScheduledFor,
      restDayRehitNudgeEnabled:
          restDayRehitNudgeEnabled ?? this.restDayRehitNudgeEnabled,
      restDayRehitNudgeScheduledDay: clearRestDayRehitNudgeScheduledDay
          ? null
          : restDayRehitNudgeScheduledDay ?? this.restDayRehitNudgeScheduledDay,
      restDayRehitNudgeScheduledFor: clearRestDayRehitNudgeScheduledDay
          ? null
          : restDayRehitNudgeScheduledFor ?? this.restDayRehitNudgeScheduledFor,
      restDayRehitNudgeEarliestHour:
          restDayRehitNudgeEarliestHour ?? this.restDayRehitNudgeEarliestHour,
      restDayRehitNudgeLatestHour:
          restDayRehitNudgeLatestHour ?? this.restDayRehitNudgeLatestHour,
    );
  }
}
