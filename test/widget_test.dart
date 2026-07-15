import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/ui/screens/checkin_screen.dart';
import 'package:morningcoach/ui/screens/logger_screen.dart';

/// Widget-level smoke test for the check-in screen. Deliberately avoids
/// calling `AppController.init()` (which opens the on-device sqflite
/// database) - platform-channel database access isn't meaningful to
/// exercise from a headless widget test, and the engine itself (the part
/// worth testing in depth) has its own pure-Dart suite under test/engine/.
void main() {
  testWidgets('Check-in screen shows the core controls', (WidgetTester tester) async {
    final controller = AppController(Repository(AppDatabase()));

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: CheckInScreen()),
      ),
    );

    expect(find.text('Ready to plan today?'), findsOneWidget);
    expect(find.text('20 min'), findsOneWidget);
    expect(find.text('35 min'), findsOneWidget);
    expect(find.text('60 min'), findsOneWidget);
    expect(find.text('Get my plan'), findsOneWidget);

    // No time slot chosen yet - submit stays disabled.
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);

    await tester.tap(find.text('35 min'));
    await tester.pump();

    final buttonAfter = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(buttonAfter.onPressed, isNotNull);
  });

  testWidgets('travel logger shows context and starts at the prescribed RIR', (WidgetTester tester) async {
    final controller = AppController(Repository(AppDatabase()));
    const plan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Strength — Lower',
      tier: SessionTier.full,
      estimatedDurationMin: 35,
      travelMode: true,
      exercises: [
        PlannedExercise(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          name: 'Split squat (bodyweight)',
          sets: 2,
          repRange: (8, 15),
          rirTarget: Rir.rir4plus,
          isTravel: true,
          progressionEligible: false,
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: LoggerScreen(plan: plan)),
      ),
    );

    expect(find.text('Travel · no equipment'), findsOneWidget);
    expect(find.text('Bodyweight'), findsOneWidget);
    final rir4 = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'RIR 4+'),
    );
    expect(rir4.selected, isTrue);
  });

  testWidgets('timed hold logger uses seconds and exposes a countdown', (WidgetTester tester) async {
    final controller = AppController(Repository(AppDatabase()));
    const plan = SessionPlan(
      sessionId: SessionTypeId.s5,
      sessionName: 'Flex / Pump',
      tier: SessionTier.full,
      estimatedDurationMin: 35,
      exercises: [
        PlannedExercise(
          trackKey: 'coreGrip',
          pattern: MovementPattern.coreGrip,
          name: 'Plank',
          sets: 2,
          metric: ExerciseMetric.seconds,
          targetRange: (20, 45),
          rirTarget: Rir.rir2,
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: LoggerScreen(plan: plan)),
      ),
    );

    expect(find.text('Target: 20-45 seconds'), findsOneWidget);
    expect(find.text('Seconds'), findsOneWidget);
    expect(find.text('Start hold'), findsOneWidget);
    expect(find.text('Reps'), findsNothing);
  });
}
