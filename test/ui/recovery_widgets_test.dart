import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/recovery_program.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/widgets/recovery_widgets.dart';

class _Controller extends AppController {
  _Controller() : super(Repository(AppDatabase())) {
    settings = settings.copyWith(lowerBackRecovery: const LowerBackRecoveryState(active: true));
  }
  RecoveryObservation? recorded;
  @override
  Future<void> recordRecoveryObservation(RecoveryObservation observation) async {
    recorded = observation;
  }
}

void main() {
  testWidgets('symptom form records resolved tingling and sitting tolerance', (tester) async {
    final controller = _Controller();
    await tester.pumpWidget(ChangeNotifierProvider<AppController>.value(
      value: controller, child: const MaterialApp(home: Scaffold(
        body: SingleChildScrollView(child: RecoveryControls()),
      )),
    ));
    await tester.tap(find.byKey(const Key('recovery-symptom-check')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save symptoms'));
    await tester.pump();
    expect(controller.recorded, isNull);
    await tester.enterText(find.byType(TextField), '25');
    final tingling = find.text('Leg tingling (including resolved)');
    await tester.ensureVisible(tingling);
    await tester.tap(tingling);
    await tester.pump();
    await tester.tap(find.text('Save symptoms'));
    await tester.pumpAndSettle();
    expect(controller.recorded!.sittingMinutes, 25);
    expect(controller.recorded!.symptoms, {PainTag.tingling});
  });

  testWidgets('progression screen has no recursive manage button', (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppController>.value(
      value: _Controller(), child: const MaterialApp(home: RecoveryProgramScreen()),
    ));
    expect(find.byKey(const Key('recovery-manage')), findsNothing);
    expect(find.text('Record clinical assessment'), findsOneWidget);
  });
}
