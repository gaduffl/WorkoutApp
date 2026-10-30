import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/user_settings.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/settings_screen.dart';

void main() {
  const controlKeys = [
    'settings-age',
    'settings-hr-max',
    'settings-anthropic-api-key',
    'settings-save',
  ];

  Future<Finder> scrollToControl(
    WidgetTester tester,
    String key,
  ) async {
    final target = find.byKey(Key(key));
    final scrollable = find.descendant(
      of: find.byType(SettingsScreen),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    expect(scrollable, findsOneWidget);

    final targetIndex = controlKeys.indexOf(key);
    final materializedControlIndices = <int>[
      for (var index = 0; index < controlKeys.length; index++)
        if (find.byKey(Key(controlKeys[index])).evaluate().isNotEmpty) index,
    ];
    final scrollDelta = materializedControlIndices.isNotEmpty &&
            targetIndex >= 0 && targetIndex < materializedControlIndices.first
        ? -400.0
        : 400.0;

    await tester.scrollUntilVisible(
      target,
      scrollDelta,
      scrollable: scrollable,
    );
    await tester.pump();
    return target;
  }

  Future<_RecordingSettingsController> pumpSettings(
    WidgetTester tester, {
    UserSettings settings = const UserSettings(),
  }) async {
    final controller = _RecordingSettingsController()..settings = settings;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    return controller;
  }

  Future<void> tapSave(WidgetTester tester) async {
    final save = await scrollToControl(tester, 'settings-save');
    await tester.tap(save);
    await tester.pump();
  }

  testWidgets('recovery options start collapsed without phase or dose forms', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      settings: const UserSettings(
        lowerBackRecovery: LowerBackRecoveryState(active: true),
      ),
    );
    await scrollToControl(tester, 'recovery-options');
    expect(find.byKey(const Key('settings-recovery-extensions')), findsNothing);
    expect(find.textContaining('Phase 1'), findsNothing);
    await tester.tap(find.byKey(const Key('recovery-options')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('settings-recovery-extensions')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings-stationary-bike-paused')),
      findsOneWidget,
    );
  });

  testWidgets('Back section shows the rebuild stage and saves Big 3 at once',
      (tester) async {
    final controller = await pumpSettings(
      tester,
      settings: const UserSettings(
        lowerBackRecovery: LowerBackRecoveryState(
          active: true,
          rebuildStage: BackRebuildStage.romanianDeadlift,
        ),
      ),
    );
    final bigThree = find.byKey(const Key('settings-big-three'));
    await tester.scrollUntilVisible(bigThree, 400);
    expect(
      find.textContaining('Stage 3 of 3 · Romanian deadlift'),
      findsOneWidget,
    );
    expect(tester.widget<SwitchListTile>(bigThree).value, isTrue);

    await tester.tap(bigThree);
    await tester.pump();
    expect(controller.saveCalls, 1);
    expect(controller.settings.bigThreeEnabled, isFalse);
    expect(tester.widget<SwitchListTile>(bigThree).value, isFalse);
  });

  testWidgets('HOV toggles immediately while retaining Big 3 and couch preferences', (tester) async {
    final controller = await pumpSettings(tester);
    final toggle = find.byKey(const Key('settings-hov-foot-warmup'));
    await tester.scrollUntilVisible(toggle, 400);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pump();
    expect(controller.settings.hovFootWarmupEnabled, isTrue);
    expect(controller.settings.bigThreeEnabled, isTrue);
    expect(controller.settings.couchStretchEnabled, isTrue);
    expect(controller.saveCalls, 1);
  });

  testWidgets('couch stretches toggle and set their hold at once',
      (tester) async {
    final controller = await pumpSettings(tester);
    final couch = find.byKey(const Key('settings-couch-stretch'));
    final hold = find.byKey(const Key('settings-couch-stretch-hold'));
    await tester.scrollUntilVisible(couch, 400);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(couch).value, isTrue);
    expect(tester.widget<DropdownButton<int>>(hold).value, 60);

    await tester.tap(hold);
    await tester.pumpAndSettle();
    await tester.tap(find.text('90 s').last);
    await tester.pumpAndSettle();
    expect(controller.saveCalls, 1);
    expect(controller.settings.couchStretchSeconds, 90);
    expect(tester.widget<DropdownButton<int>>(hold).value, 90);

    await tester.tap(couch);
    await tester.pump();
    expect(controller.saveCalls, 2);
    expect(controller.settings.couchStretchEnabled, isFalse);
    expect(controller.settings.couchStretchSeconds, 90);
    expect(hold, findsNothing);
  });

  testWidgets('a restored off-list couch stretch hold stays selectable',
      (tester) async {
    await pumpSettings(
      tester,
      settings: const UserSettings(couchStretchSeconds: 75),
    );
    final hold = find.byKey(const Key('settings-couch-stretch-hold'));
    await tester.scrollUntilVisible(hold, 400);
    await tester.pump();
    expect(tester.widget<DropdownButton<int>>(hold).value, 75);
    expect(
      tester
          .widget<DropdownButton<int>>(hold)
          .items!
          .map((item) => item.value),
      [30, 45, 60, 75, 90, 120, 180],
    );
  });

  testWidgets('blank HR override and API key explicitly clear saved values',
      (tester) async {
    final controller = await pumpSettings(
      tester,
      settings: const UserSettings(
        age: 40,
        hrMaxOverride: 190,
        anthropicApiKey: 'secret',
      ),
    );

    await tester.enterText(
      await scrollToControl(tester, 'settings-age'),
      ' 50 ',
    );
    await tester.enterText(
      await scrollToControl(tester, 'settings-hr-max'),
      '   ',
    );
    await tester.enterText(
      await scrollToControl(tester, 'settings-anthropic-api-key'),
      '   ',
    );
    await tapSave(tester);

    expect(controller.saveCalls, 1);
    expect(controller.settings.age, 50);
    expect(controller.settings.hrMaxOverride, isNull);
    expect(controller.settings.hrMax, 208 - 0.7 * 50);
    expect(controller.settings.anthropicApiKey, isNull);
    expect(find.text('Settings saved'), findsOneWidget);
  });

  testWidgets('nonblank settings text is trimmed before save', (tester) async {
    final controller = await pumpSettings(tester);

    await tester.enterText(
      await scrollToControl(tester, 'settings-age'),
      ' 41 ',
    );
    await tester.enterText(
      await scrollToControl(tester, 'settings-hr-max'),
      ' 188.5 ',
    );
    await tester.enterText(
      await scrollToControl(tester, 'settings-anthropic-api-key'),
      '  secret  ',
    );
    await tapSave(tester);

    expect(controller.saveCalls, 1);
    expect(controller.settings.age, 41);
    expect(controller.settings.hrMaxOverride, 188.5);
    expect(controller.settings.anthropicApiKey, 'secret');
  });

  testWidgets('existing decimal HRmax is not rounded in the editor',
      (tester) async {
    await pumpSettings(
      tester,
      settings: const UserSettings(hrMaxOverride: 188.5),
    );

    final field = tester.widget<TextField>(
      await scrollToControl(tester, 'settings-hr-max'),
    );
    expect(field.controller!.text, '188.5');
  });

  testWidgets('travel switch applies at once, without Save', (tester) async {
    final controller = await pumpSettings(tester);
    final toggle = find.byKey(const Key('settings-travel-mode'));
    await tester.scrollUntilVisible(toggle, 400);
    await tester.tap(toggle);
    await tester.pump();

    // Leaving Settings without Save used to keep today's dumbbell plan.
    expect(controller.travelModeCalls, [true]);
    expect(controller.settings.travelMode, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  testWidgets('Save keeps a travel mode changed outside this screen',
      (tester) async {
    final controller = await pumpSettings(tester);
    controller.settings = controller.settings.copyWith(travelMode: true);

    await tapSave(tester);

    expect(controller.saveCalls, 1);
    expect(controller.settings.travelMode, isTrue);
  });

  testWidgets('classic heatmap toggle is saved', (tester) async {
    final controller = await pumpSettings(tester);
    final toggle = find.byKey(const Key('settings-classic-heatmap'));
    await tester.scrollUntilVisible(toggle, 400);
    await tester.tap(toggle);
    await tapSave(tester);

    expect(controller.settings.classicHeatmap, isTrue);
  });

  for (final invalidAge in ['0', '121', '1000', '42.5', 'not an age']) {
    testWidgets('invalid age "$invalidAge" is rejected before save',
        (tester) async {
      final controller = await pumpSettings(tester);

      await tester.enterText(
        await scrollToControl(tester, 'settings-age'),
        invalidAge,
      );
      await tapSave(tester);

      expect(controller.saveCalls, 0);
      expect(
        find.text('Age must be a whole number from 1 to 120.'),
        findsOneWidget,
      );
    });
  }

  for (final invalidHrMax in ['0', '29.9', '261', 'NaN', 'not a number']) {
    testWidgets('invalid HRmax "$invalidHrMax" is rejected before save',
        (tester) async {
      final controller = await pumpSettings(tester);

      await tester.enterText(
        await scrollToControl(tester, 'settings-hr-max'),
        invalidHrMax,
      );
      await tapSave(tester);

      expect(controller.saveCalls, 0);
      expect(
        find.text(
          'HRmax override must be a finite number from 30 to 260, or left blank.',
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('age and HRmax validation boundaries are accepted',
      (tester) async {
    final controller = await pumpSettings(tester);

    await tester.enterText(
      await scrollToControl(tester, 'settings-age'),
      '120',
    );
    await tester.enterText(
      await scrollToControl(tester, 'settings-hr-max'),
      '260',
    );
    await tapSave(tester);
    expect(controller.saveCalls, 1);
    expect(controller.settings.age, 120);
    expect(controller.settings.hrMaxOverride, 260);

    await tester.enterText(
      await scrollToControl(tester, 'settings-age'),
      '1',
    );
    await tester.enterText(
      await scrollToControl(tester, 'settings-hr-max'),
      '30',
    );
    await tapSave(tester);
    expect(controller.saveCalls, 2);
    expect(controller.settings.age, 1);
    expect(controller.settings.hrMaxOverride, 30);
  });
}

class _RecordingSettingsController extends AppController {
  _RecordingSettingsController() : super(Repository(AppDatabase()));

  int saveCalls = 0;
  final travelModeCalls = <bool>[];

  @override
  Future<void> saveSettings(UserSettings newSettings) async {
    saveCalls += 1;
    settings = newSettings;
    notifyListeners();
  }

  @override
  Future<DecisionTrace?> setTravelMode(bool enabled) async {
    travelModeCalls.add(enabled);
    settings = settings.copyWith(travelMode: enabled);
    notifyListeners();
    return todayTrace;
  }
}
