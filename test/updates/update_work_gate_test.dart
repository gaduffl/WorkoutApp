import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/workout_draft.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/updates/update_work_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppController controller() {
    final app = AppController(Repository(AppDatabase()));
    addTearDown(app.dispose);
    return app;
  }

  test('startup and an unfinished workout block process replacement', () {
    final app = controller();
    expect(appHasUpdateWorkInProgress(app, null), isTrue);
    app.loading = false;
    expect(appHasUpdateWorkInProgress(app, null), isFalse);

    final now = DateTime.now();
    app.workoutDraft = WorkoutDraft(
      plan: const SessionPlan(
        sessionId: SessionTypeId.s1,
        sessionName: 'Lower strength',
        tier: SessionTier.full,
        exercises: [],
        estimatedDurationMin: 35,
      ),
      startedAt: now,
      stepStartedAt: now,
      superset: false,
      current: 0,
      logged: [],
      loggedKeys: [],
      weights: {},
      value: 8,
      rir: Rir.rir2,
      painFlag: false,
      plannedRestIntoStep: 0,
      holdSecondsLeft: 0,
      holdTargetSeconds: 0,
      holdTimerUsed: false,
      warmupSecondsLeft: 0,
    );
    expect(appHasUpdateWorkInProgress(app, null), isTrue);
    app.workoutDraft = null;
    expect(appHasUpdateWorkInProgress(app, null), isFalse);
  });

  test('a failed background backup releases its update blocker', () async {
    final app = controller()..loading = false;
    final busy = <bool>[];
    app.addListener(() => busy.add(app.updateWorkInFlight));
    await app.backupToOneDrive(silent: true);
    expect(busy.first, isTrue);
    expect(busy.last, isFalse);
    expect(app.updateWorkInFlight, isFalse);
  });

  testWidgets('forms and dialogs block updates and their closure notifies', (
    tester,
  ) async {
    final app = controller()..loading = false;
    final key = GlobalKey<NavigatorState>();
    final routes = UpdateRouteChanges();
    addTearDown(routes.dispose);
    var changes = 0;
    routes.addListener(() => changes++);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        navigatorObservers: [routes],
        home: const Scaffold(body: Text('Home')),
      ),
    );
    expect(appHasUpdateWorkInProgress(app, key.currentState), isFalse);
    key.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(appHasUpdateWorkInProgress(app, key.currentState), isTrue);
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(appHasUpdateWorkInProgress(app, key.currentState), isFalse);
    expect(changes, 3);

    final dialog = showDialog<void>(
      context: key.currentContext!,
      builder: (_) => const AlertDialog(content: Text('Unsaved input')),
    );
    await tester.pumpAndSettle();
    expect(appHasUpdateWorkInProgress(app, key.currentState), isTrue);
    key.currentState!.pop();
    await tester.pumpAndSettle();
    await dialog;
    expect(appHasUpdateWorkInProgress(app, key.currentState), isFalse);
    expect(changes, 5);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
