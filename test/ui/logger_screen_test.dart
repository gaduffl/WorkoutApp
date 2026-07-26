import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/rehit_eligibility_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/logger_screen.dart';

void main() {
  // Single-DB achievable totals (§2.6): fine below 25, 5-lb steps above.
  const singleDb = <double>[6, 9, 10, 12, 15, 18, 20, 21, 24, 25, 30, 35, 40, 45, 50];

  PlannedExercise ex(
    String key,
    MovementPattern p,
    double load,
    int? group, {
    int sets = 3,
    bool compound = true,
  }) =>
      PlannedExercise(
        trackKey: key,
        pattern: p,
        name: key,
        sets: sets,
        targetRange: (6, 10),
        loadTotal: load,
        loadSteps: singleDb,
        rirTarget: Rir.rir2,
        supersetGroup: group,
        isCompoundWork: compound,
      );

  final plan = SessionPlan(
    sessionId: SessionTypeId.s1,
    sessionName: 'Lower',
    tier: SessionTier.full,
    estimatedDurationMin: 35,
    exercises: [
      ex('squat', MovementPattern.squat, 24, 0),
      ex('hinge', MovementPattern.hinge, 40, 0),
    ],
  );

  SessionPlan timedHoldPlan({String? instruction}) => SessionPlan(
        sessionId: SessionTypeId.s5,
        sessionName: 'Core hold',
        tier: SessionTier.full,
        estimatedDurationMin: 20,
        exercises: [
          PlannedExercise(
            trackKey: 'coreGrip',
            pattern: MovementPattern.coreGrip,
            name: 'Plank',
            sets: 1,
            metric: ExerciseMetric.seconds,
            targetRange: const (5, 5),
            rirTarget: Rir.rir2,
            instruction: instruction,
          ),
        ],
      );

  SessionPlan progressedPlankPlan() => const SessionPlan(
        sessionId: SessionTypeId.s5,
        sessionName: 'Core hold',
        tier: SessionTier.full,
        estimatedDurationMin: 20,
        exercises: [
          PlannedExercise(
            trackKey: 'coreGrip',
            pattern: MovementPattern.coreGrip,
            name: 'Plank',
            sets: 1,
            metric: ExerciseMetric.seconds,
            targetRange: (20, 60),
            suggestedValue: 60,
            progressionFraction: 0.75,
            progressionLabel: '60-second Plank · Difficulty 1 of 5',
            nextProgressionLabel: 'Next: controlled transition',
            prescriptionChange: 'Target increased: 55 → 60 seconds',
            rirTarget: Rir.rir2,
          ),
        ],
      );

  _FinisherController captureController() => _FinisherController(
        RehitEligibilityResult(
          closedReasons: const [RehitClosedReason.readinessNotGreen],
          observedAt: DateTime(2026, 7, 15, 10),
          suggestedNudgeTime: null,
        ),
      );

  testWidgets('weight stepper snaps to PowerBlock steps, not flat +5', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoggerScreen(plan: plan)));

    expect(find.text('24 lb'), findsOneWidget); // squat starts at 24
    await tester.tap(find.byIcon(Icons.add).first); // weight +
    await tester.pump();
    expect(find.text('25 lb'), findsOneWidget); // 24 -> 25 (next achievable), not 29

    await tester.tap(find.byIcon(Icons.remove).first); // weight -
    await tester.pump();
    expect(find.text('24 lb'), findsOneWidget); // back down one real step
  });

  testWidgets('logger starts Plank at 60 and shows progress/change context',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LoggerScreen(plan: progressedPlankPlan())),
    );

    expect(find.text('60'), findsOneWidget);
    expect(find.text('Progressed since last time'), findsOneWidget);
    expect(find.text('Target increased: 55 → 60 seconds'), findsOneWidget);
    expect(find.text('60-second Plank · Difficulty 1 of 5'), findsOneWidget);
    expect(find.text('Next: controlled transition'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets(
      'single-arm accessories label the stepper "Dumbbell load (single-arm, alternate arms)"',
      (tester) async {
    final controller = AppController(Repository(AppDatabase()));
    final plan = SessionPlan(
      sessionId: SessionTypeId.s5,
      sessionName: 'Flex/Pump',
      tier: SessionTier.full,
      estimatedDurationMin: 25,
      exercises: const [
        PlannedExercise(
          trackKey: 'sub:coreGrip:db_curl',
          pattern: MovementPattern.coreGrip,
          name: 'Alternating DB curl',
          sets: 2,
          targetRange: (8, 15),
          loadTotal: 20,
          dumbbellCount: 1,
          allowsUnevenPair: false,
          rirTarget: Rir.rir2,
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: plan)),
      ),
    );

    expect(
      find.text('Dumbbell load (single-arm, alternate arms)'),
      findsOneWidget,
      reason: 'The singular "Dumbbell load" wording made single-arm exercises look like '
          'a one-DB total; the parenthetical makes the alternating-arm protocol explicit.',
    );
    expect(
      find.textContaining('Alternating DB curl'),
      findsOneWidget,
      reason: 'The plan card / AppBar must surface the new canonical accessory name; '
          'the AppBar appends " - set n/N" so a contains match is the right shape.',
    );
  });

  testWidgets('Wrist curls renders as a matched pair, not single-arm',
      (tester) async {
    final controller = AppController(Repository(AppDatabase()));
    final plan = SessionPlan(
      sessionId: SessionTypeId.s5,
      sessionName: 'Flex/Pump',
      tier: SessionTier.full,
      estimatedDurationMin: 25,
      exercises: const [
        PlannedExercise(
          trackKey: 'coreGrip',
          pattern: MovementPattern.coreGrip,
          name: 'Wrist curls',
          sets: 2,
          targetRange: (8, 15),
          loadTotal: 48,
          dumbbellCount: 2,
          allowsUnevenPair: true,
          loadSteps: [24, 36, 40, 42, 48, 50],
          rirTarget: Rir.rir2,
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: plan)),
      ),
    );

    expect(
      find.text('Dumbbells'),
      findsOneWidget,
      reason: 'Wrist curls is bilateral (one DB per wrist); the matched-pair '
          'header is "Dumbbells", not the single-arm "Dumbbell load".',
    );
    expect(
      find.text('Dumbbell load (single-arm, alternate arms)'),
      findsNothing,
    );
    expect(find.text('2 × 24 lb (48 lb total; small pair)'), findsOneWidget);
  });

  testWidgets('logger presents Goblet as one DB and deadlift as a matched pair',
      (tester) async {
    final controller = AppController(Repository(AppDatabase()));
    final physicalPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Physical loads',
      tier: SessionTier.full,
      estimatedDurationMin: 20,
      exercises: const [
        PlannedExercise(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          name: 'Goblet squat',
          sets: 1,
          targetRange: (6, 10),
          loadTotal: 24,
          dumbbellCount: 1,
          allowsUnevenPair: false,
          rirTarget: Rir.rir2,
        ),
        PlannedExercise(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          name: 'Elevated-start DB deadlift (on blocks)',
          sets: 1,
          targetRange: (6, 10),
          loadTotal: 48,
          dumbbellCount: 2,
          allowsUnevenPair: true,
          loadSteps: [12, 18, 20, 24, 30, 36, 40, 42, 48, 50],
          rirTarget: Rir.rir2,
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: physicalPlan)),
      ),
    );

    expect(find.text('1 × 24 lb (small dumbbell)'), findsOneWidget);
    await tester.tap(find.text('Log set'));
    await tester.pump();
    expect(find.text('2 × 24 lb (48 lb total; small pair)'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pump();
    // Total advances 48 -> 50, but the visible setup advances 24 -> 25 per DB.
    expect(find.text('2 × 25 lb (50 lb total; large pair)'), findsOneWidget);
  });

  testWidgets('paired setup increment persists the unchanged total-load domain',
      (tester) async {
    final controller = captureController();
    final pairedPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Paired load',
      tier: SessionTier.full,
      estimatedDurationMin: 20,
      exercises: const [
        PlannedExercise(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          name: 'Elevated-start DB deadlift (on blocks)',
          sets: 1,
          targetRange: (6, 10),
          loadTotal: 48,
          dumbbellCount: 2,
          allowsUnevenPair: false,
          loadSteps: [12, 18, 20, 24, 30, 36, 40, 42, 48, 50],
          rirTarget: Rir.rir2,
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: pairedPlan)),
      ),
    );

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pump();
    await tester.tap(find.text('Log set & finish'));
    await tester.pumpAndSettle();

    expect(controller.lastLoggedSets.single.weight, 50);
  });

  testWidgets(
      'an active uneven-pair plan keeps its 24/25 setup after settings disable uneven mode',
      (tester) async {
    final controller = captureController();
    controller.settings = controller.settings.copyWith(
      equipment: controller.settings.equipment.copyWith(
        unevenPairModeEnabled: false,
      ),
    );
    final unevenPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Uneven paired load',
      tier: SessionTier.full,
      estimatedDurationMin: 20,
      exercises: const [
        PlannedExercise(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          name: 'Elevated-start DB deadlift (on blocks)',
          sets: 1,
          targetRange: (6, 10),
          loadTotal: 49,
          loadSteps: [48, 49, 50],
          dumbbellCount: 2,
          allowsUnevenPair: true,
          rirTarget: Rir.rir2,
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: unevenPlan)),
      ),
    );

    expect(
      find.text('L: 24 / R: 25 (49 lb total), swap after each set'),
      findsOneWidget,
    );
    await tester.tap(find.text('Log set & finish'));
    await tester.pumpAndSettle();
    expect(controller.lastLoggedSets.single.weight, 49);
  });

  testWidgets('two-DB load setup fits a narrow phone without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController(Repository(AppDatabase()));
    final pairedPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Paired load',
      tier: SessionTier.full,
      estimatedDurationMin: 20,
      exercises: const [
        PlannedExercise(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          name: 'Elevated-start DB deadlift (on blocks)',
          sets: 1,
          targetRange: (6, 10),
          loadTotal: 48,
          dumbbellCount: 2,
          allowsUnevenPair: false,
          rirTarget: Rir.rir2,
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: pairedPlan)),
      ),
    );

    expect(find.text('2 × 24 lb (48 lb total; small pair)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('superset pair is indicated and can be toggled to straight sets', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoggerScreen(plan: plan)));

    expect(find.text('Superset mode'), findsOneWidget);
    // first work step is squat, alternating into hinge
    expect(find.textContaining('Superset — next: hinge'), findsOneWidget);

    // turn superset off -> straight sets, no partner chip
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.textContaining('Superset — next:'), findsNothing);
  });

  testWidgets('logger displays a deterministic pain-adjustment cue',
      (tester) async {
    const cue =
        'This substitute starts deliberately light. Use a pain-free range and stop if pain worsens.';
    final painPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Pain-adjusted strength',
      tier: SessionTier.compressed,
      estimatedDurationMin: 20,
      exercises: [
        PlannedExercise(
          trackKey: 'sub:hinge:bridge_hamstring_curl',
          pattern: MovementPattern.hinge,
          name: 'Bridge hamstring curl',
          sets: 1,
          targetRange: const (8, 15),
          rirTarget: Rir.rir2,
          instruction: cue,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: LoggerScreen(plan: painPlan)),
    );

    expect(find.text(cue), findsOneWidget);
  });

  testWidgets('last set flips the button to finish and hides early-finish', (tester) async {
    // 1 set each so the only non-last step is the superset partner (no rest
    // timer starts, keeping the test free of pending timers).
    final onePlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Lower',
      tier: SessionTier.full,
      estimatedDurationMin: 35,
      exercises: [
        ex('squat', MovementPattern.squat, 24, 0, sets: 1),
        ex('hinge', MovementPattern.hinge, 40, 0, sets: 1),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: LoggerScreen(plan: onePlan)));

    expect(find.text('Log set'), findsOneWidget);
    expect(find.text('Finish early'), findsOneWidget);

    await tester.tap(find.text('Log set')); // log squat, advance to last step
    await tester.pump();

    expect(find.text('Log set & finish'), findsOneWidget);
    expect(find.text('Finish early'), findsNothing);
  });

  testWidgets('loaded rep warm-ups and feeders receive 45 seconds rest',
      (tester) async {
    final rampPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Lower',
      tier: SessionTier.compressed,
      estimatedDurationMin: 20,
      exercises: [
        const PlannedExercise(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          name: 'Goblet squat - warm-up 50%',
          sets: 1,
          targetRange: (5, 5),
          loadTotal: 12,
          rirTarget: Rir.rir3plus,
          isWarmup: true,
        ),
        const PlannedExercise(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          name: 'Romanian deadlift - warm-up 60%',
          sets: 1,
          targetRange: (5, 5),
          loadTotal: 30,
          rirTarget: Rir.rir3plus,
          isWarmup: true,
          isFeederWarmup: true,
        ),
        ex('squat', MovementPattern.squat, 24, null, sets: 1),
      ],
    );

    await tester.pumpWidget(MaterialApp(home: LoggerScreen(plan: rampPlan)));

    await tester.tap(find.text('Log warm-up'));
    await tester.pump();
    expect(find.text('Rest: 45 s'), findsOneWidget);

    await tester.tap(find.text('Log warm-up'));
    await tester.pump();
    expect(find.text('Rest: 45 s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('minute-based general prep transitions without artificial rest',
      (tester) async {
    final prepPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Lower',
      tier: SessionTier.compressed,
      estimatedDurationMin: 20,
      exercises: [
        const PlannedExercise(
          trackKey: 'warmup:s1',
          pattern: MovementPattern.kneeHealth,
          name: 'General warm-up & movement prep',
          sets: 1,
          metric: ExerciseMetric.minutes,
          targetRange: (3, 3),
          rirTarget: Rir.rir4plus,
          isWarmup: true,
        ),
        ex('squat', MovementPattern.squat, 24, null, sets: 1),
      ],
    );

    await tester.pumpWidget(MaterialApp(home: LoggerScreen(plan: prepPlan)));
    await tester.tap(find.text('Log warm-up'));
    await tester.pump();

    expect(find.textContaining('Rest:'), findsNothing);
  });

  testWidgets('work rests remain 60 seconds accessory and 90 compound',
      (tester) async {
    final accessoryPlan = SessionPlan(
      sessionId: SessionTypeId.s5,
      sessionName: 'Pump',
      tier: SessionTier.compressed,
      estimatedDurationMin: 20,
      exercises: [
        ex(
          'lateral raise',
          MovementPattern.pushVertical,
          12,
          null,
          sets: 2,
          compound: false,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(home: LoggerScreen(plan: accessoryPlan)),
    );
    await tester.tap(find.text('Log set'));
    await tester.pump();
    expect(find.text('Rest: 60 s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    final compoundPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Lower',
      tier: SessionTier.compressed,
      estimatedDurationMin: 20,
      exercises: [
        ex(
          'squat',
          MovementPattern.squat,
          24,
          null,
          sets: 2,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(home: LoggerScreen(plan: compoundPlan)),
    );
    await tester.tap(find.text('Log set'));
    await tester.pump();
    expect(find.text('Rest: 90 s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the final overall step never starts a rest timer',
      (tester) async {
    final controller = captureController();
    final finalStepPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Lower',
      tier: SessionTier.compressed,
      estimatedDurationMin: 20,
      exercises: [
        ex('squat', MovementPattern.squat, 24, null, sets: 1),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: finalStepPlan)),
      ),
    );

    await tester.tap(find.text('Log set & finish'));
    await tester.pumpAndSettle();

    expect(controller.completed, isTrue);
    expect(find.textContaining('Rest:'), findsNothing);
  });

  testWidgets('paused hold logs elapsed seconds and shows the progression cue',
      (tester) async {
    const cue =
        'Micro-progression - controlled transition: enter and leave the hold slowly, then keep a strict position';
    final controller = captureController();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: timedHoldPlan(instruction: cue))),
      ),
    );

    expect(find.text(cue), findsOneWidget);
    await tester.tap(find.text('Start hold'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('3 s'), findsOneWidget);
    await tester.tap(find.text('Pause'));
    await tester.pump();
    await tester.tap(find.text('Log hold & finish'));
    await tester.pump();

    expect(controller.lastLoggedSets, hasLength(1));
    expect(controller.lastLoggedSets.single.metric, ExerciseMetric.seconds);
    expect(controller.lastLoggedSets.single.value, 2);
  });

  testWidgets('completed hold countdown logs the full selected target',
      (tester) async {
    final controller = captureController();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: timedHoldPlan())),
      ),
    );

    await tester.tap(find.text('Start hold'));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('0 s'), findsOneWidget);
    await tester.tap(find.text('Log hold & finish'));
    await tester.pump();

    expect(controller.lastLoggedSets.single.value, 5);
  });

  testWidgets('an immediate timer stop cannot log zero and reset restores manual entry',
      (tester) async {
    final controller = captureController();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: timedHoldPlan())),
      ),
    );

    await tester.tap(find.text('Start hold'));
    await tester.pump();
    final zeroButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Log hold & finish'),
    );
    expect(zeroButton.onPressed, isNull);
    expect(controller.lastLoggedSets, isEmpty);

    await tester.tap(find.byTooltip('Reset hold timer'));
    await tester.pump();
    final manualButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Log hold & finish'),
    );
    expect(manualButton.onPressed, isNotNull);
    await tester.tap(find.text('Log hold & finish'));
    await tester.pump();
    expect(controller.lastLoggedSets.single.value, 5);
  });

  testWidgets('changing the seconds value leaves countdown mode for manual entry',
      (tester) async {
    final controller = captureController();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: timedHoldPlan())),
      ),
    );

    await tester.tap(find.text('Start hold'));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(find.text('10 s'), findsOneWidget);
    expect(find.text('Start hold'), findsOneWidget);
    await tester.tap(find.text('Log hold & finish'));
    await tester.pump();

    expect(controller.lastLoggedSets.single.value, 10);
  });

  testWidgets('rep work keeps the manually selected value', (tester) async {
    final controller = captureController();
    final repPlan = SessionPlan(
      sessionId: SessionTypeId.s5,
      sessionName: 'Rep work',
      tier: SessionTier.full,
      estimatedDurationMin: 20,
      exercises: [
        PlannedExercise(
          trackKey: 'curl',
          pattern: MovementPattern.coreGrip,
          name: 'Curl',
          sets: 1,
          targetRange: const (8, 12),
          rirTarget: Rir.rir2,
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: repPlan)),
      ),
    );

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.tap(find.text('Log set & finish'));
    await tester.pump();

    expect(controller.lastLoggedSets.single.metric, ExerciseMetric.reps);
    expect(controller.lastLoggedSets.single.value, 9);
  });

  SessionPlan s2Plan(int sets) => SessionPlan(
        sessionId: SessionTypeId.s2,
        sessionName: 'Upper Strength',
        tier: SessionTier.extended,
        estimatedDurationMin: 60,
        optionalRehitFinisherReserved: true,
        exercises: [
          ex(
            'push',
            MovementPattern.pushHorizontal,
            24,
            null,
            sets: sets,
          ),
        ],
      );

  testWidgets('safe completed S2 opens the structured finisher dialog',
      (tester) async {
    final now = DateTime(2026, 7, 15, 10);
    final controller = _FinisherController(
      RehitEligibilityResult(
        closedReasons: const [],
        observedAt: now,
        suggestedNudgeTime: DateTime(2026, 7, 15, 15),
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: LoggerScreen(plan: s2Plan(1))),
      ),
    );
    await tester.tap(find.text('Log set & finish'));
    await tester.pumpAndSettle();

    expect(find.text('Log optional REHIT finisher'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.completed, isTrue);
    expect(controller.lastEndedEarly, isFalse);
  });

  testWidgets('unsafe or early S2 completion never opens finisher dialog',
      (tester) async {
    final now = DateTime(2026, 7, 15, 10);
    final unsafe = _FinisherController(
      RehitEligibilityResult(
        closedReasons: const [RehitClosedReason.readinessNotGreen],
        observedAt: now,
        suggestedNudgeTime: null,
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: unsafe,
        child: MaterialApp(home: LoggerScreen(plan: s2Plan(1))),
      ),
    );
    await tester.tap(find.text('Log set & finish'));
    await tester.pumpAndSettle();
    expect(find.text('Log optional REHIT finisher'), findsNothing);
    expect(unsafe.completed, isTrue);

    final nominallySafe = _FinisherController(
      RehitEligibilityResult(
        closedReasons: const [],
        observedAt: now,
        suggestedNudgeTime: DateTime(2026, 7, 15, 15),
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: nominallySafe,
        child: MaterialApp(
          home: LoggerScreen(
            key: const ValueKey('early-s2'),
            plan: s2Plan(2),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Finish early'));
    await tester.pumpAndSettle();
    // Confirmation dialog appears first — confirm to proceed
    await tester.tap(find.text('End workout'));
    await tester.pumpAndSettle();
    expect(find.text('Log optional REHIT finisher'), findsNothing);
    expect(nominallySafe.lastEndedEarly, isTrue);
  });
}

class _FinisherController extends AppController {
  final RehitEligibilityResult baseEligibility;
  bool completed = false;
  bool? lastEndedEarly;
  List<SetLog> lastLoggedSets = [];

  _FinisherController(this.baseEligibility)
      : super(Repository(AppDatabase()));

  @override
  RehitEligibilityResult rehitFinisherEligibility(
    SessionPlan plan,
    List<SetLog> loggedSets, {
    bool endedEarly = false,
    DateTime? nowLocal,
  }) {
    lastEndedEarly = endedEarly;
    if (endedEarly) {
      return RehitEligibilityResult(
        closedReasons: const [RehitClosedReason.firstSessionEarlyAbort],
        observedAt: baseEligibility.observedAt,
        suggestedNudgeTime: null,
      );
    }
    return baseEligibility;
  }

  @override
  Future<void> completeSession(
    SessionPlan plan,
    List<SetLog> loggedSets, {
    required int durationMinutes,
    CardioCompletion? cardioCompletion,
    CardioCompletion? rehitFinisherCompletion,
    bool endedEarly = false,
  }) async {
    completed = true;
    lastEndedEarly = endedEarly;
    lastLoggedSets = List.of(loggedSets);
  }
}
