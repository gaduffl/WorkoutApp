import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/logger_screen.dart';
import 'package:provider/provider.dart';

Widget appWithPlan(SessionPlan plan) {
  final controller = AppController(Repository(AppDatabase()));
  return ChangeNotifierProvider<AppController>.value(
    value: controller,
    child: MaterialApp(
      home: LoggerScreen(plan: plan),
    ),
  );
}

void main() {
  testWidgets('finish early shows confirmation dialog', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final plan = SessionPlan(
      sessionId: SessionTypeId.s1,
      tier: SessionTier.full,
      exercises: [
        PlannedExercise(
          trackKey: 'pushHorizontal1',
          pattern: MovementPattern.pushHorizontal,
          name: 'Dumbbell Bench Press',
          sets: 3,
          metric: ExerciseMetric.reps,
          targetRange: (8, 12),
          rirTarget: Rir.rir2,
          loadTotal: 40,
        ),
      ],
      estimatedDurationMin: 45,
    );

    await tester.pumpWidget(appWithPlan(plan));
    await tester.pumpAndSettle();

    // Find and tap the Wrap up button in the app bar
    final wrapUp = find.text('Wrap up');
    expect(wrapUp, findsOneWidget);
    await tester.tap(wrapUp);
    await tester.pumpAndSettle();

    // Dialog should appear
    expect(find.text('Finish workout early?'), findsOneWidget);
    expect(
      find.textContaining('End the session now'),
      findsOneWidget,
    );

    // Cancel returns to the workout
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Wrap up'), findsOneWidget);
    expect(find.text('Finish workout early?'), findsNothing);

    // Tap again and confirm
    await tester.tap(wrapUp);
    await tester.pumpAndSettle();
    await tester.tap(find.text('End workout'));
    await tester.pumpAndSettle();
  });
}