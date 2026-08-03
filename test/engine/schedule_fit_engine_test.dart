import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/schedule_fit_engine.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_timing.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  const engine = ScheduleFitEngine();

  SessionLog sessionAt(DateTime startedAt, {int elapsedSeconds = 1800}) =>
      SessionLog(
        id: 'log-${startedAt.toIso8601String()}',
        templateId: SessionTypeId.s1,
        tier: SessionTier.full,
        date: DateTime(startedAt.year, startedAt.month, startedAt.day),
        completedAt: startedAt.add(Duration(seconds: elapsedSeconds)),
        setLogs: const [],
        plannedWorkSets: 6,
        completedWorkSets: 6,
        durationMinutes: elapsedSeconds ~/ 60,
        timings: SessionTimings(
          startedAt: startedAt,
          elapsedSeconds: elapsedSeconds,
          plannedDurationMinutes: 30,
        ),
        countsAs: const {FloorCategory.strength},
      );

  /// A row with only a calendar date — its hour is genuinely unknown.
  SessionLog dateOnlySession(DateTime day) => SessionLog(
        id: 'legacy-${day.toIso8601String()}',
        templateId: SessionTypeId.s1,
        tier: SessionTier.full,
        date: day,
        setLogs: const [],
        plannedWorkSets: 6,
        completedWorkSets: 6,
        durationMinutes: 30,
        countsAs: const {FloorCategory.strength},
      );

  group('habits', () {
    // 2026-08-03 is a Monday.
    final asOf = DateTime(2026, 8, 3, 12);

    test('learns a per-weekday start time from history', () {
      final habits = engine.buildHabits(
        asOf: asOf,
        windowDays: 28,
        logs: [
          sessionAt(DateTime(2026, 7, 20, 6, 30)), // Monday
          sessionAt(DateTime(2026, 7, 27, 7, 30)), // Monday
          sessionAt(DateTime(2026, 7, 23, 18, 0)), // Thursday
        ],
      );

      final monday = habits.habitFor(DateTime.monday)!;
      expect(monday.startSampleCount, 2);
      expect(monday.medianStartMinuteOfDay, 7 * 60);
      expect(monday.trainedDays, 2);
      expect(monday.observedDays, 4);
      expect(monday.trainedRatio, 0.5);

      final thursday = habits.habitFor(DateTime.thursday)!;
      expect(thursday.medianStartMinuteOfDay, 18 * 60);
      expect(habits.startSampleCount, 3);
    });

    test('a date-only row counts as a training day but has no start time', () {
      final habits = engine.buildHabits(
        asOf: asOf,
        windowDays: 28,
        logs: [dateOnlySession(DateTime(2026, 7, 27))],
      );
      final monday = habits.habitFor(DateTime.monday)!;
      expect(monday.trainedDays, 1);
      expect(monday.startSampleCount, 0);
      expect(monday.medianStartMinuteOfDay, isNull);
      expect(habits.medianStartMinuteOfDay, isNull);
    });

    test('history outside the window does not shape the habit', () {
      final habits = engine.buildHabits(
        asOf: asOf,
        windowDays: 7,
        logs: [sessionAt(DateTime(2026, 6, 1, 5, 0))],
      );
      expect(habits.startSampleCount, 0);
    });
  });

  group('slot suggestion', () {
    ScheduleHabits habitsFrom(List<SessionLog> logs, DateTime asOf) =>
        engine.buildHabits(logs: logs, asOf: asOf, windowDays: 28);

    test('uses this weekday own median when there is enough of it', () {
      final now = DateTime(2026, 8, 3, 9); // Monday morning
      final slot = engine.suggestSlot(
        habits: habitsFrom([
          sessionAt(DateTime(2026, 7, 20, 17, 0)),
          sessionAt(DateTime(2026, 7, 27, 17, 30)),
          sessionAt(DateTime(2026, 7, 21, 6, 0)),
        ], now),
        nowLocal: now,
      );
      expect(slot, isNotNull);
      expect(slot!.source, ScheduleSlotSource.weekdayHabit);
      expect(slot.at, DateTime(2026, 8, 3, 17, 15));
      expect(slot.sampleCount, 2);
    });

    test('falls back to the overall median with one same-weekday sample', () {
      final now = DateTime(2026, 8, 3, 9);
      final slot = engine.suggestSlot(
        habits: habitsFrom([
          sessionAt(DateTime(2026, 7, 27, 6, 0)), // single Monday
          sessionAt(DateTime(2026, 7, 21, 16, 0)),
          sessionAt(DateTime(2026, 7, 22, 16, 0)),
          sessionAt(DateTime(2026, 7, 23, 16, 0)),
        ], now),
        nowLocal: now,
      );
      expect(slot!.source, ScheduleSlotSource.overallHabit);
      expect(slot.at, DateTime(2026, 8, 3, 16));
    });

    test('with no usable history it uses the caller fallback', () {
      final now = DateTime(2026, 8, 3, 9);
      final slot = engine.suggestSlot(
        habits: habitsFrom(const [], now),
        nowLocal: now,
      );
      expect(slot!.source, ScheduleSlotSource.fallback);
      expect(slot.sampleCount, 0);
      expect(slot.at, DateTime(2026, 8, 3, 17));
    });

    test('a habitual slot already past today moves to the next quarter hour',
        () {
      final now = DateTime(2026, 8, 3, 14, 7);
      final slot = engine.suggestSlot(
        habits: habitsFrom([
          sessionAt(DateTime(2026, 7, 20, 7, 0)),
          sessionAt(DateTime(2026, 7, 27, 7, 0)),
        ], now),
        nowLocal: now,
        leadMinutes: 45,
      );
      // 14:07 + 45 min = 14:52, rounded up to 15:00.
      expect(slot!.at, DateTime(2026, 8, 3, 15));
    });

    test('a slot that cannot fit before the cutoff returns null', () {
      final now = DateTime(2026, 8, 3, 19, 40);
      final slot = engine.suggestSlot(
        habits: habitsFrom(const [], now),
        nowLocal: now,
        leadMinutes: 45,
        latestHour: 20,
      );
      expect(slot, isNull);
    });

    test('an early-morning habit is pushed to the earliest allowed hour', () {
      final now = DateTime(2026, 8, 3, 5, 0);
      final slot = engine.suggestSlot(
        habits: habitsFrom([
          sessionAt(DateTime(2026, 7, 20, 6, 0)),
          sessionAt(DateTime(2026, 7, 27, 6, 0)),
        ], now),
        nowLocal: now,
        leadMinutes: 30,
        earliestHour: 8,
      );
      expect(slot!.at, DateTime(2026, 8, 3, 8));
    });

    test('lead time is always respected', () {
      final now = DateTime(2026, 8, 3, 16, 50);
      final slot = engine.suggestSlot(
        habits: habitsFrom(const [], now),
        nowLocal: now,
        leadMinutes: 45,
      );
      expect(slot!.at.isAfter(now.add(const Duration(minutes: 44))), isTrue);
    });
  });
}
