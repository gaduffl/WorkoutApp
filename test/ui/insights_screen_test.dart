import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/analytics_engine.dart';
import 'package:morningcoach/engine/schedule_fit_engine.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_timing.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/ui/screens/insights_screen.dart';

void main() {
  SessionLog session({
    required DateTime startedAt,
    int elapsedSeconds = 2400,
    int plannedDurationMinutes = 30,
    SessionTypeId templateId = SessionTypeId.s1,
    List<SetLog> setLogs = const [],
  }) =>
      SessionLog(
        id: 'log-${startedAt.toIso8601String()}',
        templateId: templateId,
        tier: SessionTier.full,
        date: DateTime(startedAt.year, startedAt.month, startedAt.day),
        completedAt: startedAt.add(Duration(seconds: elapsedSeconds)),
        setLogs: setLogs,
        plannedWorkSets: 6,
        completedWorkSets: 6,
        durationMinutes: elapsedSeconds ~/ 60,
        timings: SessionTimings(
          startedAt: startedAt,
          elapsedSeconds: elapsedSeconds,
          plannedDurationMinutes: plannedDurationMinutes,
        ),
        countsAs: const {FloorCategory.strength},
      );

  Widget screen(TrainingTimeInsights insights, {ScheduleHabits? habits}) =>
      MaterialApp(
        home: InsightsScreen(
          loadData: () async => insights,
          loadHabits: habits == null ? null : () => habits,
        ),
      );

  final asOf = DateTime(2026, 8, 3, 20);

  TrainingTimeInsights insightsFrom(List<SessionLog> logs) =>
      const AnalyticsEngine()
          .build(logs: logs, events: const [], asOf: asOf, windowDays: 28);

  testWidgets('empty history explains itself instead of showing zeroes',
      (tester) async {
    await tester.pumpWidget(screen(insightsFrom(const [])));
    await tester.pumpAndSettle();

    expect(find.text('No sessions in this window yet'), findsOneWidget);
    expect(find.text('Session length vs. plan'), findsNothing);
  });

  testWidgets('a consistent overrun is named as a plan-estimate problem',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      screen(
        insightsFrom([
          for (var offset = 0; offset < 3; offset++)
            session(
              startedAt: DateTime(2026, 8, 3 - offset, 7),
              elapsedSeconds: 40 * 60,
              plannedDurationMinutes: 30,
            ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Runs +10 min over the estimate'), findsOneWidget);
  });

  testWidgets('the rhythm card reports the observed training time',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final logs = [
      session(startedAt: DateTime(2026, 8, 1, 17, 30)),
      session(startedAt: DateTime(2026, 8, 2, 17, 30)),
    ];
    await tester.pumpWidget(
      screen(
        insightsFrom(logs),
        habits: const ScheduleFitEngine()
            .buildHabits(logs: logs, asOf: asOf, windowDays: 28),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Your training rhythm'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('17:30'), findsWidgets);
  });

  testWidgets('time categories use distinct fixed colors in bar and legend',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final start = DateTime(2026, 8, 3, 7);
    final setLogs = [
      SetLog(
        trackKey: 'warmup',
        pattern: MovementPattern.squat,
        exerciseName: 'Warm-up',
        weight: 0,
        value: 10,
        rir: Rir.rir4plus,
        isWarmup: true,
        startedAt: start,
        plannedRestSecondsBefore: 0,
        timestamp: start.add(const Duration(seconds: 120)),
      ),
      SetLog(
        trackKey: 'work',
        pattern: MovementPattern.squat,
        exerciseName: 'Work set',
        weight: 40,
        value: 8,
        rir: Rir.rir2,
        startedAt: start.add(const Duration(seconds: 120)),
        plannedRestSecondsBefore: 90,
        timestamp: start.add(const Duration(seconds: 300)),
      ),
    ];
    await tester.pumpWidget(
      screen(
        insightsFrom([
          session(
            startedAt: start,
            elapsedSeconds: 600,
            setLogs: setLogs,
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    const colors = <String, Color>{
      'warmup': timeAllocationWarmupColor,
      'working': timeAllocationWorkingColor,
      'rest': timeAllocationRestColor,
      'unaccounted': timeAllocationUnaccountedColor,
    };
    expect(colors.values.toSet(), hasLength(colors.length));
    for (final entry in colors.entries) {
      final segment = tester.widget<Container>(
        find.byKey(ValueKey('time-allocation-segment-${entry.key}')),
      );
      final swatch = tester.widget<Container>(
        find.byKey(ValueKey('time-allocation-swatch-${entry.key}')),
      );
      expect(segment.color, entry.value);
      expect((swatch.decoration! as BoxDecoration).color, entry.value);
    }
  });

  testWidgets('a load failure offers a retry rather than a blank screen',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: InsightsScreen(
          loadData: () async => throw StateError('nope'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load training insights.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  group('formatters', () {
    test('durations read naturally at every scale', () {
      expect(formatDurationSeconds(45), '45s');
      expect(formatDurationSeconds(90), '1:30');
      expect(formatDurationSeconds(2400), '40:00');
      expect(formatDurationSeconds(3900), '1h 05m');
    });

    test('estimate bias keeps its sign', () {
      expect(formatSignedMinutes(600), '+10 min');
      expect(formatSignedMinutes(-600), '−10 min');
      expect(formatSignedMinutes(30), '+0.5 min');
    });

    test('minute-of-day renders as a wall clock', () {
      expect(formatMinuteOfDay(0), '00:00');
      expect(formatMinuteOfDay(17 * 60 + 5), '17:05');
    });
  });

  group('estimate verdict', () {
    SessionTypeTimeSummary summary({
      required int sessionCount,
      double? bias,
    }) =>
        SessionTypeTimeSummary(
          templateId: SessionTypeId.s1,
          sessionCount: sessionCount,
          medianTotalSeconds: 2400,
          medianPlannedSeconds: 1800,
          medianEstimateErrorSeconds: bias,
          medianAbsoluteEstimateErrorSeconds: bias?.abs(),
          medianSecondsPerWorkSet: 300,
        );

    test('a thin sample is reported as inconclusive', () {
      expect(
        estimateVerdict(summary(sessionCount: 2, bias: 900)),
        contains('not conclusive'),
      );
    });

    test('a small bias with enough evidence is called fine', () {
      expect(
        estimateVerdict(summary(sessionCount: 5, bias: 30)),
        startsWith('Estimate holds up'),
      );
    });

    test('finishing early is described as such, not as an overrun', () {
      expect(
        estimateVerdict(summary(sessionCount: 5, bias: -420)),
        startsWith('Finishes'),
      );
    });

    test('no recorded estimate says so', () {
      expect(
        estimateVerdict(summary(sessionCount: 5)),
        'No estimate recorded yet',
      );
    });
  });
}
