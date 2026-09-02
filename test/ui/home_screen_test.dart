import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/stimulus_ledger_engine.dart';
import 'package:morningcoach/engine/training_status_engine.dart';
import 'package:morningcoach/models/bouldering_log.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/history_data.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/training_targets.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/home_screen.dart';

void main() {
  Future<_RecordingHomeController> pumpHome(
    WidgetTester tester, {
    Completer<void>? saveGate,
  }) async {
    final controller = _RecordingHomeController()..saveGate = saveGate;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    return controller;
  }

  Future<void> openCompletionForm(WidgetTester tester) async {
    await tester.tap(find.text('Log unplanned REHIT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  test('home copy treats a partial workout as a saved attempt', () {
    expect(
      homeTodayStatus(
        hasTrace: true,
        sessionLogged: true,
        sessionDone: false,
      ),
      "Today's workout attempt is saved.",
    );
    expect(
      homeTodayActionLabel(
        hasTrace: true,
        sessionLogged: true,
        sessionDone: false,
      ),
      "View today's summary",
    );
  });

  test('home copy preserves check-in, ready, and completed states', () {
    expect(
      homeTodayStatus(
        hasTrace: false,
        sessionLogged: false,
        sessionDone: false,
      ),
      'No check-in yet today.',
    );
    expect(
      homeTodayActionLabel(
        hasTrace: false,
        sessionLogged: false,
        sessionDone: false,
      ),
      'Morning check-in',
    );

    expect(
      homeTodayStatus(
        hasTrace: true,
        sessionLogged: false,
        sessionDone: false,
      ),
      "Today's plan is ready.",
    );
    expect(
      homeTodayActionLabel(
        hasTrace: true,
        sessionLogged: false,
        sessionDone: false,
      ),
      "View today's plan",
    );

    expect(
      homeTodayStatus(
        hasTrace: true,
        sessionLogged: true,
        sessionDone: true,
      ),
      "Today's session is done ✅",
    );
    expect(
      homeTodayActionLabel(
        hasTrace: true,
        sessionLogged: true,
        sessionDone: true,
      ),
      "View today's summary",
    );
  });

  testWidgets('unplanned REHIT confirmation cancel does not save',
      (tester) async {
    final controller = await pumpHome(tester);

    expect(find.text('Morning check-in'), findsOneWidget);
    expect(find.text('Log unplanned REHIT'), findsOneWidget);

    await tester.tap(find.text('Log unplanned REHIT'));
    await tester.pumpAndSettle();

    expect(find.text('Log unplanned REHIT?'), findsOneWidget);
    expect(
      find.textContaining(
        'only if you have already completed the fixed CAROL REHIT Intense preset',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('appear in history'), findsOneWidget);
    expect(
      find.textContaining('count toward high-intensity recovery timing'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        "will not complete or replace today's planned workout",
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(controller.logCalls, 0);
    expect(controller.completion, isNull);
    expect(find.text('Log completed unplanned CAROL REHIT'), findsNothing);
    expect(find.text('Morning check-in'), findsOneWidget);
  });

  testWidgets('start screen logs yesterday bouldering with duration and effort',
      (tester) async {
    final controller = await pumpHome(tester);

    await tester.tap(find.byKey(const Key('home-log-bouldering')));
    await tester.pumpAndSettle();

    expect(find.text('When?'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Overall perceived effort'), findsOneWidget);
    expect(find.text('Easy'), findsOneWidget);
    expect(find.text('Moderate'), findsOneWidget);
    expect(find.text('Hard'), findsOneWidget);
    expect(
      find.textContaining('does not complete a MorningCoach workout'),
      findsOneWidget,
    );

    await tester.tap(find.text('Yesterday'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Duration (min)'),
      '95',
    );
    await tester.tap(find.text('Hard'));
    await tester.tap(find.text('Save bouldering'));
    await tester.pumpAndSettle();

    expect(controller.boulderingCalls, 1);
    expect(
      controller.boulderingDate,
      controller.today().subtract(const Duration(days: 1)),
    );
    expect(controller.boulderingDurationMinutes, 95);
    expect(controller.boulderingEffort, BoulderingEffort.hard);
    expect(
      find.text('Bouldering logged — the next plan will account for it'),
      findsOneWidget,
    );
  });

  testWidgets('completed unplanned REHIT captures structured dose and credit',
      (tester) async {
    final saveGate = Completer<void>();
    final controller = await pumpHome(tester, saveGate: saveGate);

    await openCompletionForm(tester);

    expect(
      find.text('Log completed unplanned CAROL REHIT'),
      findsOneWidget,
    );
    expect(find.text('CAROL REHIT Intense'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.widgetWithText(TextField, 'Completed intervals'),
          )
          .controller!
          .text,
      '2',
    );
    expect(
      tester
          .widget<TextField>(
            find.widgetWithText(
              TextField,
              'Duration shown by CAROL (M:SS)',
            ),
          )
          .controller!
          .text,
      '08:40',
    );
    final durationField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Duration shown by CAROL (M:SS)'),
    );
    expect(durationField.keyboardType, TextInputType.number);
    expect(find.widgetWithText(TextField, 'Average HR (optional)'), findsNothing);
    expect(find.widgetWithText(TextField, 'Peak HR (optional)'), findsNothing);
    expect(find.widgetWithText(TextField, 'RPE 0–10 (optional)'), findsNothing);
    expect(
      find.widgetWithText(TextField, 'Fitness Score (optional)'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextField, 'Peak Power (W, optional)'),
      findsOneWidget,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Duration shown by CAROL (M:SS)'),
      '0840',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Fitness Score (optional)'),
      '42.5',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Peak Power (W, optional)'),
      '734.5',
    );
    await tester.tap(find.text('Save attempt'));
    await tester.pump();

    expect(controller.logCalls, 1);
    expect(controller.completion!.protocol.type, CardioProtocolType.rehit);
    expect(controller.completion!.completedWorkIntervals, 2);
    expect(controller.completion!.completedWorkSeconds, 40);
    expect(controller.completion!.completedRecoveryIntervals, 0);
    expect(controller.completion!.completedRecoverySeconds, 0);
    expect(controller.completion!.completedDurationSeconds, 520);
    expect(controller.completion!.averageHeartRateBpm, isNull);
    expect(controller.completion!.peakHeartRateBpm, isNull);
    expect(controller.completion!.rpe, isNull);
    expect(controller.completion!.fitnessScore, 42.5);
    expect(controller.completion!.peakPowerWatts, 734.5);
    expect(controller.completion!.meetsCreditableDose, isTrue);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('home-log-unplanned-rehit')),
          )
          .onPressed,
      isNull,
    );

    saveGate.complete();
    await tester.pumpAndSettle();

    expect(
      find.text('Unplanned CAROL REHIT logged — full intensity credit ✓'),
      findsOneWidget,
    );
    expect(find.text('Morning check-in'), findsOneWidget);
  });

  testWidgets(
      'history opened while an unplanned REHIT is saving refreshes after persistence',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saveGate = Completer<void>();
    final controller = await pumpHome(tester, saveGate: saveGate);

    await openCompletionForm(tester);
    await tester.tap(find.text('Save attempt'));
    await tester.pump();
    expect(controller.logCalls, 1);

    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(find.text('No activity logged yet.'), findsOneWidget);

    saveGate.complete();
    await tester.pumpAndSettle();

    expect(find.text('S7 - full · unplanned'), findsOneWidget);
    expect(
      find.textContaining('2 sprints · 0:40 work · 8:40 total'),
      findsOneWidget,
    );
    expect(find.textContaining('1/3 DISTINCT DAYS'), findsOneWidget);
    expect(find.text('No activity logged yet.'), findsNothing);
  });

  testWidgets('below-dose unplanned REHIT is saved without credit wording',
      (tester) async {
    final controller = await pumpHome(tester);
    await openCompletionForm(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Completed intervals'),
      '1',
    );
    await tester.tap(find.text('Save attempt'));
    await tester.pumpAndSettle();

    expect(controller.logCalls, 1);
    expect(controller.completion!.completedWorkIntervals, 1);
    expect(controller.completion!.meetsCreditableDose, isFalse);
    expect(
      find.text(
        'Unplanned CAROL REHIT attempt saved — below the qualifying intensity dose',
      ),
      findsOneWidget,
    );
  });
}

class _RecordingHomeController extends AppController {
  _RecordingHomeController() : super(Repository(AppDatabase())) {
    loading = false;
  }

  int logCalls = 0;
  int boulderingCalls = 0;
  CardioCompletion? completion;
  DateTime? boulderingDate;
  int? boulderingDurationMinutes;
  BoulderingEffort? boulderingEffort;
  Completer<void>? saveGate;
  final List<SessionLog> historyLogs = [];

  @override
  DateTime today() => DateTime(2026, 9, 2);

  @override
  Future<bool> logBouldering({
    required DateTime date,
    required int durationMinutes,
    required BoulderingEffort effort,
  }) async {
    boulderingCalls += 1;
    boulderingDate = date;
    boulderingDurationMinutes = durationMinutes;
    boulderingEffort = effort;
    return false;
  }

  @override
  Future<void> logUnplannedRehit({
    required CardioCompletion completion,
  }) async {
    logCalls += 1;
    this.completion = completion;
    final gate = saveGate;
    if (gate != null) await gate.future;
    final completedAt = DateTime.now();
    historyLogs.add(
      SessionLog(
        id: 'unplanned-$logCalls',
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
        durationMinutes: (completion.completedDurationSeconds + 59) ~/ 60,
        countsAs: completion.meetsCreditableDose
            ? const {FloorCategory.intensity}
            : const {},
        cardioCompletion: completion,
        cardioCompletedAsPrescribed: completion.meetsCreditableDose,
        isSupplemental: true,
        isUnplanned: true,
      ),
    );
    notifyListeners();
  }

  @override
  Future<HistoryData> loadHistoryData({DateTime? asOf}) async {
    final effectiveAsOf = asOf ?? DateTime.now();
    final targets = TrainingTargets();
    final ledger = const StimulusLedgerEngine().buildFromSessionLogs(
      logs: historyLogs,
      asOf: effectiveAsOf,
    );
    final status = const TrainingStatusEngine().build(
      targets: targets,
      ledger: ledger,
    );
    return HistoryData(
      asOf: effectiveAsOf,
      logs: historyLogs,
      recoverySnapshots: const [],
      targets: targets,
      ledger: ledger,
      trainingStatus: status,
    );
  }
}
