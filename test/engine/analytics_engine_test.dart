import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/analytics_engine.dart';
import 'package:morningcoach/models/analytics_event.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_timing.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';

void main() {
  const engine = AnalyticsEngine();

  SetLog set({
    required DateTime startedAt,
    required int cycleSeconds,
    int plannedRestBefore = 0,
    bool isWarmup = false,
    String trackKey = 'squat',
    String name = 'Goblet Squat',
    int value = 8,
  }) =>
      SetLog(
        trackKey: trackKey,
        pattern: MovementPattern.squat,
        exerciseName: name,
        weight: 40,
        value: value,
        metric: ExerciseMetric.reps,
        rir: Rir.rir2,
        isWarmup: isWarmup,
        startedAt: startedAt,
        plannedRestSecondsBefore: plannedRestBefore,
        timestamp: startedAt.add(Duration(seconds: cycleSeconds)),
      );

  SessionLog strengthLog({
    required DateTime date,
    required DateTime startedAt,
    required int elapsedSeconds,
    int plannedDurationMinutes = 35,
    List<SetLog> sets = const [],
    SessionTypeId templateId = SessionTypeId.s1,
    String? id,
  }) =>
      SessionLog(
        id: id ?? 'log-${date.toIso8601String()}',
        templateId: templateId,
        tier: SessionTier.full,
        date: DateTime(date.year, date.month, date.day),
        completedAt: startedAt.add(Duration(seconds: elapsedSeconds)),
        setLogs: sets,
        plannedWorkSets: sets.where((s) => !s.isWarmup).length,
        completedWorkSets: sets.where((s) => !s.isWarmup).length,
        durationMinutes: elapsedSeconds ~/ 60,
        timings: SessionTimings(
          startedAt: startedAt,
          elapsedSeconds: elapsedSeconds,
          plannedDurationMinutes: plannedDurationMinutes,
        ),
        countsAs: const {FloorCategory.strength},
      );

  group('per-set timing', () {
    test('cycle splits into prescribed rest and everything after it', () {
      final start = DateTime(2026, 8, 3, 7, 30);
      final logged = set(startedAt: start, cycleSeconds: 140, plannedRestBefore: 90);
      expect(logged.cycleSeconds, 140);
      expect(logged.restSeconds, 90);
      expect(logged.activeSecondsEstimate, 50);
    });

    test('rest is capped by the cycle when the user starts early', () {
      final logged = set(
        startedAt: DateTime(2026, 8, 3, 7, 30),
        cycleSeconds: 40,
        plannedRestBefore: 90,
      );
      expect(logged.restSeconds, 40);
      expect(logged.activeSecondsEstimate, 0);
    });

    test('a set without timing reports null rather than zero', () {
      final logged = SetLog(
        trackKey: 'squat',
        pattern: MovementPattern.squat,
        exerciseName: 'Goblet Squat',
        weight: 40,
        value: 8,
        rir: Rir.rir2,
        timestamp: DateTime(2026, 8, 3, 7, 30),
      );
      expect(logged.cycleSeconds, isNull);
      expect(logged.restSeconds, isNull);
      expect(logged.activeSecondsEstimate, isNull);
    });

    test('a negative span collapses to null instead of lying', () {
      final start = DateTime(2026, 8, 3, 7, 30);
      final logged = SetLog(
        trackKey: 'squat',
        pattern: MovementPattern.squat,
        exerciseName: 'Goblet Squat',
        weight: 40,
        value: 8,
        rir: Rir.rir2,
        startedAt: start,
        timestamp: start.subtract(const Duration(seconds: 5)),
      );
      expect(logged.cycleSeconds, isNull);
    });
  });

  group('session metrics', () {
    test('partitions the session exactly and names the leftover', () {
      final start = DateTime(2026, 8, 3, 7, 0);
      final sets = [
        set(startedAt: start, cycleSeconds: 60, isWarmup: true, name: 'Ramp 40%'),
        set(startedAt: start.add(const Duration(seconds: 60)), cycleSeconds: 100),
        set(
          startedAt: start.add(const Duration(seconds: 160)),
          cycleSeconds: 140,
          plannedRestBefore: 90,
        ),
      ];
      final metrics = engine.sessionMetrics(
        strengthLog(
          date: start,
          startedAt: start,
          elapsedSeconds: 420,
          sets: sets,
        ),
      );

      expect(metrics.warmupSeconds, 60);
      expect(metrics.warmupSetCount, 1);
      expect(metrics.workSetCount, 2);
      expect(metrics.timedSetCount, 3);
      expect(metrics.workRestSeconds, 90);
      expect(metrics.workActiveSeconds, 100 + 50);
      expect(metrics.attributedSeconds, 300);
      expect(metrics.unattributedSeconds, 120);
      expect(
        metrics.warmupSeconds +
            metrics.workRestSeconds +
            metrics.workActiveSeconds +
            metrics.unattributedSeconds,
        metrics.totalSeconds,
      );
    });

    test('estimate error is actual minus predicted', () {
      final start = DateTime(2026, 8, 3, 7, 0);
      final metrics = engine.sessionMetrics(
        strengthLog(
          date: start,
          startedAt: start,
          elapsedSeconds: 45 * 60,
          plannedDurationMinutes: 35,
        ),
      );
      expect(metrics.plannedSeconds, 35 * 60);
      expect(metrics.estimateErrorSeconds, 10 * 60);
      expect(metrics.estimateRatio, closeTo(45 / 35, 0.0001));
    });

    test('steps outrunning the clock never report negative dead time', () {
      final start = DateTime(2026, 8, 3, 7, 0);
      final metrics = engine.sessionMetrics(
        strengthLog(
          date: start,
          startedAt: start,
          elapsedSeconds: 60,
          sets: [set(startedAt: start, cycleSeconds: 300)],
        ),
      );
      expect(metrics.unattributedSeconds, 0);
    });

    test('a legacy log yields no per-set timing but still reports duration', () {
      final day = DateTime(2026, 8, 1);
      final metrics = engine.sessionMetrics(
        SessionLog(
          id: 'legacy',
          templateId: SessionTypeId.s1,
          tier: SessionTier.full,
          date: day,
          setLogs: const [],
          plannedWorkSets: 6,
          completedWorkSets: 6,
          durationMinutes: 40,
          countsAs: const {FloorCategory.strength},
        ),
      );
      expect(metrics.totalSeconds, 40 * 60);
      expect(metrics.totalSecondsExact, isFalse);
      expect(metrics.timedSetCount, 0);
      expect(metrics.plannedSeconds, isNull);
      expect(metrics.startedAt, isNull);
    });
  });

  group('window roll-up', () {
    final asOf = DateTime(2026, 8, 3, 19);

    TrainingTimeInsights build({
      List<SessionLog> logs = const [],
      List<AnalyticsEvent> events = const [],
      int windowDays = 28,
    }) =>
        engine.build(
          logs: logs,
          events: events,
          asOf: asOf,
          windowDays: windowDays,
        );

    test('session-type bias is the median signed error', () {
      final logs = [
        for (var offset = 0; offset < 3; offset++)
          strengthLog(
            id: 'over-$offset',
            date: asOf.subtract(Duration(days: offset)),
            startedAt: DateTime(2026, 8, 3 - offset, 7),
            elapsedSeconds: (35 + 5 + offset) * 60,
            plannedDurationMinutes: 35,
          ),
      ];
      final summary = build(logs: logs).bySessionType.single;
      expect(summary.sessionCount, 3);
      expect(summary.medianEstimateErrorSeconds, 6 * 60);
      expect(summary.estimateNeedsAttention, isTrue);
    });

    test('a small sample is not treated as a conclusive bias', () {
      final summary = build(
        logs: [
          strengthLog(
            date: asOf,
            startedAt: DateTime(2026, 8, 3, 7),
            elapsedSeconds: 50 * 60,
            plannedDurationMinutes: 35,
          ),
        ],
      ).bySessionType.single;
      expect(summary.medianEstimateErrorSeconds, 15 * 60);
      expect(summary.estimateNeedsAttention, isFalse);
    });

    test('logs outside the window are excluded', () {
      final insights = build(
        logs: [
          strengthLog(
            id: 'old',
            date: asOf.subtract(const Duration(days: 40)),
            startedAt: DateTime(2026, 6, 24, 7),
            elapsedSeconds: 1800,
          ),
          strengthLog(
            id: 'recent',
            date: asOf,
            startedAt: DateTime(2026, 8, 3, 7),
            elapsedSeconds: 1800,
          ),
        ],
      );
      expect(insights.sessions.map((s) => s.sessionLogId), ['recent']);
    });

    test('allocation ignores sessions with no per-set timing', () {
      final start = DateTime(2026, 8, 3, 7);
      final insights = build(
        logs: [
          strengthLog(
            id: 'timed',
            date: start,
            startedAt: start,
            elapsedSeconds: 300,
            sets: [
              set(startedAt: start, cycleSeconds: 120, plannedRestBefore: 90),
            ],
          ),
          SessionLog(
            id: 'legacy',
            templateId: SessionTypeId.s1,
            tier: SessionTier.full,
            date: DateTime(2026, 8, 2),
            setLogs: const [],
            plannedWorkSets: 6,
            completedWorkSets: 6,
            durationMinutes: 60,
            countsAs: const {FloorCategory.strength},
          ),
        ],
      );
      expect(insights.allocation.sessionCount, 1);
      expect(insights.allocation.totalSeconds, 300);
      expect(insights.allocation.restSeconds, 90);
      expect(insights.allocation.activeSeconds, 30);
      expect(insights.allocation.unattributedSeconds, 180);
    });

    test('consistency counts streaks and the most-missed weekday', () {
      // 2026-08-03 is a Monday. Train Sat/Sun/Mon.
      final logs = [
        for (final day in [
          DateTime(2026, 8, 1),
          DateTime(2026, 8, 2),
          DateTime(2026, 8, 3),
        ])
          strengthLog(
            id: 'day-${day.day}',
            date: day,
            startedAt: DateTime(day.year, day.month, day.day, 7),
            elapsedSeconds: 1800,
          ),
      ];
      final consistency = build(logs: logs, windowDays: 14).consistency;
      expect(consistency.trainedDays, 3);
      expect(consistency.currentStreakDays, 3);
      expect(consistency.longestStreakDays, 3);
      expect(consistency.daysSinceLastSession, 0);
      expect(consistency.untrainedDays, 11);
      expect(consistency.untrainedDaysByWeekday[DateTime.wednesday], 2);
    });

    test('a streak that stopped before today is not the current streak', () {
      final logs = [
        for (final day in [DateTime(2026, 7, 30), DateTime(2026, 7, 31)])
          strengthLog(
            id: 'day-${day.day}',
            date: day,
            startedAt: DateTime(day.year, day.month, day.day, 7),
            elapsedSeconds: 1800,
          ),
      ];
      final consistency = build(logs: logs, windowDays: 14).consistency;
      expect(consistency.currentStreakDays, 0);
      expect(consistency.longestStreakDays, 2);
      expect(consistency.daysSinceLastSession, 3);
    });

    test('latency measures check-in to actually starting', () {
      final insights = build(
        logs: [
          strengthLog(
            date: asOf,
            startedAt: DateTime(2026, 8, 3, 9, 30),
            elapsedSeconds: 1800,
          ),
        ],
        events: [
          AnalyticsEvent(
            id: 'checkin',
            type: AnalyticsEventType.checkInSubmitted,
            timestamp: DateTime(2026, 8, 3, 7),
          ),
          AnalyticsEvent(
            id: 'plan',
            type: AnalyticsEventType.planGenerated,
            timestamp: DateTime(2026, 8, 3, 7, 1),
          ),
        ],
      );
      expect(insights.latency.medianCheckInToStartSeconds, 2.5 * 3600);
      expect(insights.latency.medianPlanToStartSeconds, 149 * 60);
      expect(insights.latency.medianCheckInMinuteOfDay, 7 * 60);
      expect(insights.latency.checkedInWithoutTrainingDays, 0);
    });

    test('a check-in with no session is counted as such', () {
      final insights = build(
        events: [
          AnalyticsEvent(
            id: 'checkin',
            type: AnalyticsEventType.checkInSubmitted,
            timestamp: DateTime(2026, 8, 2, 7),
          ),
        ],
      );
      expect(insights.latency.checkedInWithoutTrainingDays, 1);
    });
  });

  group('REHIT funnel', () {
    final asOf = DateTime(2026, 8, 3, 21);

    SessionLog rehitLog(DateTime completedAt) => SessionLog(
          id: 'rehit-${completedAt.toIso8601String()}',
          templateId: SessionTypeId.s7,
          tier: SessionTier.full,
          date: DateTime(
            completedAt.year,
            completedAt.month,
            completedAt.day,
          ),
          completedAt: completedAt,
          setLogs: const [],
          plannedWorkSets: 0,
          completedWorkSets: 0,
          durationMinutes: 9,
          countsAs: const {FloorCategory.intensity},
          cardioCompletion: const CardioCompletion(
            protocol: CardioProtocol(
              type: CardioProtocolType.rehit,
              name: 'CAROL REHIT Intense',
            ),
            completedWorkIntervals: 2,
            completedWorkSeconds: 40,
            completedRecoveryIntervals: 2,
            completedRecoverySeconds: 300,
            completedDurationSeconds: 520,
          ),
        );

    test('measures suggestion and session-start latency to the dose', () {
      final funnel = engine.build(
        asOf: asOf,
        windowDays: 28,
        logs: [
          strengthLog(
            date: asOf,
            startedAt: DateTime(2026, 8, 3, 7),
            elapsedSeconds: 1800,
          ),
          rehitLog(DateTime(2026, 8, 3, 17)),
        ],
        events: [
          AnalyticsEvent(
            id: 'suggested',
            type: AnalyticsEventType.rehitSuggested,
            timestamp: DateTime(2026, 8, 3, 12),
          ),
          AnalyticsEvent(
            id: 'nudged',
            type: AnalyticsEventType.rehitNudgeScheduled,
            timestamp: DateTime(2026, 8, 3, 12),
          ),
        ],
      ).rehit;

      expect(funnel.suggestedDays, 1);
      expect(funnel.nudgedDays, 1);
      expect(funnel.completedDays, 1);
      expect(funnel.convertedDays, 1);
      expect(funnel.conversionRate, 1.0);
      expect(funnel.medianSuggestionToCompletionSeconds, 5 * 3600);
      expect(funnel.medianSessionStartToCompletionSeconds, 10 * 3600);
      expect(funnel.medianCompletionMinuteOfDay, 17 * 60);
    });

    test('a suggested day with no dose lowers the conversion rate', () {
      final funnel = engine.build(
        asOf: asOf,
        windowDays: 28,
        logs: const [],
        events: [
          AnalyticsEvent(
            id: 'a',
            type: AnalyticsEventType.rehitSuggested,
            timestamp: DateTime(2026, 8, 2, 12),
          ),
          AnalyticsEvent(
            id: 'b',
            type: AnalyticsEventType.restDayRehitSuggested,
            timestamp: DateTime(2026, 8, 3, 12),
          ),
        ],
      ).rehit;
      expect(funnel.suggestedDays, 2);
      expect(funnel.completedDays, 0);
      expect(funnel.conversionRate, 0.0);
    });

    test('a REHIT logged before it was ever suggested is not a conversion', () {
      final funnel = engine.build(
        asOf: asOf,
        windowDays: 28,
        logs: [rehitLog(DateTime(2026, 8, 3, 9))],
        events: [
          AnalyticsEvent(
            id: 'suggested',
            type: AnalyticsEventType.rehitSuggested,
            timestamp: DateTime(2026, 8, 3, 12),
          ),
        ],
      ).rehit;
      expect(funnel.completedDays, 1);
      expect(funnel.convertedDays, 0);
      expect(funnel.medianSuggestionToCompletionSeconds, isNull);
    });
  });

  group('median', () {
    test('averages the middle pair and rejects an empty sample', () {
      expect(AnalyticsEngine.median(const []), isNull);
      expect(AnalyticsEngine.median(const [5]), 5);
      expect(AnalyticsEngine.median(const [1, 2, 3, 4]), 2.5);
      expect(AnalyticsEngine.median(const [9, 1, 5]), 5);
    });
  });
}
