import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/ui/screens/logger_screen.dart';

void main() {
  // Single-DB achievable totals (§2.6): fine below 25, 5-lb steps above.
  const singleDb = <double>[6, 9, 10, 12, 15, 18, 20, 21, 24, 25, 30, 35, 40, 45, 50];

  PlannedExercise ex(String key, MovementPattern p, double load, int? group) => PlannedExercise(
        trackKey: key,
        pattern: p,
        name: key,
        sets: 3,
        repRange: (6, 10),
        loadTotal: load,
        loadSteps: singleDb,
        rirTarget: Rir.rir2,
        supersetGroup: group,
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
}
