import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/stimulus_ledger_engine.dart';
import 'package:morningcoach/engine/training_status_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/history_data.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/training_targets.dart';
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

  Widget app({required HistoryDataLoader loader}) {
    final controller = AppController(Repository(AppDatabase()));
    return ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: MaterialApp(home: HistoryScreen(loadData: loader)),
    );
  }

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
    expect(find.text('Norwegian 4×4 anchor'), findsOneWidget);
    expect(find.text('REHIT fallback'), findsOneWidget);
    expect(find.text('60m base exposure'), findsOneWidget);
    expect(find.text('30/35m base exposure'), findsOneWidget);
    expect(
      find.textContaining(
        'Temporary fallback only · does not equal 4×4 or base work',
      ),
      findsOneWidget,
    );

    // The obsolete weekly-floor card is replaced; the useful history views
    // remain below the evidence-target dashboard.
    expect(find.text('Rolling 7-day floor'), findsNothing);
    expect(find.text('Last 12 weeks'), findsOneWidget);
    expect(find.text('Progression (top set, 12 weeks)'), findsOneWidget);
    expect(find.text('HRV, last 28 days'), findsOneWidget);
    expect(find.text('No sessions logged yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('4x4 anchor makes the REHIT fallback explicitly not needed',
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

    expect(find.textContaining('Anchor met'), findsOneWidget);
    expect(
      find.textContaining('Not needed — 4×4 anchor met'),
      findsOneWidget,
    );
    expect(
      find.textContaining('0/2 exposures · 0/2 distinct days'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Temporary fallback only · does not equal 4×4 or base work',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'distinct-day REHIT fallback covers the weekly target while 4x4 count stays separate',
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
      ],
    );

    await tester.pumpWidget(app(loader: (_) async => data));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        '0/1 in trailing 7d\nNot currently needed — REHIT fallback met',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('2/2 exposures · 2/2 distinct days'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Fallback met — weekly high-intensity target covered for now',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('1 anchor remaining'), findsNothing);
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
      find.textContaining('2 sprints · 0:40 work · 8:00 total'),
      findsOneWidget,
    );
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
