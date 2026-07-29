import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/ui/widgets/progression_panel.dart';

void main() {
  testWidgets('progression panel header does not overflow in a narrow column',
      (tester) async {
    // The Today card renders this inside a ListTile subtitle squeezed by a
    // trailing "RIR" label — a regression previously overflowed by 16 px
    // because the "Prescription changed since last time" header text was not
    // allowed to wrap.
    const exercise = PlannedExercise(
      trackKey: 'squat',
      pattern: MovementPattern.squat,
      name: 'DB squat',
      sets: 3,
      targetRange: (6, 10),
      loadTotal: 70,
      rirTarget: Rir.rir2,
      progressionFraction: 0.4,
      progressionLabel: '70 lb DB squat · Difficulty 2 of 6',
      nextProgressionLabel: 'Next: complete every set at the top of the range with RIR 2+',
      prescriptionChange: 'Set manually to "DB squat"',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: ProgressionPanel(exercise: exercise),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Prescription changed since last time'), findsOneWidget);
  });
}
