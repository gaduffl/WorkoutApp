import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:morningcoach/ui/update_section.dart';
import 'package:morningcoach/updates/apk_installer.dart';
import 'package:morningcoach/updates/app_version.dart';
import 'package:morningcoach/updates/update_controller.dart';
import 'package:morningcoach/updates/update_downloader.dart';
import 'package:morningcoach/updates/update_models.dart';
import 'package:morningcoach/updates/update_settings.dart';

import '../updates/fakes.dart';

void main() {
  late FakeInstaller installer;
  late MemoryTokens tokens;
  late FixedSource source;
  late Directory dir;
  final bytes = List<int>.generate(32, (i) => i);

  UpdateController build({DateTime Function()? clock}) {
    final adapter = FakeAdapter({
      'https://api.github.com/a': Reply(200, bytes: bytes),
    });
    final controller = UpdateController(
      installer: installer,
      settingsStore: UpdateSettingsStore(),
      tokenStore: tokens,
      downloader: UpdateDownloader(
        dio: dioFor(adapter),
        directory: () async => dir,
      ),
      sourceFactory: (_, _) => source,
      clock: clock,
    );
    // Auto-update starts a real countdown timer; it must not outlive the test.
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pump(
    WidgetTester tester,
    UpdateController? controller, {
    Locale locale = const Locale('en'),
    Widget body = const SingleChildScrollView(child: AppUpdateSection()),
  }) async {
    Widget scope(Widget child) => controller == null
        ? child
        : ChangeNotifierProvider.value(value: controller, child: child);
    await tester.pumpWidget(
      scope(
        MaterialApp(
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('de')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: body),
        ),
      ),
    );
    await controller?.load();
    await tester.pumpAndSettle();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installer = FakeInstaller();
    tokens = MemoryTokens();
    dir = tempDir();
    source = FixedSource(
      AvailableUpdate(
        version: AppVersion.tryParse('0.43.0+72')!,
        downloadUri: Uri.parse('https://api.github.com/a'),
        sizeBytes: bytes.length,
        sha256: sha256Of(bytes),
        notes: 'Faster charts',
      ),
    );
  });

  testWidgets('the check is a labelled button on the card, not a bare icon', (
    tester,
  ) async {
    await pump(tester, build());

    expect(find.text('App updates'), findsOneWidget);
    expect(find.text('Installed: 0.42.0+71'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Check for updates'),
      findsOneWidget,
    );
    expect(find.text('GitHub · gaduffl/WorkoutApp'), findsOneWidget);
  });

  testWidgets('nothing is drawn without a controller or off Android', (
    tester,
  ) async {
    await pump(tester, null);
    expect(find.text('App updates'), findsNothing);

    installer.supported = false;
    await pump(tester, build());
    expect(find.text('App updates'), findsNothing);
  });

  testWidgets(
    'checking offers the update with its notes, then installs it on tap',
    (tester) async {
      final controller = build();
      await pump(tester, controller);

      await tester.tap(find.byKey(const ValueKey('update-check')));
      await tester.pumpAndSettle();
      expect(
        find.text('Version 0.43.0+72 is available · 0.0 MB.'),
        findsOneWidget,
      );
      expect(find.text('Faster charts'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('update-install')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      // Bounded: the bar while Android's sheet is open animates until the
      // person answers, so the tree never settles by design.
      await tester.pump(const Duration(milliseconds: 50));

      expect(installer.installed, hasLength(1));
      expect(find.textContaining('Confirm the installation'), findsOneWidget);
    },
  );

  testWidgets(
    'without permission the card explains it and opens the system page',
    (tester) async {
      installer.allowed = false;
      final controller = build();
      await pump(tester, controller);
      await tester.tap(find.byKey(const ValueKey('update-check')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('update-install')));
      await tester.pumpAndSettle();

      expect(find.textContaining('needs your permission'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-permission')));
      expect(installer.permissionPageOpened, 1);
    },
  );

  testWidgets('a failed check says why, in the person\'s terms', (
    tester,
  ) async {
    source.error = const UpdateException(UpdateFailureKind.notFound);
    await pump(tester, build());
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'No release was found. A private repository needs an access token.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'a failure that blames the token only does so when one is saved',
    (tester) async {
      tokens.values[UpdateSourceKind.github] = 'ghp_x';
      source.error = const UpdateException(UpdateFailureKind.unauthorized);
      await pump(tester, build());
      await tester.tap(find.byKey(const ValueKey('update-check')));
      await tester.pumpAndSettle();
      expect(
        find.text('The server rejected the access token.'),
        findsOneWidget,
      );
      expect(
        find.text('GitHub · gaduffl/WorkoutApp · token saved'),
        findsOneWidget,
      );
    },
  );

  testWidgets('German users get German, with no English left on the card', (
    tester,
  ) async {
    source.error = const UpdateException(UpdateFailureKind.checksumMismatch);
    await pump(tester, build(), locale: const Locale('de'));

    expect(find.text('App-Updates'), findsOneWidget);
    expect(find.text('Nach Updates suchen'), findsOneWidget);
    expect(find.text('Automatische Updates'), findsOneWidget);
    expect(find.textContaining('Automatic'), findsNothing);
    expect(find.text('Update-Quelle'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('stimmte nicht mit der Prüfsumme überein'),
      findsOneWidget,
    );
  });

  testWidgets(
    'the source dialog rejects http, then saves a server and its token',
    (tester) async {
      final controller = build();
      await pump(tester, controller);
      await tester.tap(find.text('Update source'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Own server'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('update-server')),
        'http://updates.example.org/latest.json',
      );
      await tester.tap(find.byKey(const ValueKey('update-source-save')));
      await tester.pumpAndSettle();
      expect(find.text('Enter an https:// address.'), findsOneWidget);
      expect(
        controller.settings.source,
        UpdateSourceKind.github,
        reason: 'nothing saved',
      );

      await tester.enterText(
        find.byKey(const ValueKey('update-server')),
        'https://updates.example.org/latest.json',
      );
      await tester.enterText(
        find.byKey(const ValueKey('update-token')),
        ' tok ',
      );
      await tester.tap(find.byKey(const ValueKey('update-source-save')));
      await tester.pumpAndSettle();

      expect(controller.settings.source, UpdateSourceKind.server);
      expect(
        controller.settings.serverUrl,
        'https://updates.example.org/latest.json',
      );
      expect(tokens.values[UpdateSourceKind.server], 'tok');
      expect(tokens.values.containsKey(UpdateSourceKind.github), isFalse);
      expect(
        find.text('Own server · updates.example.org · token saved'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'an invalid repository is rejected and a saved token can be removed',
    (tester) async {
      tokens.values[UpdateSourceKind.github] = 'ghp_x';
      final controller = build();
      await pump(tester, controller);
      await tester.tap(find.text('Update source'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('update-repository')),
        'not a repo',
      );
      await tester.tap(find.byKey(const ValueKey('update-source-save')));
      await tester.pumpAndSettle();
      expect(find.text('Use the form owner/name.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('update-repository')),
        'https://github.com/someone/else',
      );
      await tester.tap(find.text('Remove saved token'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('update-source-save')));
      await tester.pumpAndSettle();

      expect(controller.settings.githubRepository, 'someone/else');
      expect(tokens.values, isEmpty);
    },
  );

  testWidgets(
    'auto update is a labelled checkbox on the card that says what it will do',
    (tester) async {
      installer.silent = SilentInstall.supported;
      final controller = build();
      await pump(tester, controller);

      final box = find.byKey(const ValueKey('update-auto-install'));
      expect(
        find.descendant(of: box, matching: find.text('Auto update')),
        findsOneWidget,
      );
      expect(tester.widget<CheckboxListTile>(box).value, isFalse);
      expect(
        find.textContaining(
          'also while you use MorningCoach: a 10-second notice comes first',
        ),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.tap(box);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      expect(controller.settings.autoInstall, isTrue);
      expect(tester.widget<CheckboxListTile>(box).value, isTrue);
      expect(
        find.textContaining('It installs as soon as nothing is open'),
        findsOneWidget,
      );
      expect(installer.installed, isEmpty);
    },
  );

  testWidgets(
    'where Android insists on its sheet, the box says it only looks',
    (tester) async {
      installer.silent = SilentInstall.androidTooOld;
      await pump(tester, build());

      expect(
        find.text(
          'Android 11 and older confirm every install. So auto update only '
          'looks for new versions here, and you install them.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a tap that installs without a sheet warns that the app will close',
    (tester) async {
      installer.silent = SilentInstall.supported;
      final controller = build();
      await pump(tester, controller);
      await tester.tap(find.byKey(const ValueKey('update-check')));
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('update-install')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('MorningCoach closes when'), findsOneWidget);
      expect(find.textContaining('Confirm the installation'), findsNothing);
    },
  );

  testWidgets(
    'while auto update is on, the source dialog cannot switch the check off',
    (tester) async {
      SharedPreferences.setMockInitialValues({'update_auto_install': true});
      await pump(tester, build());
      await tester.tap(find.text('Update source'));
      await tester.pumpAndSettle();

      final check = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('update-auto-check')),
      );
      expect(check.value, isTrue);
      expect(check.onChanged, isNull);
      expect(
        find.textContaining('Auto update is on, and it looks'),
        findsOneWidget,
      );
    },
  );

  group('the countdown banner', () {
    final fixed = DateTime.utc(2026, 10, 2, 12);

    Future<UpdateController> counting(
      WidgetTester tester, {
      Locale locale = const Locale('en'),
    }) async {
      installer.silent = SilentInstall.supported;
      final controller = build(clock: () => fixed);
      await pump(
        tester,
        controller,
        locale: locale,
        body: const UpdateCountdownBanner(),
      );
      await tester.runAsync(() => controller.setAutoInstall(true));
      await tester.pump();
      return controller;
    }

    testWidgets('draws nothing while no install is counting down', (
      tester,
    ) async {
      await pump(tester, build(), body: const UpdateCountdownBanner());
      expect(find.byKey(const ValueKey('update-countdown')), findsNothing);
    });

    testWidgets('announces the version, the seconds left and the app closing', (
      tester,
    ) async {
      await counting(tester);

      expect(
        find.text(
          'Updating to version 0.43.0 in 10 s. MorningCoach closes while '
          'Android installs it.',
        ),
        findsOneWidget,
      );
      expect(installer.installed, isEmpty);
    });

    testWidgets('Later puts it off and takes the banner away', (tester) async {
      final controller = await counting(tester);
      await tester.tap(find.byKey(const ValueKey('update-later')));
      await tester.pump();

      expect(find.byKey(const ValueKey('update-countdown')), findsNothing);
      expect(controller.installPostponed, isTrue);
      expect(installer.installed, isEmpty);
    });

    testWidgets('Update now installs without waiting out the countdown', (
      tester,
    ) async {
      await counting(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('update-now')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(installer.installed, hasLength(1));
      expect(installer.unattended.single, isTrue);
      expect(find.byKey(const ValueKey('update-countdown')), findsNothing);
    });

    testWidgets('speaks German to a German reader', (tester) async {
      await counting(tester, locale: const Locale('de'));

      expect(
        find.text(
          'Update auf Version 0.43.0 in 10 s. MorningCoach schließt sich, '
          'während Android es installiert.',
        ),
        findsOneWidget,
      );
      expect(find.text('Später'), findsOneWidget);
      expect(find.text('Jetzt aktualisieren'), findsOneWidget);
    });
  });

  test('the notice that brings the person back is in their language', () {
    final version = AppVersion.tryParse('0.45.0+76')!;
    final english = updateNoticeFor(UpdateStrings.english, version);
    final german = updateNoticeFor(UpdateStrings.german, version);

    expect(english.title, 'MorningCoach was updated');
    expect(english.body, contains('0.45.0'));
    expect(english.versionCode, 76);
    expect(german.title, 'MorningCoach wurde aktualisiert');
    expect(german.channelName, 'App-Updates');
  });

  testWidgets(
    'outside the widget tree, "system" resolves to what the app shows',
    (tester) async {
      tester.platformDispatcher.localesTestValue = const [Locale('de', 'AT')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      expect(UpdateStrings.resolve(null), same(UpdateStrings.german));

      tester.platformDispatcher.localesTestValue = const [Locale('fr')];
      expect(UpdateStrings.resolve(null), same(UpdateStrings.english));
      expect(
        UpdateStrings.resolve(const Locale('de')),
        same(UpdateStrings.german),
      );
    },
  );
}

