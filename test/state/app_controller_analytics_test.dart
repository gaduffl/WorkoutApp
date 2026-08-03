import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/engine/rest_day_rehit_engine.dart';
import 'package:morningcoach/engine/schedule_fit_engine.dart';
import 'package:morningcoach/models/analytics_event.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_timing.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _AnalyticsController controllerWith(_MemoryDatabase db) =>
      _AnalyticsController(Repository(db));

  SetLog set({
    required DateTime startedAt,
    required int cycleSeconds,
    int plannedRestBefore = 0,
    bool isWarmup = false,
  }) =>
      SetLog(
        trackKey: 'squat',
        pattern: MovementPattern.squat,
        exerciseName: 'Goblet Squat',
        weight: 40,
        value: 8,
        metric: ExerciseMetric.reps,
        rir: Rir.rir2,
        isWarmup: isWarmup,
        startedAt: startedAt,
        plannedRestSecondsBefore: plannedRestBefore,
        timestamp: startedAt.add(Duration(seconds: cycleSeconds)),
      );

  const plan = SessionPlan(
    sessionId: SessionTypeId.s1,
    sessionName: 'Full Body A',
    tier: SessionTier.full,
    exercises: [
      PlannedExercise(
        trackKey: 'squat',
        pattern: MovementPattern.squat,
        name: 'Goblet Squat',
        sets: 2,
        metric: ExerciseMetric.reps,
        targetRange: (8, 12),
        rirTarget: Rir.rir2,
        loadTotal: 40,
      ),
    ],
    estimatedDurationMin: 30,
  );

  test('a completed session persists exact timings and analytics events',
      () async {
    final db = _MemoryDatabase();
    final controller = controllerWith(db);
    final startedAt = DateTime.now().subtract(const Duration(minutes: 41));

    await controller.completeSession(
      plan,
      [
        set(startedAt: startedAt, cycleSeconds: 100),
        set(
          startedAt: startedAt.add(const Duration(seconds: 100)),
          cycleSeconds: 140,
          plannedRestBefore: 90,
        ),
      ],
      durationMinutes: 41,
      startedAt: startedAt,
      elapsedSeconds: 2460,
    );

    final saved = db.sessionLogs.values.map(sessionLogFromJson).single;
    expect(saved.timings!.startedAt, startedAt);
    expect(saved.timings!.elapsedSeconds, 2460);
    expect(saved.timings!.plannedDurationMinutes, 30);
    expect(saved.durationMinutes, 41, reason: 'legacy field is unchanged');

    final events = db.analyticsEvents.values
        .map(analyticsEventFromJson)
        .nonNulls
        .toList();
    expect(
      events.map((event) => event.type),
      contains(AnalyticsEventType.sessionCompleted),
    );
    final completion = events
        .firstWhere((e) => e.type == AnalyticsEventType.sessionCompleted);
    expect(completion.properties['elapsedSeconds'], '2460');
    expect(completion.properties['plannedDurationMin'], '30');
  });

  test('insights read the persisted timings back into real metrics', () async {
    final db = _MemoryDatabase();
    final controller = controllerWith(db);
    final startedAt = DateTime.now().subtract(const Duration(minutes: 41));

    await controller.completeSession(
      plan,
      [
        set(startedAt: startedAt, cycleSeconds: 100),
        set(
          startedAt: startedAt.add(const Duration(seconds: 100)),
          cycleSeconds: 140,
          plannedRestBefore: 90,
        ),
      ],
      durationMinutes: 41,
      startedAt: startedAt,
      elapsedSeconds: 2460,
    );

    final insights = await controller.loadInsights();
    final session = insights.sessions.single;
    expect(session.workSetCount, 2);
    expect(session.timedSetCount, 2);
    expect(session.workRestSeconds, 90);
    expect(session.workActiveSeconds, 150);
    expect(session.estimateErrorSeconds, 2460 - 30 * 60);
    expect(insights.allocation.sessionCount, 1);
  });

  test('markSessionStarted records the moment training actually began',
      () async {
    final db = _MemoryDatabase();
    final controller = controllerWith(db);
    final at = DateTime.now();

    await controller.markSessionStarted(plan, at: at);

    final event = db.analyticsEvents.values
        .map(analyticsEventFromJson)
        .nonNulls
        .single;
    expect(event.type, AnalyticsEventType.sessionStarted);
    expect(event.timestamp, at);
    expect(event.properties['sessionId'], 's1');
  });

  test('once-per-day events are written once, not on every re-evaluation',
      () async {
    final db = _MemoryDatabase();
    final controller = controllerWith(db);

    await controller.recordAnalyticsEvent(
      AnalyticsEventType.rehitSuggested,
      oncePerDay: true,
    );
    await controller.recordAnalyticsEvent(
      AnalyticsEventType.rehitSuggested,
      oncePerDay: true,
    );
    await controller.recordAnalyticsEvent(AnalyticsEventType.sessionStarted);
    await controller.recordAnalyticsEvent(AnalyticsEventType.sessionStarted);

    final types = db.analyticsEvents.values
        .map(analyticsEventFromJson)
        .nonNulls
        .map((event) => event.type)
        .toList();
    expect(
      types.where((t) => t == AnalyticsEventType.rehitSuggested).length,
      1,
    );
    expect(
      types.where((t) => t == AnalyticsEventType.sessionStarted).length,
      2,
    );
  });

  test('a failing analytics write never breaks the session it observes',
      () async {
    final db = _MemoryDatabase()..failAnalyticsWrites = true;
    final controller = controllerWith(db);

    await controller.completeSession(
      plan,
      [set(startedAt: DateTime.now(), cycleSeconds: 100)],
      durationMinutes: 20,
      startedAt: DateTime.now(),
      elapsedSeconds: 1200,
    );

    expect(db.sessionLogs, hasLength(1));
    expect(db.analyticsEvents, isEmpty);
  });

  group('rest-day REHIT eligibility', () {
    SessionLog sessionAt(DateTime startedAt) => SessionLog(
          id: 'log-${startedAt.toIso8601String()}',
          templateId: SessionTypeId.s1,
          tier: SessionTier.full,
          date: DateTime(startedAt.year, startedAt.month, startedAt.day),
          completedAt: startedAt.add(const Duration(minutes: 30)),
          setLogs: const [],
          plannedWorkSets: 6,
          completedWorkSets: 6,
          durationMinutes: 30,
          timings: SessionTimings(
            startedAt: startedAt,
            elapsedSeconds: 1800,
            plannedDurationMinutes: 30,
          ),
          countsAs: const {FloorCategory.strength},
        );

    test('an untrained day with a learned slot is eligible without a check-in',
        () async {
      final db = _MemoryDatabase();
      final controller = controllerWith(db);
      final now = DateTime(2026, 8, 3, 10); // Monday
      controller.replaceScheduleLogsForTesting([
        sessionAt(DateTime(2026, 7, 20, 17)),
        sessionAt(DateTime(2026, 7, 27, 17)),
      ]);

      final result = controller.restDayRehitEligibilityAt(now);
      expect(result.eligible, isTrue);
      expect(result.checkInMissing, isTrue);
      expect(result.slotSource, ScheduleSlotSource.weekdayHabit);
      expect(result.suggestedNudgeTime, DateTime(2026, 8, 3, 17));
    });

    test('a session already logged today closes it', () async {
      final db = _MemoryDatabase();
      final controller = controllerWith(db);
      final now = DateTime(2026, 8, 3, 10);
      controller.replaceRecentLogsForTesting([
        sessionAt(DateTime(2026, 8, 3, 7)),
      ]);

      final result = controller.restDayRehitEligibilityAt(now);
      expect(result.eligible, isFalse);
      expect(
        result.closedReasons,
        contains(RestDayRehitClosedReason.trainingLoggedToday),
      );
    });

    test('logging is gated tighter than the reminder: it needs a check-in',
        () async {
      final db = _MemoryDatabase();
      final controller = controllerWith(db);
      final now = DateTime.now();

      // Eligible for the reminder, but no readiness decision on file.
      expect(controller.restDayRehitEligibilityAt(now).eligible, isTrue);
      expect(controller.canLogRestDayRehitAt(now), isFalse);
      await expectLater(
        controller.logCardioSession(
          SessionTypeId.s7,
          completion: _fullRehit,
        ),
        throwsA(isA<StateError>()),
      );

      // With a GREEN check-in on file the same day, the log path opens.
      controller.todayTrace = _greenTrace(now);
      expect(controller.canLogRestDayRehitAt(now), isTrue);
      await controller.logCardioSession(
        SessionTypeId.s7,
        completion: _fullRehit,
      );

      final saved = db.sessionLogs.values.map(sessionLogFromJson).single;
      expect(saved.templateId, SessionTypeId.s7);
      expect(saved.isSupplemental, isTrue);
      // A bike-guided attempt has no stopwatch, but its dose is its duration.
      expect(saved.timings!.elapsedSeconds, _fullRehit.completedDurationSeconds);
      expect(
        saved.timings!.startedAt,
        saved.completedAt.subtract(
          Duration(seconds: _fullRehit.completedDurationSeconds),
        ),
      );

      final types = db.analyticsEvents.values
          .map(analyticsEventFromJson)
          .nonNulls
          .map((event) => event.type);
      expect(types, contains(AnalyticsEventType.rehitCompleted));

      // Having trained, the day is no longer a rest day.
      expect(controller.restDayRehitEligibilityAt(now).eligible, isFalse);
    });

    test('travel mode removes the CAROL bike and therefore the reminder',
        () async {
      final db = _MemoryDatabase();
      final controller = controllerWith(db);
      await controller
          .saveSettings(controller.settings.copyWith(travelMode: true));

      final result =
          controller.restDayRehitEligibilityAt(DateTime(2026, 8, 3, 10));
      expect(
        result.closedReasons,
        contains(RestDayRehitClosedReason.rehitUnavailableDueToTravel),
      );
    });
  });
}

