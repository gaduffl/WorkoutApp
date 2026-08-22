import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/cardio_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/today_screen.dart';
import 'package:morningcoach/ui/widgets/cardio_widgets.dart';

void main() {
  const cardio = CardioEngine();

  test('CAROL duration formatter inserts a colon and preserves editing', () {
    const formatter = CarolDurationInputFormatter();
    const empty = TextEditingValue();
    final entered = formatter.formatEditUpdate(
      empty,
      const TextEditingValue(
        text: '0840',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    expect(entered.text, '08:40');
    expect(entered.selection.baseOffset, 5);

    final edited = formatter.formatEditUpdate(
      entered,
      const TextEditingValue(
        text: '08:4',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    expect(edited.text, '08:4');

    final rejected = formatter.formatEditUpdate(
      entered,
      const TextEditingValue(text: '08x40'),
    );
    expect(rejected, entered);
  });

  test('summary copy distinguishes all three cardio stimuli', () {
    final fourByFour = cardioPrescriptionSummaryLines(cardio.prescriptionFor(
      sessionId: SessionTypeId.s3,
      durationMinutes: 30,
      heartRateMaxBpm: 200,
    ));
    expect(fourByFour, contains(carolFourByFourInstruction));
    expect(
      fourByFour,
      contains('Coaching target: 170–190 bpm · RPE 8–9'),
    );
    expect(
      fourByFour,
      contains('Talk test: only a few words during work intervals'),
    );
    expect(cardioProtocolTimeline(cardio.prescriptionFor(
      sessionId: SessionTypeId.s3,
      durationMinutes: 30,
      heartRateMaxBpm: 200,
    )), isEmpty);

    final base = cardioPrescriptionSummaryLines(cardio.prescriptionFor(
      sessionId: SessionTypeId.s6,
      durationMinutes: 60,
      heartRateMaxBpm: 200,
    ));
    expect(base, contains('Continuous 60 min'));
    expect(base, contains('Target: 130–150 bpm · RPE 3–4'));
    expect(
      base,
      contains('Talk test: full sentences with controlled breathing'),
    );
    expect(
      base,
      contains(
        '0:00–60:00 · Ride continuously in Zone 2.\nStart near 130 bpm; adjust resistance/cadence to stay at 130–150 bpm (RPE 3–4).',
      ),
    );
    expect(
      base.join('\n'),
      isNot(
        contains('Continuous: ease into target effort within the prescribed duration'),
      ),
    );
    final recoveryBase = cardioPrescriptionSummaryLines(cardio.prescriptionFor(
      sessionId: SessionTypeId.s6,
      durationMinutes: 20,
      heartRateMaxBpm: 200,
    ));
    expect(
      recoveryBase,
      contains('Recovery dose: below the 30-min base-credit threshold'),
    );

    final rehit = cardioPrescriptionSummaryLines(cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 9,
      heartRateMaxBpm: 200,
    ));
    expect(rehit, contains(carolRehitInstruction));
    expect(rehit, contains('Coaching target: RPE 9–10'));
    expect(
      rehit,
      contains('Talk test: talking is not possible during the sprints'),
    );
    expect(cardioProtocolTimeline(cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 9,
      heartRateMaxBpm: 200,
    )), isEmpty);

    final appFacingCopy = [...fourByFour, ...rehit].join('\n');
    for (final forbidden in [
      'Progressive ramp',
      'Easy build',
      '5-minute ramp',
      '3-minute build',
      '10-min REHIT',
    ]) {
      expect(appFacingCopy, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('only app-timed Zone 2 exposes a protocol timeline',
      () {
    final fourByFourPrescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s3,
      durationMinutes: 30,
      heartRateMaxBpm: 200,
    );
    final fourByFour = cardioProtocolTimeline(fourByFourPrescription);
    expect(fourByFour, isEmpty);

    final rehitPrescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 9,
      heartRateMaxBpm: 200,
    );
    final rehit = cardioProtocolTimeline(rehitPrescription);
    expect(rehit, isEmpty);

    final recoveryPrescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s6,
      durationMinutes: 20,
      heartRateMaxBpm: 200,
    );
    final recovery = cardioProtocolTimeline(recoveryPrescription);
    expect(recovery.map((segment) => segment.durationSeconds), [1200]);
    expect(
      recovery.single.label,
      'Ride continuously in Zone 2.\nStart near 130 bpm; adjust resistance/cadence to stay at 130–150 bpm (RPE 3–4).',
    );
    expect(
      recovery.single.summaryLine,
      '0:00–20:00 · Ride continuously in Zone 2.\nStart near 130 bpm; adjust resistance/cadence to stay at 130–150 bpm (RPE 3–4).',
    );
    expect(recovery.single.summaryLine, isNot(contains('warm-up')));

    for (final minutes in [20, 35, 60]) {
      final timeline = cardioProtocolTimeline(cardio.prescriptionFor(
        sessionId: SessionTypeId.s6,
        durationMinutes: minutes,
        heartRateMaxBpm: 200,
      ));
      expect(timeline, hasLength(1));
      expect(
        timeline.single.summaryLine,
        '0:00–$minutes:00 · Ride continuously in Zone 2.\nStart near 130 bpm; adjust resistance/cadence to stay at 130–150 bpm (RPE 3–4).',
      );
      expect(timeline.single.summaryLine, isNot(contains('warm-up')));
      expect(timeline.single.summaryLine, isNot(contains('Warm-up')));
    }

    const noTargetPrescription = CardioPrescription(
      protocol: CardioProtocol.zone2Base,
      plannedWorkIntervals: 1,
      plannedWorkSeconds: 20 * 60,
      plannedRecoveryIntervals: 0,
      plannedRecoverySeconds: 0,
      plannedDurationSeconds: 20 * 60,
    );
    expect(
      cardioProtocolTimeline(noTargetPrescription).single.summaryLine,
      '0:00–20:00 · Ride continuously in Zone 2.\nAdjust resistance/cadence as needed to keep the effort comfortably sustainable.',
    );
  });

  testWidgets('Zone 2 card shows a self-contained continuous target',
      (tester) async {
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s6,
      durationMinutes: 35,
      heartRateMaxBpm: 180,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CardioPrescriptionCard(prescription: prescription),
        ),
      ),
    );

    expect(
      find.text(
        '0:00–35:00 · Ride continuously in Zone 2.\nStart near 117 bpm; adjust resistance/cadence to stay at 117–135 bpm (RPE 3–4).',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Warm-up'), findsNothing);
  });

  test('Today labels non-target S6 as recovery rather than queue work', () {
    const candidate = ScoredCandidate(
      sessionId: SessionTypeId.s6,
      tier: SessionTier.compressed,
      score: 10,
      scoreTerms: {'base': 10},
    );

    expect(
      candidateReason(candidate),
      'Easy recovery cardio that fits today\'s available time',
    );
  });

  testWidgets('Today shows the prescription and opens an explicit completion form', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController(Repository(AppDatabase()));
    final now = DateTime.now();
    final date = DateTime(now.year, now.month, now.day);
    final trace = DecisionTrace(
      date: date,
      checkin: CheckIn(
        date: date,
        timeMinutes: 35,
        subjective: 4,
        timestamp: date,
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
      plan: SessionPlan(
        sessionId: SessionTypeId.s3,
        sessionName: 'Norwegian 4x4 (CAROL)',
        tier: SessionTier.full,
        exercises: const [],
        estimatedDurationMin: 35,
        // Legacy persisted plans had no prescription. Today must reconstruct
        // and display it while still requiring structured completion entry.
      ),
      queue: const QueueTraceInfo(
        pointerBefore: SessionTypeId.s3,
        servedBefore: {},
      ),
    );
    controller.todayTrace = trace;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: TodayScreen(trace: trace)),
      ),
    );
    await tester.pump();

    expect(find.text(carolFourByFourInstruction), findsOneWidget);
    expect(find.text('CAROL bike preset · 30 min'), findsOneWidget);
    expect(find.textContaining('Timeline'), findsNothing);
    expect(find.textContaining('Warm-up'), findsNothing);
    expect(find.textContaining('Mark Norwegian 4x4'), findsNothing);
    expect(find.text('Log cardio attempt'), findsOneWidget);

    await tester.ensureVisible(find.text('Log cardio attempt'));
    await tester.tap(find.text('Log cardio attempt'));
    await tester.pumpAndSettle();

    expect(
      find.text('Log CAROL 4×4 Norwegian Zone 5 Intervals attempt'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextField, 'Completed intervals'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Duration shown by CAROL (M:SS)'),
      findsOneWidget,
    );
    final durationField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Duration shown by CAROL (M:SS)'),
    );
    expect(durationField.controller!.text, '30:00');
    expect(durationField.keyboardType, TextInputType.number);
    expect(
      durationField.inputFormatters,
      contains(isA<CarolDurationInputFormatter>()),
    );
    expect(find.widgetWithText(TextField, 'Average HR (optional)'), findsNothing);
    expect(find.widgetWithText(TextField, 'Peak HR (optional)'), findsNothing);
    expect(find.widgetWithText(TextField, 'RPE 0–10 (optional)'), findsNothing);
    expect(
      find.widgetWithText(TextField, 'Fitness Score (optional)'),
      findsNothing,
    );
    expect(
      find.widgetWithText(TextField, 'Peak Power (W, optional)'),
      findsNothing,
    );
    expect(find.text('Save attempt'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('REHIT card delegates the actionable sequence to CAROL',
      (tester) async {
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 9,
      heartRateMaxBpm: 200,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CardioPrescriptionCard(prescription: prescription),
        ),
      ),
    );

    expect(find.text(carolRehitInstruction), findsOneWidget);
    expect(find.text('Coaching target: RPE 9–10'), findsOneWidget);
    expect(find.textContaining('Timeline'), findsNothing);
    expect(find.textContaining('Easy recovery'), findsNothing);
  });

  testWidgets('Zone 2 keeps its optional HR and RPE feedback fields',
      (tester) async {
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s6,
      durationMinutes: 35,
      heartRateMaxBpm: 200,
    );
    await tester.pumpWidget(
      MaterialApp(home: _CompletionDialogHost(prescription: prescription)),
    );

    await tester.tap(find.text('Open completion form'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Average HR (optional)'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Peak HR (optional)'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'RPE 0–10 (optional)'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Fitness Score (optional)'),
      findsNothing,
    );
    expect(
      find.widgetWithText(TextField, 'Peak Power (W, optional)'),
      findsNothing,
    );
  });

  testWidgets('Zone 2 completion accepts more than 60 minutes',
      (tester) async {
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s6,
      durationMinutes: 60,
      heartRateMaxBpm: 200,
    );
    await tester.pumpWidget(
      MaterialApp(home: _CompletionDialogHost(prescription: prescription)),
    );

    await tester.tap(find.text('Open completion form'));
    await tester.pumpAndSettle();
    expect(
      find.text('Actual ride time; may exceed the plan'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Duration (min)'),
      '90',
    );
    await tester.tap(find.text('Save attempt'));
    await tester.pumpAndSettle();

    expect(find.text('Accepted: 90:00'), findsOneWidget);
  });

  testWidgets('CAROL completion form defaults to bike preset duration',
      (tester) async {
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 9,
      heartRateMaxBpm: 200,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: _CompletionDialogHost(prescription: prescription),
      ),
    );

    Future<void> openDialog() async {
      await tester.tap(find.text('Open completion form'));
      await tester.pumpAndSettle();
    }

    Future<void> enterAttempt(String duration) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'Completed intervals'),
        '2',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Duration shown by CAROL (M:SS)'),
        duration,
      );
      await tester.tap(find.text('Save attempt'));
      await tester.pumpAndSettle();
    }

    await openDialog();
    final defaultDuration = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Duration shown by CAROL (M:SS)'),
    );
    expect(defaultDuration.controller!.text, '08:40');
    expect(defaultDuration.keyboardType, TextInputType.number);
    await enterAttempt('084');
    expect(defaultDuration.controller!.text, '08:4');
    expect(find.textContaining('seconds 00–59'), findsOneWidget);
    await enterAttempt('0860');
    expect(defaultDuration.controller!.text, '08:60');
    expect(find.textContaining('seconds 00–59'), findsOneWidget);
    await enterAttempt('0840');
    expect(find.text('Accepted: 8:40'), findsOneWidget);

    await openDialog();
    await tester.tap(find.text('Save attempt'));
    await tester.pumpAndSettle();
    expect(find.text('Accepted: 8:40'), findsOneWidget);
  });
}

class _CompletionDialogHost extends StatefulWidget {
  final CardioPrescription prescription;

  const _CompletionDialogHost({required this.prescription});

  @override
  State<_CompletionDialogHost> createState() =>
      _CompletionDialogHostState();
}

class _CompletionDialogHostState extends State<_CompletionDialogHost> {
  CardioCompletion? _completion;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(
          children: [
            FilledButton(
              onPressed: () async {
                final completion = await showCardioCompletionDialog(
                  context,
                  prescription: widget.prescription,
                );
                if (!mounted || completion == null) return;
                setState(() => _completion = completion);
              },
              child: const Text('Open completion form'),
            ),
            if (_completion != null)
              Text(
                'Accepted: '
                '${_completion!.completedDurationSeconds ~/ 60}:'
                '${(_completion!.completedDurationSeconds % 60).toString().padLeft(2, '0')}',
              ),
          ],
        ),
      );
}
