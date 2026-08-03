import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/models/analytics_event.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_timing.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/user_settings.dart';

/// Round-trips through real JSON text, so a value that only survives because
/// it stayed an in-memory object cannot pass.
Map<String, dynamic> _wire(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  test('set timing survives a JSON round trip', () {
    final original = SetLog(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      exerciseName: 'Goblet Squat',
      weight: 40,
      value: 8,
      metric: ExerciseMetric.reps,
      rir: Rir.rir2,
      startedAt: DateTime(2026, 8, 3, 7, 30),
      plannedRestSecondsBefore: 90,
      timestamp: DateTime(2026, 8, 3, 7, 32, 20),
    );
    final restored = setLogFromJson(_wire(setLogToJson(original)));

    expect(restored.startedAt, original.startedAt);
    expect(restored.plannedRestSecondsBefore, 90);
    expect(restored.cycleSeconds, 140);
    expect(restored.restSeconds, 90);
    expect(restored.activeSecondsEstimate, 50);
  });

  test('a set written before timing existed loads with null timing', () {
    final legacy = {
      'trackKey': 'squat',
      'pattern': 'squat',
      'exerciseName': 'Goblet Squat',
      'weight': 40,
      'metric': 'reps',
      'value': 8,
      'reps': 8,
      'rir': 'rir2',
      'painFlag': false,
      'isWarmup': false,
      'timestamp': '2026-08-03T07:32:20.000',
    };
    final restored = setLogFromJson(legacy);
    expect(restored.startedAt, isNull);
    expect(restored.plannedRestSecondsBefore, isNull);
    expect(restored.cycleSeconds, isNull);
  });

  test('session timings survive a JSON round trip', () {
    final original = SessionLog(
      id: 'log-1',
      templateId: SessionTypeId.s1,
      tier: SessionTier.full,
      date: DateTime(2026, 8, 3),
      completedAt: DateTime(2026, 8, 3, 7, 42),
      setLogs: const [],
      plannedWorkSets: 6,
      completedWorkSets: 6,
      durationMinutes: 42,
      timings: SessionTimings(
        startedAt: DateTime(2026, 8, 3, 7),
        elapsedSeconds: 2520,
        plannedDurationMinutes: 35,
      ),
      countsAs: const {FloorCategory.strength},
    );
    final restored = sessionLogFromJson(_wire(sessionLogToJson(original)));

    expect(restored.timings!.startedAt, DateTime(2026, 8, 3, 7));
    expect(restored.timings!.elapsedSeconds, 2520);
    expect(restored.timings!.plannedDurationMinutes, 35);
    expect(restored.hasExactElapsedSeconds, isTrue);
    expect(restored.elapsedSecondsOrEstimate, 2520);
    expect(restored.startedAtOrNull, DateTime(2026, 8, 3, 7));
  });

  test('a legacy session reconstructs its start from exact completion', () {
    final log = SessionLog(
      id: 'log-2',
      templateId: SessionTypeId.s1,
      tier: SessionTier.full,
      date: DateTime(2026, 8, 3),
      completedAt: DateTime(2026, 8, 3, 7, 40),
      setLogs: const [],
      plannedWorkSets: 6,
      completedWorkSets: 6,
      durationMinutes: 40,
      countsAs: const {FloorCategory.strength},
    );
    final restored = sessionLogFromJson(_wire(sessionLogToJson(log)));
    expect(restored.timings, isNull);
    expect(restored.hasExactElapsedSeconds, isFalse);
    expect(restored.startedAtOrNull, DateTime(2026, 8, 3, 7));
  });

  test('a date-only session refuses to invent a start time', () {
    final log = SessionLog(
      id: 'log-3',
      templateId: SessionTypeId.s1,
      tier: SessionTier.full,
      date: DateTime(2026, 8, 3),
      setLogs: const [],
      plannedWorkSets: 6,
      completedWorkSets: 6,
      durationMinutes: 40,
      countsAs: const {FloorCategory.strength},
    );
    expect(log.completedAtPrecision, CompletionTimePrecision.dateOnlyInferred);
    expect(log.startedAtOrNull, isNull);
  });

  test('analytics events survive a JSON round trip', () {
    final original = AnalyticsEvent(
      id: 'event-1',
      type: AnalyticsEventType.rehitSuggested,
      timestamp: DateTime(2026, 8, 3, 12, 30),
      properties: const {'slotSource': 'weekdayHabit', 'checkInMissing': 'false'},
    );
    final restored = analyticsEventFromJson(_wire(analyticsEventToJson(original)))!;

    expect(restored.id, 'event-1');
    expect(restored.type, AnalyticsEventType.rehitSuggested);
    expect(restored.timestamp, DateTime(2026, 8, 3, 12, 30));
    expect(restored.date, DateTime(2026, 8, 3));
    expect(restored.properties['slotSource'], 'weekdayHabit');
  });

  test('an event type this build does not know is dropped, not thrown', () {
    expect(
      analyticsEventFromJson({
        'id': 'x',
        'type': 'somethingFromTheFuture',
        'timestamp': '2026-08-03T12:00:00.000',
      }),
      isNull,
    );
    expect(
      analyticsEventFromJson({
        'id': 'x',
        'type': 'checkInSubmitted',
        'timestamp': 'not a timestamp',
      }),
      isNull,
    );
  });

  test('rest-day nudge settings round-trip and default off', () {
    const original = UserSettings(
      restDayRehitNudgeEnabled: true,
      restDayRehitNudgeScheduledDay: '2026-08-03',
      restDayRehitNudgeEarliestHour: 9,
      restDayRehitNudgeLatestHour: 19,
    );
    final restored = userSettingsFromJson(_wire(userSettingsToJson(original)));

    expect(restored.restDayRehitNudgeEnabled, isTrue);
    expect(restored.restDayRehitNudgeScheduledDay, '2026-08-03');
    expect(restored.restDayRehitNudgeEarliestHour, 9);
    expect(restored.restDayRehitNudgeLatestHour, 19);

    final legacy = _wire(userSettingsToJson(const UserSettings()))
      ..remove('restDayRehitNudgeEnabled')
      ..remove('restDayRehitNudgeEarliestHour')
      ..remove('restDayRehitNudgeLatestHour');
    final fromLegacy = userSettingsFromJson(legacy);
    expect(fromLegacy.restDayRehitNudgeEnabled, isFalse);
    expect(fromLegacy.restDayRehitNudgeEarliestHour, 8);
    expect(fromLegacy.restDayRehitNudgeLatestHour, 20);
  });

  test('a corrupt persisted hour is clamped instead of crashing the load', () {
    final json = _wire(userSettingsToJson(const UserSettings()))
      ..['restDayRehitNudgeEarliestHour'] = -4
      ..['restDayRehitNudgeLatestHour'] = 99;
    final restored = userSettingsFromJson(json);
    expect(restored.restDayRehitNudgeEarliestHour, 0);
    expect(restored.restDayRehitNudgeLatestHour, 24);
  });
}