/// The fixed CAROL preset: two 20-second sprints inside 8:40, with the
/// bike's own recovery not decomposed into app-authored intervals.
const _fullRehit = CardioCompletion(
  protocol: CardioProtocol.rehit,
  completedWorkIntervals: 2,
  completedWorkSeconds: 40,
  completedRecoveryIntervals: 0,
  completedRecoverySeconds: 0,
  completedDurationSeconds: 8 * 60 + 40,
);

DecisionTrace _greenTrace(DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  return DecisionTrace(
    date: day,
    checkin: CheckIn(
      date: day,
      timeMinutes: 35,
      subjective: 4,
      timestamp: now,
    ),
    recovery: const RecoveryTrace(
      hrvZToday: 0,
      hrvTrend3: 0,
      sleepScore: 90,
      rhrDev: 0,
      bucket: ReadinessBucket.green,
      compositeScore: 80,
    ),
    candidates: const [],
    firedRules: const [],
    plan: null,
    queue: const QueueTraceInfo(
      pointerBefore: SessionTypeId.s1,
      servedBefore: {},
    ),
  );
}

/// Exercises the real persistence paths while skipping the notification
/// plugin, which has no platform channel under test.
class _AnalyticsController extends AppController {
  _AnalyticsController(super.repository);

  @override
  Future<void> syncNotifications() async {}
}

