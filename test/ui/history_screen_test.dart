import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/stimulus_ledger_engine.dart';
import 'package:morningcoach/engine/training_status_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/history_data.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/training_targets.dart';
import 'package:morningcoach/models/user_settings.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/history_screen.dart';
import 'package:provider/provider.dart';

void main() {
  final asOf = DateTime(2026, 7, 15, 18);

  HistoryData dataWith({List<SessionLog> logs = const []}) {
    final targets = TrainingTargets();
    final ledger = const StimulusLedgerEngine().buildFromSessionLogs(
      logs: logs,
      asOf: asOf,
    );
    final status = const TrainingStatusEngine().build(
      targets: targets,
      ledger: ledger,
    );
    return HistoryData(
      asOf: asOf,
      logs: logs,
      recoverySnapshots: const [],
      targets: targets,
      ledger: ledger,
      trainingStatus: status,
    );
  }

  Widget app({
    required HistoryDataLoader loader,
    bool classicHeatmap = false,
  }) {
    final controller = AppController(Repository(AppDatabase()))
      ..settings = UserSettings(classicHeatmap: classicHeatmap);
    return ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: MaterialApp(home: HistoryScreen(loadData: loader)),
    );
  }

  test('activity projection uses stable elapsed-time levels', () {
    final projected = HistoryActivityDay.project([
      heatLog(
        id: 'short',
        date: DateTime(2026, 7, 10),
        durationMinutes: 9,
      ),
      heatLog(
        id: 'medium',
        date: DateTime(2026, 7, 11),
        durationMinutes: 10,
      ),
      heatLog(
        id: 'long',
        date: DateTime(2026, 7, 12),
        durationMinutes: 20,
      ),
      heatLog(
        id: 'longest',
        date: DateTime(2026, 7, 13),
        durationMinutes: 35,
      ),
    ]);

    expect(projected['2026-7-10']!.level, 1);
    expect(projected['2026-7-11']!.level, 2);
    expect(projected['2026-7-12']!.level, 3);
    expect(projected['2026-7-13']!.level, 4);
  });

  testWidgets('year activity heatmap is the default history view',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(loader: (_) async => dataWith()));
    await tester.pumpAndSettle();

    expect(find.text('Activity · last 12 months'), findsOneWidget);
    expect(find.text('Last 12 weeks'), findsNothing);
    expect(find.text('28-day dose'), findsOneWidget);
    expect(find.text('Recency'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
  });

  SessionLog heatLog({
    required String id,
    required DateTime date,
    SessionTypeId type = SessionTypeId.s1,
    int strengthSets = 0,
    int durationMinutes = 20,
    CardioCompletion? cardioCompletion,
    bool rehitFinisherCompleted = false,
  }) =>
      SessionLog(
        id: id,
        templateId: type,
        tier: SessionTier.full,
        date: date,
        completedAt: date.add(const Duration(hours: 8)),
        setLogs: const [],
        plannedWorkSets: strengthSets,
        completedWorkSets: strengthSets,
        durationMinutes: durationMinutes,
        countsAs: const {},
        cardioCompletion: cardioCompletion,
        rehitFinisherCompleted: rehitFinisherCompleted,
      );

  test('heatmap projection keeps cardio attempts visible with VO₂ priority', () {
    final zone2 = heatLog(
      id: 'partial-zone2',
      date: DateTime(2026, 7, 11),
      type: SessionTypeId.s6,
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.zone2Base,
        completedWorkIntervals: 1,
        completedWorkSeconds: 600,
        completedRecoveryIntervals: 0,
        completedRecoverySeconds: 0,
        completedDurationSeconds: 600,
      ),
    );
    final vo2 = heatLog(
      id: 'partial-rehit',
      date: DateTime(2026, 7, 12),
      type: SessionTypeId.s7,
      durationMinutes: 8,
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.rehit,
        completedWorkIntervals: 1,
        completedWorkSeconds: 20,
        completedRecoveryIntervals: 1,
        completedRecoverySeconds: 180,
        completedDurationSeconds: 480,
      ),
    );
    final mixedStrengthFinisher = heatLog(
      id: 'strength-rehit',
      date: DateTime(2026, 7, 13),
      strengthSets: 3,
      durationMinutes: 8,
      rehitFinisherCompleted: true,
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.rehit,
        completedWorkIntervals: 2,
        completedWorkSeconds: 40,
        completedRecoveryIntervals: 2,
        completedRecoverySeconds: 360,
        completedDurationSeconds: 480,
      ),
    );
    final mixedZone2 = heatLog(
      id: 'mixed-zone2',
      date: DateTime(2026, 7, 13),
      type: SessionTypeId.s6,
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.zone2Base,
        completedWorkIntervals: 1,
        completedWorkSeconds: 1200,
        completedRecoveryIntervals: 0,
        completedRecoverySeconds: 0,
        completedDurationSeconds: 1200,
      ),
    );

    final projected = HistoryHeatDay.project([
      heatLog(id: 'strength', date: DateTime(2026, 7, 10), strengthSets: 2),
      zone2,
      vo2,
      mixedStrengthFinisher,
      mixedZone2,
    ]);

    expect(projected['2026-7-10']!.category, HistoryHeatCategory.strength);
    expect(projected['2026-7-11']!.category, HistoryHeatCategory.zone2);
    expect(projected['2026-7-12']!.category, HistoryHeatCategory.vo2Rehit);
    expect(projected['2026-7-13']!.category, HistoryHeatCategory.vo2Rehit);
    expect(
      projected['2026-7-13']!.tooltip(DateTime(2026, 7, 13)),
      contains('3 strength sets · Zone 2 20m · VO₂/REHIT 8m'),
    );
  });

  testWidgets('heatmap legend has three distinct category colors and copy',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      app(loader: (_) async => dataWith(), classicHeatmap: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Strength'), findsOneWidget);
    expect(find.text('Zone 2'), findsOneWidget);
    expect(find.text('VO₂/REHIT'), findsOneWidget);
    expect(
      find.text(
        'Strength shade = completed sets · cardio color = session type; tooltip shows logged dose',
      ),
      findsOneWidget,
    );
    final colors = [
      'history-heat-legend-strength',
      'history-heat-legend-zone2',
      'history-heat-legend-vo2-rehit',
    ].map((key) {
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(Container),
        ),
      );
      return (container.decoration! as BoxDecoration).color;
    }).toSet();
    expect(colors, hasLength(3));
  });

  testWidgets('strength heat blocks and legend use the red error palette',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final strengthLog = heatLog(
      id: 'strength-color',
      date: DateTime(2026, 7, 15),
      strengthSets: 4,
    );
    await tester.pumpWidget(
      app(
        loader: (_) async => dataWith(logs: [strengthLog]),
        classicHeatmap: true,
      ),
    );
    await tester.pumpAndSettle();

    final errorColor = Theme.of(
      tester.element(find.byType(HistoryScreen)),
    ).colorScheme.error;
    final strengthBlock = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byTooltip('2026-07-15: 4 strength sets'),
        matching: find.byType(DecoratedBox),
      ),
    );
    final strengthLegend = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('history-heat-legend-strength')),
        matching: find.byType(Container),
      ),
    );

    expect((strengthBlock.decoration as BoxDecoration).color, errorColor);
    expect((strengthLegend.decoration! as BoxDecoration).color, errorColor);
  });

  testWidgets('shows a stable loading state', (tester) async {
    final pending = Completer<HistoryData>();
    await tester.pumpWidget(app(loader: (_) => pending.future));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a retryable error state without crashing', (tester) async {
    await tester.pumpWidget(
      app(loader: (_) => Future<HistoryData>.error(StateError('database'))),
    );
    await tester.pump();

    expect(find.text('Could not load history.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty history renders the target dashboard and existing views',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = dataWith();
    await tester.pumpWidget(app(loader: (_) async => data));
    await tester.pumpAndSettle();

    expect(find.text('Muscle targets'), findsOneWidget);
    expect(
      find.text('Targets: 8–12/week (center 10) · 32–48/28d (center 40)'),
      findsOneWidget,
    );
    expect(find.text('Quads'), findsOneWidget);
    expect(find.text('Core/grip'), findsOneWidget);
    expect(find.text('Below'), findsNWidgets(18));
    expect(find.text('Cardio targets'), findsOneWidget);
    expect(find.text('High-intensity days'), findsOneWidget);
    expect(find.text('Norwegian 4×4 preference'), findsOneWidget);
    expect(
      find.text('60m base exposure (secondary to strength deficits)'),
      findsOneWidget,
    );

    // The obsolete weekly-floor card is replaced; the useful history views
    // remain below the evidence-target dashboard.
    expect(find.text('Rolling 7-day floor'), findsNothing);
    expect(find.text('Activity · last 12 months'), findsOneWidget);
    expect(find.text('Progression (top set, 12 weeks)'), findsOneWidget);
    expect(find.text('HRV, last 28 days'), findsOneWidget);
    expect(find.text('No sessions logged yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timed core progression and difficulty changes are visible',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SessionLog timedLog({
      required String id,
      required DateTime date,
      required String exercise,
      required int seconds,
    }) =>
        SessionLog(
          id: id,
          templateId: SessionTypeId.s5,
          tier: SessionTier.full,
          date: date,
          completedAt: date.add(const Duration(minutes: 20)),
          setLogs: [
            SetLog(
              trackKey: MovementPattern.coreGrip.name,
              pattern: MovementPattern.coreGrip,
              exerciseName: exercise,
              weight: 0,
              metric: ExerciseMetric.seconds,
              value: seconds,
              rir: Rir.rir2,
              timestamp: date,
            ),
          ],
          plannedWorkSets: 1,
          completedWorkSets: 1,
          durationMinutes: 20,
          countsAs: const {FloorCategory.strength},
        );

    final logs = [
      timedLog(
        id: 'plank',
        date: DateTime(2026, 7, 10),
        exercise: 'Plank',
        seconds: 60,
      ),
      timedLog(
        id: 'l-sit',
        date: DateTime(2026, 7, 14),
        exercise: 'L-sit progression',
        seconds: 15,
      ),
      timedLog(
        id: 'l-sit-2',
        date: DateTime(2026, 7, 15),
        exercise: 'L-sit progression',
        seconds: 20,
      ),
    ];
    await tester.pumpWidget(app(loader: (_) async => dataWith(logs: logs)));
    await tester.pumpAndSettle();

    expect(find.text('20 s'), findsOneWidget);
    expect(
      find.text('Latest: L-sit progression'),
      findsOneWidget,
      reason: 'The latest difficulty must appear as a small secondary line under the row label, never inside the chart column.',
    );
    expect(
      find.text('Difficulty history: Plank → L-sit progression'),
      findsOneWidget,
    );
    // "Plank" must not appear anywhere on the card now: the row label is
    // "Core / grip", the secondary line is "Latest: L-sit progression", and
    // Plank only shows up inside the difficulty-history summary string.
    expect(find.textContaining('Plank'), findsOneWidget);
    final timedSparkline = find.byKey(
      const ValueKey('progression-sparkline-coreGrip'),
    );
    expect(timedSparkline, findsOneWidget);
    expect(
      tester.getSize(timedSparkline).width,
      greaterThan(200),
      reason: 'The timed sparkline must fill the chart column, not collapse to a dot.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('4x4 meets the preference while frequency remains visible',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final log = SessionLog(
      id: 'legacy-4x4',
      templateId: SessionTypeId.s3,
      tier: SessionTier.full,
      date: DateTime(2026, 7, 15),
      completedAt: asOf,
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: 35,
      countsAs: const {FloorCategory.intensity},
    );
    final data = dataWith(logs: [log]);

    await tester.pumpWidget(app(loader: (_) async => data));
    await tester.pumpAndSettle();

    expect(find.textContaining('Preference met'), findsOneWidget);
    expect(
      find.textContaining('1/3 DISTINCT DAYS'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'three distinct-day REHIT sessions show replacement guidance instead of a fourth day',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SessionLog rehit(String id, DateTime completedAt) => SessionLog(
          id: id,
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
          durationMinutes: 10,
          countsAs: const {FloorCategory.intensity},
        );
    final data = dataWith(
      logs: [
        rehit('day-one', DateTime(2026, 7, 14, 9)),
        rehit('day-two', DateTime(2026, 7, 15, 9)),
        rehit('day-three', DateTime(2026, 7, 13, 9)),
      ],
    );

    await tester.pumpWidget(app(loader: (_) async => data));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('3/3 DISTINCT DAYS'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Replace a REHIT day with 4×4 when a 35/60 min slot is available; do not add a fourth high-intensity day.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('session rows render cardio dose instead of 0/0 strength sets',
      (tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SessionLog cardioLog({
      required String id,
      required SessionTypeId type,
      required DateTime completedAt,
      required int durationMinutes,
      CardioCompletion? completion,
      bool? completedAsPrescribed,
      Set<FloorCategory> countsAs = const {},
    }) =>
        SessionLog(
          id: id,
          templateId: type,
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
          durationMinutes: durationMinutes,
          countsAs: countsAs,
          cardioCompletion: completion,
          cardioCompletedAsPrescribed: completedAsPrescribed,
        );
    final data = dataWith(
      logs: [
        cardioLog(
          id: 'structured-4x4',
          type: SessionTypeId.s3,
          completedAt: DateTime(2026, 7, 12, 8),
          durationMinutes: 35,
          countsAs: const {FloorCategory.intensity},
          completedAsPrescribed: true,
          completion: const CardioCompletion(
            protocol: CardioProtocol.norwegian4x4,
            completedWorkIntervals: 4,
            completedWorkSeconds: 960,
            completedRecoveryIntervals: 3,
            completedRecoverySeconds: 540,
            completedDurationSeconds: 2100,
          ),
        ),
        cardioLog(
          id: 'recovery-base',
          type: SessionTypeId.s6,
          completedAt: DateTime(2026, 7, 13, 8),
          durationMinutes: 20,
          completedAsPrescribed: true,
          completion: const CardioCompletion(
            protocol: CardioProtocol.zone2Base,
            completedWorkIntervals: 1,
            completedWorkSeconds: 1200,
            completedRecoveryIntervals: 0,
            completedRecoverySeconds: 0,
            completedDurationSeconds: 1200,
          ),
        ),
        cardioLog(
          id: 'partial-rehit',
          type: SessionTypeId.s7,
          completedAt: DateTime(2026, 7, 14, 8),
          durationMinutes: 8,
          completedAsPrescribed: false,
          completion: const CardioCompletion(
            protocol: CardioProtocol.rehit,
            completedWorkIntervals: 1,
            completedWorkSeconds: 20,
            completedRecoveryIntervals: 1,
            completedRecoverySeconds: 180,
            completedDurationSeconds: 480,
          ),
        ),
        cardioLog(
          id: 'legacy-4x4',
          type: SessionTypeId.s3,
          completedAt: DateTime(2026, 7, 15, 8),
          durationMinutes: 35,
          countsAs: const {FloorCategory.intensity},
        ),
      ],
    );

    await tester.pumpWidget(app(loader: (_) async => data));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('4 work intervals · 16:00 work · 35:00 total'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        '20:00 continuous (completed recovery · no base credit)',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('1 sprint · 0:20 work · 8:00 total (partial)'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        '35 min logged · legacy cardio details unavailable',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('0/0 sets'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'supplemental and unplanned REHIT rows use delivered dose for partial status',
      (tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SessionLog rehit({
      required String id,
      required DateTime date,
      required bool isUnplanned,
      required CardioCompletion completion,
    }) =>
        SessionLog(
          id: id,
          templateId: SessionTypeId.s7,
          tier: SessionTier.full,
          date: date,
          completedAt: date.add(const Duration(hours: 8)),
          setLogs: const [],
          plannedWorkSets: 0,
          completedWorkSets: 0,
          durationMinutes: 8,
          countsAs: completion.meetsCreditableDose
              ? const {FloorCategory.intensity}
              : const {},
          cardioCompletedAsPrescribed: false,
          cardioCompletion: completion,
          isSupplemental: true,
          isUnplanned: isUnplanned,
        );
    final data = dataWith(
      logs: [
        rehit(
          id: 'eligible-second-rehit',
          date: DateTime(2026, 7, 14),
          isUnplanned: false,
          completion: const CardioCompletion(
            protocol: CardioProtocol.rehit,
            completedWorkIntervals: 2,
            completedWorkSeconds: 40,
            completedRecoveryIntervals: 0,
            completedRecoverySeconds: 0,
            completedDurationSeconds: 480,
            averageHeartRateBpm: 151,
            peakHeartRateBpm: 181,
            rpe: 9.5,
            fitnessScore: 42.5,
            peakPowerWatts: 734.5,
          ),
        ),
        rehit(
          id: 'retrospective-partial-rehit',
          date: DateTime(2026, 7, 15),
          isUnplanned: true,
          completion: const CardioCompletion(
            protocol: CardioProtocol.rehit,
            completedWorkIntervals: 1,
            completedWorkSeconds: 20,
            completedRecoveryIntervals: 0,
            completedRecoverySeconds: 0,
            completedDurationSeconds: 480,
          ),
        ),
      ],
    );

    await tester.pumpWidget(app(loader: (_) async => data));
    await tester.pumpAndSettle();

    expect(find.text('S7 - full · supplemental'), findsOneWidget);
    expect(find.text('S7 - full · unplanned'), findsOneWidget);
    expect(
      find.textContaining(
        '2 sprints · 0:40 work · 8:00 total · '
        'Fitness Score 42.5 · Peak Power 734.5 W',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Peak HR'), findsNothing);
    expect(find.textContaining('Average HR'), findsNothing);
    expect(find.textContaining('RPE 9.5'), findsNothing);
    expect(
      find.textContaining('2 sprints · 0:40 work · 8:00 total (partial)'),
      findsNothing,
    );
    expect(
      find.textContaining('1 sprint · 0:20 work · 8:00 total (partial)'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'history distinguishes completed short recovery from a partial longer S6',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SessionLog recoveryLog({
      required String id,
      required DateTime date,
      required bool completedAsPrescribed,
    }) =>
        SessionLog(
          id: id,
          templateId: SessionTypeId.s6,
          tier: SessionTier.compressed,
          date: date,
          completedAt: date.add(const Duration(hours: 8)),
          setLogs: const [],
          plannedWorkSets: 0,
          completedWorkSets: 0,
          durationMinutes: 20,
          countsAs: const {},
          cardioCompletedAsPrescribed: completedAsPrescribed,
          cardioCompletion: const CardioCompletion(
            protocol: CardioProtocol.zone2Base,
            completedWorkIntervals: 1,
            completedWorkSeconds: 1200,
            completedRecoveryIntervals: 0,
            completedRecoverySeconds: 0,
            completedDurationSeconds: 1200,
          ),
        );
    final data = dataWith(
      logs: [
        recoveryLog(
          id: 'completed-recovery',
          date: DateTime(2026, 7, 15),
          completedAsPrescribed: true,
        ),
        recoveryLog(
          id: 'partial-long-plan',
          date: DateTime(2026, 7, 14),
          completedAsPrescribed: false,
        ),
      ],
    );

    await tester.pumpWidget(app(loader: (_) async => data));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        '20:00 continuous (completed recovery · no base credit)',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('20:00 continuous (partial)'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
