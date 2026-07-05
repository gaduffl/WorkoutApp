import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/checkin_screen.dart';

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
}