class _MemoryDatabase extends AppDatabase {
  final Map<String, Map<String, dynamic>> meta = {};
  final Map<String, Map<String, dynamic>> sessionLogs = {};
  final Map<String, Map<String, dynamic>> analyticsEvents = {};
  final Map<String, Map<String, dynamic>> exerciseStates = {};
  bool failAnalyticsWrites = false;

  @override
  Future<void> putJson(
    String table,
    String keyColumn,
    String key,
    Map<String, dynamic> json,
  ) async {
    switch (table) {
      case 'meta':
        meta[key] = Map<String, dynamic>.from(json);
      case 'exercise_states':
        exerciseStates[key] = Map<String, dynamic>.from(json);
    }
  }

  @override
  Future<void> putJsonWithDate(
    String table,
    String key,
    DateTime date,
    Map<String, dynamic> json,
  ) async {
    if (table == 'analytics_events') {
      if (failAnalyticsWrites) throw StateError('analytics write failed');
      analyticsEvents[key] = Map<String, dynamic>.from(json);
      return;
    }
    if (table == 'session_logs') {
      sessionLogs[key] = Map<String, dynamic>.from(json);
    }
  }

  @override
  Future<Map<String, dynamic>?> getJson(
    String table,
    String keyColumn,
    String key,
  ) async =>
      table == 'meta' ? meta[key] : null;

  @override
  Future<List<Map<String, dynamic>>> getAllJson(String table) async =>
      table == 'exercise_states' ? exerciseStates.values.toList() : const [];

  @override
  Future<List<Map<String, dynamic>>> getJsonSince(
    String table,
    String dateColumn,
    DateTime since,
  ) async =>
      switch (table) {
        'session_logs' => sessionLogs.values.toList(),
        'analytics_events' => analyticsEvents.values.toList(),
        _ => const [],
      };
}
