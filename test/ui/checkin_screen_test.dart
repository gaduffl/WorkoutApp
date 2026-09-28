import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/user_settings.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/checkin_screen.dart';

void main() {
  Future<_CheckInController> pumpCheckIn(
    WidgetTester tester, {
    DateTime? pendingSessionDate,
  }) async {
    final controller = _CheckInController()
      ..settings = UserSettings(
        lowerBackRecovery: LowerBackRecoveryState(
          active: true,
          pendingNextMorningSessionDate: pendingSessionDate,
          pendingSameDayResponse: pendingSessionDate == null
              ? null
              : LowerBackSymptomResponse.unchanged,
          pendingRebuildExposure: pendingSessionDate == null
              ? BackRebuildExposure.none
              : BackRebuildExposure.loaded,
        ),
      );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        // A fresh screen state for every pump.
        child: MaterialApp(key: UniqueKey(), home: const CheckInScreen()),
      ),
    );
    await tester.pump();
    return controller;
  }

  FilledButton submitButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.ancestor(
      of: find.text('Get my plan'),
      matching: find.byType(FilledButton),
    ),
  );

  testWidgets('a due back check must be answered before planning', (
    tester,
  ) async {
    final controller = await pumpCheckIn(
      tester,
      pendingSessionDate: DateTime(2026, 9, 1, 7),
    );
    expect(find.byKey(const Key('checkin-back-check')), findsOneWidget);
    expect(find.text('Back after your last session?'), findsOneWidget);

    await tester.tap(find.text('35 min'));
    await tester.pump();
    expect(submitButton(tester).onPressed, isNull);

    await tester.tap(find.byKey(const Key('checkin-back-worse')));
    await tester.pump();
    expect(find.textContaining('steps back one stage'), findsOneWidget);
    expect(submitButton(tester).onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('checkin-back-better')));
    await tester.pump();
    expect(find.textContaining('steps back one stage'), findsNothing);

    await tester.ensureVisible(find.text('Get my plan'));
    await tester.tap(find.text('Get my plan'));
    await tester.pump();
    expect(controller.submits, 1);
    expect(controller.timeMinutes, 35);
    expect(controller.backCheck, LowerBackSymptomResponse.better);
  });

  testWidgets('no back question appears without trained work to judge', (
    tester,
  ) async {
    for (final pending in [null, DateTime(2026, 9, 2, 7)]) {
      final controller = await pumpCheckIn(tester, pendingSessionDate: pending);
      expect(find.byKey(const Key('checkin-back-check')), findsNothing);
      await tester.tap(find.text('20 min'));
      await tester.pump();
      await tester.ensureVisible(find.text('Get my plan'));
      await tester.tap(find.text('Get my plan'));
      await tester.pump();
      expect(controller.submits, 1);
      expect(controller.backCheck, isNull);
    }
  });
}

class _CheckInController extends AppController {
  _CheckInController() : super(Repository(AppDatabase())) {
    loading = false;
  }

  /// Never completes, so the screen stays put after submitting.
  final Completer<DecisionTrace> _pending = Completer();
  int submits = 0;
  int? timeMinutes;
  LowerBackSymptomResponse? backCheck;

  @override
  DateTime today() => DateTime(2026, 9, 2);

  @override
  Future<DecisionTrace> submitCheckIn({
    required int timeMinutes,
    required int subjective,
    List<PainFlag> pain = const [],
    RecoverySnapshot? recovery,
    LowerBackSymptomResponse? backCheck,
  }) {
    submits += 1;
    this.timeMinutes = timeMinutes;
    this.backCheck = backCheck;
    return _pending.future;
  }
}
