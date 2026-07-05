import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/floor_engine.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  const engine = FloorEngine();
  final today = DateTime(2026, 1, 20);

  SessionLog logOn(DateTime date, {FloorCategory category = FloorCategory.strength}) => SessionLog(
        id: date.toIso8601String(),
        templateId: SessionTypeId.s1,
        tier: SessionTier.full,
        date: date,
        setLogs: const [],
        plannedWorkSets: 6,
        completedWorkSets: 6,
        durationMinutes: 30,
        countsAs: {category},
      );

  test('deficit <= 0 -> no pressure', () {
    final logs = [logOn(today.subtract(const Duration(days: 1))), logOn(today.subtract(const Duration(days: 3)))];
    final result = engine.pressureFor(category: FloorCategory.strength, logs: logs, requirement: 2, today: today);
    expect(result.level, FloorPressureLevel.none);
  });

  test('deficit >= 2 -> hard force', () {
    final result = engine.pressureFor(category: FloorCategory.strength, logs: const [], requirement: 2, today: today);
    expect(result.level, FloorPressureLevel.hard);
    expect(result.deficit, 2);
  });

  group('§13: deficit == 1 aging-out horizon', () {
    test('fires hard when the single logged session drops out of the window within 2 days', () {
      // Logged 6 days ago -> drops out on day+7 = today+1 -> within 2 days.
      final logs = [logOn(today.subtract(const Duration(days: 6)))];
      final result = engine.pressureFor(category: FloorCategory.strength, logs: logs, requirement: 2, today: today);
      expect(result.level, FloorPressureLevel.hard);
    });

    test('stays soft when the single logged session ages out later than 2 days from now', () {
      // Logged 1 day ago -> drops out on day+7 = today+6 -> not within 2 days.
      final logs = [logOn(today.subtract(const Duration(days: 1)))];
      final result = engine.pressureFor(category: FloorCategory.strength, logs: logs, requirement: 2, today: today);
      expect(result.level, FloorPressureLevel.soft);
    });

    test('deficit==1 with zero logs (requirement 1) is a hard force ("or none exists")', () {
      final result = engine.pressureFor(category: FloorCategory.intensity, logs: const [], requirement: 1, today: today);
      expect(result.level, FloorPressureLevel.hard);
    });
  });
}
