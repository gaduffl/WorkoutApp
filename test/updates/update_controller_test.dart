import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:morningcoach/updates/apk_installer.dart';
import 'package:morningcoach/updates/app_version.dart';
import 'package:morningcoach/updates/update_controller.dart';
import 'package:morningcoach/updates/update_downloader.dart';
import 'package:morningcoach/updates/update_models.dart';
import 'package:morningcoach/updates/update_settings.dart';

import 'fakes.dart';

const _apkUrl = 'https://api.github.com/repos/o/r/releases/assets/9';

void main() {
  late Directory dir;
  late FakeInstaller installer;
  late MemoryTokens tokens;
  late FakeAdapter adapter;
  late FixedSource source;
  late DateTime now;
  final bytes = List<int>.generate(64, (i) => i);

  AvailableUpdate update({String version = '0.43.0+72'}) => AvailableUpdate(
    version: AppVersion.tryParse(version)!,
    downloadUri: Uri.parse(_apkUrl),
    sizeBytes: bytes.length,
    sha256: sha256Of(bytes),
    notes: 'Fixes',
  );

  UpdateController build({
    bool Function()? workInFlight,
    Listenable? workChanges,
    bool Function()? installInFront,
    Duration installNotice = const Duration(seconds: 10),
    HttpClientAdapter? http,
  }) {
    final controller = UpdateController(
      installer: installer,
      settingsStore: UpdateSettingsStore(),
      tokenStore: tokens,
      downloader: UpdateDownloader(
        dio: Dio()..httpClientAdapter = http ?? adapter,
        directory: () async => dir,
      ),
      sourceFactory: (_, _) => source,
      workInFlight: workInFlight,
      workChanges: workChanges,
      installInFront: installInFront,
      installNotice: installNotice,
      noticeFor: (version) => UpdateNotice(
        channelName: 'App updates',
        title: 'Updated',
        body: 'Version ${version.name}',
        versionCode: version.build ?? 0,
      ),
      clock: () => now,
    );
    // A countdown left running would fire into the next test.
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = tempDir();
    installer = FakeInstaller();
    tokens = MemoryTokens();
    adapter = FakeAdapter({_apkUrl: Reply(200, bytes: bytes)});
    source = FixedSource(update());
    now = DateTime.utc(2026, 10, 1, 12);
  });

  test('a newer release is offered and the check time is recorded', () async {
    final controller = build();
    await controller.checkForUpdates();

    expect(controller.phase, UpdatePhase.available);
    expect(controller.available!.version.toString(), '0.43.0+72');
    expect(controller.installedVersion.toString(), '0.42.0+71');
    expect(controller.updateAvailable, isTrue);
    expect(await UpdateSettingsStore().lastCheckedAt(), now);
  });

  test(
    'the same or an older build is "up to date" and clears stale downloads',
    () async {
      File(
        '${dir.path}/morningcoach-0.42.0-71.apk',
      ).createSync(recursive: true);
      source.update = update(version: '0.42.0+71');
      final controller = build();
      await controller.checkForUpdates();
      // The clean-up is deliberately fire-and-forget.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(controller.phase, UpdatePhase.upToDate);
      expect(controller.updateAvailable, isFalse);
      expect(dir.listSync(), isEmpty);
    },
  );

  test(
    'the stored token reaches the source for the configured kind only',
    () async {
      tokens.values[UpdateSourceKind.server] = 'server-token';
      tokens.values[UpdateSourceKind.github] = 'github-token';
      String? seen;
      final controller = UpdateController(
        installer: installer,
        settingsStore: UpdateSettingsStore(),
        tokenStore: tokens,
        downloader: UpdateDownloader(
          dio: dioFor(adapter),
          directory: () async => dir,
        ),
        sourceFactory: (_, token) {
          seen = token;
          return source;
        },
      );
      await controller.checkForUpdates();
      expect(seen, 'github-token');
    },
  );

  test(
    'a failed manual check is shown; a failed startup check is silent',
    () async {
      source.error = const UpdateException(UpdateFailureKind.network);
      final manual = build();
      await manual.checkForUpdates();
      expect(manual.phase, UpdatePhase.failed);
      expect(manual.failure!.kind, UpdateFailureKind.network);

      final startup = build();
      await startup.checkInBackground();
      expect(startup.phase, UpdatePhase.idle);
      expect(startup.failure, isNull);
    },
  );

  test(
    'a silent failure does not erase an update that was already known',
    () async {
      final controller = build();
      await controller.checkForUpdates();
      source.error = const UpdateException(UpdateFailureKind.network);
      await controller.checkForUpdates(background: true);

      expect(controller.phase, UpdatePhase.available);
      expect(controller.available, isNotNull);
    },
  );

  test(
    'the startup check honours the switch, the configuration and the interval',
    () async {
      final off = build();
      await off.saveSettings(const UpdateSettings(autoCheck: false));
      await off.checkInBackground();
      expect(source.fetches, 0);

      final on = build();
      await on.saveSettings(const UpdateSettings());
      await on.checkInBackground();
      expect(source.fetches, 1);

      now = now.add(const Duration(minutes: 10));
      await build().checkInBackground();
      expect(
        source.fetches,
        1,
        reason: 'a relaunch within the hour does not re-ask',
      );

      now = now.add(UpdateController.autoCheckInterval);
      await build().checkInBackground();
      expect(source.fetches, 2);
    },
  );

  test('an unconfigured manual check explains what is missing', () async {
    final controller = build();
    await controller.saveSettings(
      const UpdateSettings(source: UpdateSourceKind.server),
    );
    await controller.checkForUpdates();
    expect(controller.failure!.kind, UpdateFailureKind.notConfigured);
    expect(source.fetches, 0);
  });

  test('nothing is fetched or installed off Android', () async {
    installer.supported = false;
    final controller = build();
    await controller.checkForUpdates();
    expect(controller.supported, isFalse);
    expect(controller.failure!.kind, UpdateFailureKind.unsupportedPlatform);
    expect(source.fetches, 0);
  });

  test('download then install hands the verified file to Android', () async {
    final controller = build();
    await controller.checkForUpdates();
    await controller.downloadAndInstall();

    expect(installer.installed, hasLength(1));
    expect(installer.installed.single.readAsBytesSync(), bytes);
    expect(controller.phase, UpdatePhase.awaitingConfirmation);
  });

  test(
    'without the install permission nothing is downloaded and the person is sent to settings',
    () async {
      installer.allowed = false;
      final controller = build();
      await controller.checkForUpdates();
      await controller.downloadAndInstall();

      expect(controller.phase, UpdatePhase.needsPermission);
      expect(
        adapter.requests,
        isEmpty,
        reason: 'no data spent before the switch is on',
      );
      await controller.openInstallPermissionSettings();
      expect(installer.permissionPageOpened, 1);
    },
  );

  test(
    'returning from settings with the switch on carries on by itself',
    () async {
      installer.allowed = false;
      final controller = build();
      await controller.checkForUpdates();
      await controller.downloadAndInstall();

      await controller.onResumed();
      expect(
        controller.phase,
        UpdatePhase.needsPermission,
        reason: 'still off',
      );

      installer.allowed = true;
      await controller.onResumed();
      expect(installer.installed, hasLength(1));
    },
  );

  test('a corrupt download fails and installs nothing', () async {
    adapter = FakeAdapter({_apkUrl: Reply(200, bytes: List.filled(64, 7))});
    final controller = build();
    await controller.checkForUpdates();
    await controller.downloadAndInstall();

    expect(controller.phase, UpdatePhase.failed);
    expect(controller.failure!.kind, UpdateFailureKind.checksumMismatch);
    expect(installer.installed, isEmpty);
    expect(controller.available, isNotNull, reason: 'the person can try again');
  });

  test(
    'dismissing the system sheet keeps the file so install can be offered again',
    () async {
      final controller = build();
      await controller.checkForUpdates();
      await controller.downloadAndInstall();
      installer.emit(const InstallEvent(InstallEventKind.cancelled));
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, UpdatePhase.readyToInstall);

      final requestsBefore = adapter.requests.length;
      await controller.downloadAndInstall();
      expect(installer.installed, hasLength(2));
      expect(
        adapter.requests.length,
        requestsBefore,
        reason: 'no second download',
      );
    },
  );

  test(
    'an installer failure is reported with Android\'s own message',
    () async {
      final controller = build();
      await controller.checkForUpdates();
      await controller.downloadAndInstall();
      installer.emit(
        const InstallEvent(
          InstallEventKind.failed,
          'INSTALL_FAILED_UPDATE_INCOMPATIBLE',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.phase, UpdatePhase.failed);
      expect(controller.failure!.kind, UpdateFailureKind.installFailed);
      expect(controller.failure!.detail, contains('INCOMPATIBLE'));
    },
  );

  test('a commit that throws is a failure, not a hang', () async {
    installer.installError = const UpdateException(
      UpdateFailureKind.installFailed,
      'no space',
    );
    final controller = build();
    await controller.checkForUpdates();
    await controller.downloadAndInstall();
    expect(controller.phase, UpdatePhase.failed);
    expect(controller.failure!.detail, 'no space');
  });

  test(
    'a newer release invalidates a file downloaded for an older one',
    () async {
      final controller = build();
      await controller.checkForUpdates();
      await controller.downloadAndInstall();
      installer.emit(const InstallEvent(InstallEventKind.cancelled));
      await Future<void>.delayed(Duration.zero);

      final newer = update(version: '0.44.0+73');
      source.update = newer;
      adapter.routes[_apkUrl] = Reply(200, bytes: bytes);
      await controller.checkForUpdates();
      final before = adapter.requests.length;
      await controller.downloadAndInstall();
      expect(
        adapter.requests.length,
        greaterThan(before),
        reason: 'fetched again',
      );
    },
  );

  test(
    'cancelling a download returns to "available", not to an error',
    () async {
      adapter = FakeAdapter({
        _apkUrl: Reply(
          200,
          chunks: [for (var i = 0; i < 40; i++) List.filled(2, i)],
          headers: {'content-length': '80'},
        ),
      });
      source.update = AvailableUpdate(
        version: AppVersion.tryParse('0.43.0+72')!,
        downloadUri: Uri.parse(_apkUrl),
      );
      final controller = build();
      await controller.checkForUpdates();
      controller.addListener(() {
        if (controller.phase == UpdatePhase.downloading &&
            controller.receivedBytes >= 10) {
          controller.cancelDownload();
        }
      });
      await controller.downloadAndInstall();

      expect(controller.phase, UpdatePhase.available);
      expect(controller.failure, isNull);
      expect(installer.installed, isEmpty);
      expect(dir.existsSync() ? dir.listSync() : [], isEmpty);
    },
  );

  test(
    'editing the source forgets what the old one said, and keeps a token it did not touch',
    () async {
      final controller = build();
      await controller.saveSettings(const UpdateSettings(), token: 'abc');
      await controller.checkForUpdates();
      expect(controller.available, isNotNull);

      await controller.saveSettings(
        const UpdateSettings(githubRepository: 'someone/else'),
      );
      expect(controller.available, isNull);
      expect(controller.phase, UpdatePhase.idle);
      expect(
        controller.hasToken,
        isTrue,
        reason: 'null token means leave it alone',
      );

      await controller.saveSettings(
        const UpdateSettings(githubRepository: 'someone/else'),
        token: '  ',
      );
      expect(controller.hasToken, isFalse, reason: 'an empty token removes it');
    },
  );

  test(
    'settings load from storage and report whether a token exists',
    () async {
      SharedPreferences.setMockInitialValues({
        'update_source': 'server',
        'update_server_url': 'https://updates.example.org/latest.json',
      });
      tokens.values[UpdateSourceKind.server] = 'x';
      final controller = build();
      await controller.load();
      expect(controller.settings.source, UpdateSourceKind.server);
      expect(controller.hasToken, isTrue);
      expect(controller.loaded, isTrue);
    },
  );

  test('progress is indeterminate when the size is unknown', () async {
    final controller = build();
    expect(controller.progress, isNull);
  });

  test(
    'returning to the app looks for an update again, at most once an hour',
    () async {
      final controller = build();
      await controller.checkInBackground();
      expect(source.fetches, 1);

      await controller.lifecycleChanged(AppLifecycleState.paused);
      await controller.lifecycleChanged(AppLifecycleState.resumed);
      expect(source.fetches, 1, reason: 'within the hour');

      now = now.add(UpdateController.autoCheckInterval);
      await controller.lifecycleChanged(AppLifecycleState.resumed);
      expect(source.fetches, 2);
    },
  );

  test(
    'a tap that Android can install without its sheet says installing, not "confirm"',
    () async {
      installer.silent = SilentInstall.supported;
      final controller = build();
      await controller.checkForUpdates();
      await controller.downloadAndInstall();

      expect(installer.unattended.single, isFalse);
      expect(controller.phase, UpdatePhase.installing);
    },
  );

  test(
    'with auto update off, leaving the app fetches and installs nothing',
    () async {
      installer.silent = SilentInstall.supported;
      final controller = build();
      await controller.checkInBackground();
      expect(controller.phase, UpdatePhase.available);

      await controller.lifecycleChanged(AppLifecycleState.paused);
      expect(adapter.requests, isEmpty);
      expect(installer.installed, isEmpty);
    },
  );

  group('auto update', () {
    setUp(() => installer.silent = SilentInstall.supported);

    test(
      'downloads what the check finds; leaving the app installs it at once, without a notice',
      () async {
        final controller = build();
        await controller.setAutoInstall(true);

        expect(controller.phase, UpdatePhase.readyToInstall);
        expect(controller.installsAutomatically, isTrue);
        expect(controller.installCountdown, isNotNull);
        expect(installer.installed, isEmpty, reason: 'not without warning');

        await controller.lifecycleChanged(AppLifecycleState.inactive);
        expect(
          installer.installed,
          isEmpty,
          reason: 'a dialog or the shade over the app is not leaving it',
        );

        await controller.lifecycleChanged(AppLifecycleState.paused);
        expect(installer.installed, hasLength(1));
        expect(installer.unattended.single, isTrue);
        expect(installer.installed.single.readAsBytesSync(), bytes);
        expect(controller.phase, UpdatePhase.installing);
        expect(controller.installCountdown, isNull);
        expect(
          installer.notices.single,
          isNull,
          reason: 'nothing closed in front of them to come back from',
        );
      },
    );

    test(
      'in front of the person it installs once the countdown runs out, and says how to get back',
      () async {
        final controller = build(
          installNotice: const Duration(milliseconds: 20),
        );
        await controller.setAutoInstall(true);
        expect(controller.installCountdown, const Duration(milliseconds: 20));
        expect(installer.installed, isEmpty);

        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(installer.installed, hasLength(1));
        expect(installer.unattended.single, isTrue);
        expect(controller.installCountdown, isNull);
        final notice = installer.notices.single!;
        expect(notice.versionCode, 72);
        expect(notice.body, contains('0.43.0'));
      },
    );

    test(
      'Later holds it off until the person leaves; leaving still installs',
      () async {
        final open = ValueNotifier(false);
        final controller = build(
          workInFlight: () => open.value,
          workChanges: open,
          installNotice: const Duration(milliseconds: 20),
        );
        await controller.setAutoInstall(true);
        controller.postponeInstall();

        expect(controller.installCountdown, isNull);
        expect(controller.installPostponed, isTrue);
        // A dialog opened and closed: the next look must still respect Later.
        open.value = true;
        open.value = false;
        await Future<void>.delayed(Duration.zero);
        expect(controller.installCountdown, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(installer.installed, isEmpty);

        await controller.lifecycleChanged(AppLifecycleState.paused);
        expect(installer.installed, hasLength(1));
      },
    );

    test(
      'Later lasts until the person comes back, then it asks again',
      () async {
        final work = ValueNotifier(false);
        final controller = build(workInFlight: () => work.value);
        await controller.setAutoInstall(true);
        controller.postponeInstall();

        work.value = true;
        await controller.lifecycleChanged(AppLifecycleState.paused);
        expect(installer.installed, isEmpty, reason: 'a lab plan is running');
        work.value = false;
        await controller.lifecycleChanged(AppLifecycleState.resumed);

        expect(controller.installPostponed, isFalse);
        expect(controller.installCountdown, isNotNull);
      },
    );

    test(
      'something opening during the countdown stops it; closing it starts over',
      () async {
        final open = ValueNotifier(false);
        final controller = build(
          workInFlight: () => open.value,
          workChanges: open,
          installNotice: const Duration(milliseconds: 20),
        );
        await controller.setAutoInstall(true);
        expect(controller.installCountdown, isNotNull);

        open.value = true;
        await Future<void>.delayed(Duration.zero);
        expect(controller.installCountdown, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(installer.installed, isEmpty, reason: 'a form is open');

        open.value = false;
        await Future<void>.delayed(Duration.zero);
        expect(controller.installCountdown, isNotNull);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(installer.installed, hasLength(1));
      },
    );

    test('Update now skips the rest of the countdown', () async {
      final controller = build();
      await controller.setAutoInstall(true);
      await controller.installNow();

      expect(installer.installed, hasLength(1));
      expect(installer.notices.single, isNotNull);
      expect(controller.installCountdown, isNull);
    });

    test(
      'where it may not interrupt — easy mode — it only installs on the way out',
      () async {
        final controller = build(
          installInFront: () => false,
          installNotice: const Duration(milliseconds: 20),
        );
        await controller.setAutoInstall(true);

        expect(controller.phase, UpdatePhase.readyToInstall);
        expect(controller.installCountdown, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(installer.installed, isEmpty);

        await controller.lifecycleChanged(AppLifecycleState.paused);
        expect(installer.installed, hasLength(1));
      },
    );

    test(
      'a tap on Install mid-countdown ends the countdown, and only it installs',
      () async {
        final controller = build(
          installNotice: const Duration(milliseconds: 20),
        );
        await controller.setAutoInstall(true);
        await controller.installDownloaded();
        expect(controller.installCountdown, isNull);

        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(installer.installed, hasLength(1));
        expect(installer.unattended.single, isFalse);
      },
    );

    test(
      'waits for work in flight, and installs when it ends in the background',
      () async {
        final work = ValueNotifier(true);
        final controller = build(
          workInFlight: () => work.value,
          workChanges: work,
        );
        await controller.setAutoInstall(true);

        await controller.lifecycleChanged(AppLifecycleState.paused);
        expect(
          installer.installed,
          isEmpty,
          reason: 'a lab plan is generating',
        );

        await controller.lifecycleChanged(AppLifecycleState.resumed);
        work.value = false;
        await Future<void>.delayed(Duration.zero);
        expect(
          installer.installed,
          isEmpty,
          reason: 'back in front of them, so it counts down first',
        );
        expect(controller.installCountdown, isNotNull);

        work.value = true;
        await controller.lifecycleChanged(AppLifecycleState.paused);
        work.value = false;
        await Future<void>.delayed(Duration.zero);
        expect(installer.installed, hasLength(1));
        expect(installer.unattended.single, isTrue);
      },
    );

    test(
      'where Android would show its sheet, it only looks: nothing is downloaded or installed',
      () async {
        installer.silent = SilentInstall.androidTooOld;
        final controller = build();
        await controller.setAutoInstall(true);

        expect(controller.phase, UpdatePhase.available);
        expect(controller.installsAutomatically, isFalse);
        expect(
          adapter.requests,
          isEmpty,
          reason:
              'a download that can only end in a sheet repeats every launch',
        );
        await controller.lifecycleChanged(AppLifecycleState.paused);
        expect(installer.installed, isEmpty);
      },
    );

    test(
      'an install Android still wanted confirmed is not retried; the button installs it',
      () async {
        final controller = build();
        await controller.setAutoInstall(true);
        await controller.lifecycleChanged(AppLifecycleState.paused);
        installer.emit(
          const InstallEvent(InstallEventKind.confirmationRequired),
        );
        await Future<void>.delayed(Duration.zero);

        expect(controller.phase, UpdatePhase.readyToInstall);
        expect(controller.installsAutomatically, isFalse);

        await controller.lifecycleChanged(AppLifecycleState.resumed);
        await controller.lifecycleChanged(AppLifecycleState.paused);
        expect(
          installer.installed,
          hasLength(1),
          reason: 'not committed and declined on every trip away',
        );

        await controller.lifecycleChanged(AppLifecycleState.resumed);
        await controller.installDownloaded();
        expect(installer.installed, hasLength(2));
        expect(installer.unattended.last, isFalse, reason: 'a tap may ask');
      },
    );

    test(
      'leaving the app in the middle of a tapped install does not start a second one',
      () async {
        final controller = build();
        await controller.setAutoInstall(true);
        installer.whileAskingPermission = () async {
          installer.whileAskingPermission = null;
          await controller.lifecycleChanged(AppLifecycleState.paused);
        };

        await controller.installDownloaded();
        expect(installer.installed, hasLength(1));
        expect(installer.unattended.single, isFalse);
      },
    );

    test(
      'a later check of the release already downloaded keeps it ready, without fetching it again',
      () async {
        final controller = build();
        await controller.setAutoInstall(true);
        final downloads = adapter.requests.length;

        now = now.add(UpdateController.autoCheckInterval);
        await controller.lifecycleChanged(AppLifecycleState.resumed);

        expect(source.fetches, 2);
        expect(controller.phase, UpdatePhase.readyToInstall);
        expect(adapter.requests, hasLength(downloads));
      },
    );

    test(
      'turning it on carries on with a release that is already known',
      () async {
        final controller = build();
        await controller.checkForUpdates();
        expect(adapter.requests, isEmpty);

        await controller.setAutoInstall(true);
        expect(controller.phase, UpdatePhase.readyToInstall);
        expect(adapter.requests, isNotEmpty);
      },
    );

    test(
      'a lost connection is as quiet as the check; a corrupt download is shown',
      () async {
        final offline = build(http: _OfflineAdapter());
        await offline.setAutoInstall(true);
        expect(offline.phase, UpdatePhase.available);
        expect(offline.failure, isNull);

        adapter = FakeAdapter({_apkUrl: Reply(200, bytes: List.filled(64, 7))});
        now = now.add(UpdateController.autoCheckInterval);
        final corrupt = build();
        await corrupt.setAutoInstall(true);
        expect(corrupt.phase, UpdatePhase.failed);
        expect(corrupt.failure!.kind, UpdateFailureKind.checksumMismatch);
        await corrupt.lifecycleChanged(AppLifecycleState.paused);
        expect(installer.installed, isEmpty);
      },
    );
  });

  // Silences "unused" for Dio import used by the adapter helpers above.
  test('dio helper is wired', () => expect(dioFor(adapter), isA<Dio>()));
}

class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(
    requestOptions: options,
    reason: 'offline',
  );

  @override
  void close({bool force = false}) {}
}
