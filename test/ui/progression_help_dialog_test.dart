import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/settings_screen.dart';
import 'package:morningcoach/ui/widgets/progression_panel.dart';
import 'package:provider/provider.dart';

void main() {
  Widget testWidget(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  Widget settingsApp() {
    final controller = AppController(Repository(AppDatabase()));
    return ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: const MaterialApp(home: SettingsScreen()),
    );
  }

  const sampleExercise = PlannedExercise(
    trackKey: 'pushHorizontal',
    pattern: MovementPattern.pushHorizontal,
    name: 'Dumbbell Bench Press',
    sets: 3,
    metric: ExerciseMetric.reps,
    targetRange: (8, 12),
    rirTarget: Rir.rir2,
    loadTotal: 40,
    progressionFraction: 0.5,
    progressionLabel: '40 lb · Stage 1',
    nextProgressionLabel: 'Next: Stage 2',
    prescriptionChange: 'Target increased since last time',
  );

  testWidgets('ProgressionPanel displays info icon and opens Progression Rules dialog',
      (tester) async {
    await tester.pumpWidget(testWidget(const ProgressionPanel(exercise: sampleExercise)));
    await tester.pumpAndSettle();

    final infoButton = find.byTooltip('Progression rules');
    expect(infoButton, findsOneWidget);

    await tester.tap(infoButton);
    await tester.pumpAndSettle();

    expect(find.text('Progression Rules'), findsOneWidget);
    expect(find.textContaining('RIR 2+'), findsWidgets);
    expect(find.textContaining('Progression earned'), findsOneWidget);
    expect(find.textContaining('Maintain / Repeat'), findsWidgets);
    expect(find.textContaining('Hold / Regression'), findsWidgets);
  });

  testWidgets('SettingsScreen provides a tile to open Progression Rules', (tester) async {
    await tester.pumpWidget(settingsApp());
    await tester.pumpAndSettle();

    final tile = find.text('Progression rules');
    expect(tile, findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.text('Progression Rules'), findsOneWidget);
  });
}
