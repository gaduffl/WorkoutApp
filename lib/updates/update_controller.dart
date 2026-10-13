import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'apk_installer.dart';
import 'app_version.dart';
import 'update_downloader.dart';
import 'update_models.dart';
import 'update_settings.dart';
import 'update_source.dart';

typedef UpdateSourceFactory =
    UpdateSource Function(UpdateSettings settings, String? token);

/// The production wiring: GitHub's release API, or a manifest URL.
UpdateSourceFactory updateSourceFactoryFor(Dio dio) =>
    (settings, token) => switch (settings.source) {
      UpdateSourceKind.github => GitHubReleaseSource(
        repository: normalizeGitHubRepository(settings.githubRepository)!,
        dio: dio,
        token: token,
      ),
      UpdateSourceKind.server => ManifestUpdateSource(
        manifestUri: parseSecureUrl(settings.serverUrl)!,
        dio: dio,
        token: token,
      ),
    };

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,

  /// Waiting for the person to allow installs from this app in system settings.
  needsPermission,
  downloading,

  /// Downloaded and verified, not yet handed to Android — or handed over and
  /// dismissed, so the same file can be offered again without another download.
  readyToInstall,
  awaitingConfirmation,

  /// Committed with no confirmation to wait for. Android replaces the process
  /// when it finishes, so this is normally the last thing a build shows.
  installing,
  failed,
}

/// Looks for a newer release, downloads it, and hands it to Android.
///
/// By default nothing is fetched or installed without a tap; the automatic
/// check only *looks*. Auto-update is the opt-in exception. Installing replaces
/// the running process, so even then it never installs with work in flight —
/// mid-entry, or mid lab plan, that would throw the work away — and in front of
/// the person only after a countdown they can postpone.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.installer,
    required this.settingsStore,
    required this.tokenStore,
    required this.downloader,
    required this.sourceFactory,
    bool Function()? workInFlight,
    Listenable? workChanges,
    bool Function()? installInFront,
    this.installNotice = const Duration(seconds: 10),
    UpdateNotice Function(AppVersion version)? noticeFor,
    DateTime Function()? clock,
  }) : _workChanges = workChanges,
       _noticeFor = noticeFor,
       _clock = clock ?? DateTime.now,
       _workInFlight = workInFlight ?? _nothingInFlight,
       _installInFront = installInFront ?? _always {
    _events = installer.events.listen(_onInstallEvent);
    _workChanges?.addListener(_onWorkChanged);
  }

  final ApkInstaller installer;
  final UpdateSettingsStore settingsStore;
  final UpdateTokenStore tokenStore;
  final UpdateDownloader downloader;
  final UpdateSourceFactory sourceFactory;
  final DateTime Function() _clock;

  /// Whether something is running that a restart would cut off. An unattended
  /// install waits for it, and [_workChanges] says when to look again.
  final bool Function() _workInFlight;
  final Listenable? _workChanges;

  /// Whether auto-update may install while the app is on screen. False in
  /// easy mode: the person using it did not choose updates, and an app that
  /// closes under them reads as broken.
  final bool Function() _installInFront;

  /// How long the "updating in N s" banner shows before an install in front
  /// of the person, so the app closing is announced rather than a surprise.
  final Duration installNotice;

  /// The notification that brings the person back once an install has closed
  /// the app in front of them, in their language.
  final UpdateNotice Function(AppVersion version)? _noticeFor;

  static bool _nothingInFlight() => false;
  static bool _always() => true;

  /// A relaunch or return to the app inside this window does not re-ask the
  /// server: a few opens in an hour is a phone being fiddled with, not news.
  static const autoCheckInterval = Duration(hours: 1);

  late final StreamSubscription<InstallEvent> _events;
  CancelToken? _cancelToken;
  UpdateSource? _source;

  UpdatePhase _phase = UpdatePhase.idle;
  UpdateSettings _settings = const UpdateSettings();
  AppVersion? _installed;
  AvailableUpdate? _available;
  UpdateException? _failure;
  DateTime? _lastCheckedAt;
  File? _downloaded;
  int _received = 0;
  int? _total;
  bool _hasToken = false;
  bool _loaded = false;
  Future<void>? _loading;
  bool _disposed = false;
  SilentInstall _silentInstall = SilentInstall.unavailable;

  /// Starts true: the controller is built while the app launches on screen.
  bool _foreground = true;

  /// A tapped install is between its awaits, where the phase can still read
  /// "ready to install". Leaving the app in that moment must not start a
  /// second, unattended install of the same file.
  bool _tapped = false;

  Timer? _countdown;
  DateTime? _countdownEndsAt;

  /// "Later" on the banner: no install in front of the person until they have
  /// left the app and come back. Leaving still installs.
  bool _postponed = false;

  /// Android wanted an unattended install confirmed after all. Remembered so
  /// that every later trip to the background does not commit and decline the
  /// same thing again; the person installs it with the button instead.
  bool _unattendedDeclined = false;

  UpdatePhase get phase => _phase;
  UpdateSettings get settings => _settings;
  AppVersion? get installedVersion => _installed;
  AvailableUpdate? get available => _available;
  UpdateException? get failure => _failure;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  bool get hasToken => _hasToken;
  bool get loaded => _loaded;
  bool get supported => installer.isSupported;
  SilentInstall get silentInstall => _silentInstall;
  bool get unattendedDeclined => _unattendedDeclined;
  bool get installPostponed => _postponed;

  /// Time left before an install in front of the person, or null when none is
  /// counting down.
  Duration? get installCountdown {
    final ends = _countdownEndsAt;
    if (ends == null) return null;
    final left = ends.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether auto-update will install by itself on this device. False while
  /// Android would show its sheet — a sheet nobody asked for must not appear
  /// over another app — in which case auto-update only looks, and says so.
  bool get installsAutomatically =>
      _settings.autoInstall &&
      _silentInstall == SilentInstall.supported &&
      !_unattendedDeclined;

  /// 0–1 while the size is known, null when it is not (an indeterminate bar).
  double? get progress {
    final total = _total;
    if (total == null || total <= 0) return null;
    return (_received / total).clamp(0.0, 1.0);
  }

  int get receivedBytes => _received;
  int? get totalBytes => _total;

  bool get busy =>
      _phase == UpdatePhase.checking ||
      _phase == UpdatePhase.downloading ||
      _phase == UpdatePhase.awaitingConfirmation ||
      _phase == UpdatePhase.installing;

  /// Whether a newer build is known, for a badge somewhere other than the card.
  bool get updateAvailable => switch (_phase) {
    UpdatePhase.available ||
    UpdatePhase.needsPermission ||
    UpdatePhase.downloading ||
    UpdatePhase.readyToInstall ||
    UpdatePhase.awaitingConfirmation ||
    UpdatePhase.installing => true,
    UpdatePhase.failed => _available != null,
    _ => false,
  };

  /// Once per controller. Launch and the first return to the app both ask,
  /// and a second load would sweep away a download the first one's check had
  /// already started.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    _settings = await settingsStore.load();
    _hasToken = await tokenStore.read(_settings.source) != null;
    _lastCheckedAt = await settingsStore.lastCheckedAt();
    if (supported) {
      try {
        _installed = await installer.installedVersion();
      } on UpdateException {
        // Leaves the card without a version line rather than without a card.
      }
    }
    _silentInstall = await _readSilentInstall();
    // A build that has just replaced itself leaves its APK behind, and the
    // process that downloaded it is gone. Awaited: a later download must not
    // have its own file swept away by a clean-up still in flight.
    await downloader.discardAll();
    _loaded = true;
    notifyListeners();
  }

  /// The check on launch and on return to the app. Quiet by construction: it
  /// never shows an error, because a phone without signal is normal and not
  /// worth a red banner.
  Future<void> checkInBackground() async {
    if (!_loaded) await load();
    if (!supported ||
        !_settings.checksAutomatically ||
        !_settings.isConfigured) {
      return;
    }
    final last = _lastCheckedAt;
    if (last != null && _clock().difference(last) < autoCheckInterval) return;
    await checkForUpdates(background: true);
  }

  Future<void> checkForUpdates({bool background = false}) async {
    if (busy) return;
    if (!_loaded) await load();
    if (!supported) {
      return _fail(
        const UpdateException(UpdateFailureKind.unsupportedPlatform),
      );
    }
    if (!_settings.isConfigured) {
      if (background) return;
      return _fail(const UpdateException(UpdateFailureKind.notConfigured));
    }
    final previous = _phase;
    _phase = UpdatePhase.checking;
    _failure = null;
    notifyListeners();
    final bool newer;
    try {
      final installed = _installed ??= await installer.installedVersion();
      final token = await tokenStore.read(_settings.source);
      final source = sourceFactory(_settings, token);
      final latest = await source.fetchLatest();
      _source = source;
      _lastCheckedAt = _clock();
      await settingsStore.recordCheck(_lastCheckedAt!);
      newer = latest.version.isNewerThan(installed);
      if (newer) {
        // A file fetched for an older release must not be offered as this one.
        if (_available?.version != latest.version) _downloaded = null;
        _available = latest;
        // Asking again about a release already on disk must not send the card
        // back to "Download".
        _phase = _downloaded == null
            ? UpdatePhase.available
            : UpdatePhase.readyToInstall;
      } else {
        _available = null;
        _downloaded = null;
        _phase = UpdatePhase.upToDate;
        // An APK for a build this one has caught up to is dead weight.
        await downloader.discardAll();
      }
      notifyListeners();
    } on UpdateException catch (error) {
      if (background) {
        // Back to what the card was showing: a silent failure must not erase a
        // known update or leave the card stuck on "checking".
        _phase = previous == UpdatePhase.checking ? UpdatePhase.idle : previous;
        notifyListeners();
      } else {
        _fail(error);
      }
      return;
    }
    if (newer) await _advanceAutomatically();
  }

  /// Asks Android for permission if needed, downloads, verifies and installs.
  Future<void> downloadAndInstall() async {
    if (_available == null || busy || _tapped) return;
    if (_source == null) return checkForUpdates();
    _tapped = true;
    try {
      if (!await _installAllowed()) return;
      if (await _fetch()) await _install();
    } finally {
      _tapped = false;
    }
  }

  /// Downloads and verifies the known release, unless its file is already on
  /// disk. True when there is a verified file to install afterwards.
  ///
  /// [automatic] is auto-update's own fetch: losing the connection is as quiet
  /// as the check it follows, but any other failure is shown, because it will
  /// fail the same way next time and nobody would otherwise know why the
  /// update never arrives.
  Future<bool> _fetch({bool automatic = false}) async {
    final update = _available;
    final source = _source;
    if (update == null || source == null) return false;
    // A file that survived an earlier attempt for this exact release is
    // already verified; offering it again saves a download over mobile data.
    final existing = _downloaded;
    if (existing != null && await existing.exists()) return true;
    _phase = UpdatePhase.downloading;
    _failure = null;
    _received = 0;
    _total = update.sizeBytes;
    final cancel = _cancelToken = CancelToken();
    notifyListeners();
    try {
      await downloader.discardAll();
      _downloaded = await downloader.download(
        update,
        source,
        cancelToken: cancel,
        onProgress: (received, total) {
          _received = received;
          _total = total;
          notifyListeners();
        },
      );
    } on UpdateException catch (error) {
      _cancelToken = null;
      // A cancelled download is the person's own choice, not a failure.
      if (error.kind == UpdateFailureKind.cancelled ||
          (automatic && error.kind == UpdateFailureKind.network)) {
        _phase = UpdatePhase.available;
        notifyListeners();
      } else {
        _fail(error);
      }
      return false;
    }
    _cancelToken = null;
    _phase = UpdatePhase.readyToInstall;
    notifyListeners();
    return true;
  }

  Future<void> installDownloaded() async {
    if (_tapped) return;
    _tapped = true;
    try {
      await _install();
    } finally {
      _tapped = false;
    }
  }

  Future<void> _install() async {
    final file = _downloaded;
    if (file == null) return;
    if (!await _installAllowed()) return;
    _cancelCountdown();
    _phase = UpdatePhase.installing;
    _failure = null;
    notifyListeners();
    try {
      await installer.install(file, notice: _notice());
      // The commit succeeded. Where Android will show its sheet, its own event
      // normally lands first, but if it is late the person still sees that
      // something is waiting on them rather than a button that did nothing.
      if (_phase == UpdatePhase.installing &&
          _silentInstall != SilentInstall.supported) {
        _phase = UpdatePhase.awaitingConfirmation;
        notifyListeners();
      }
    } on UpdateException catch (error) {
      _fail(error);
    }
  }

  /// Turns auto-update on or off, and on, carries on with whatever is already
  /// known rather than waiting for the next launch.
  Future<void> setAutoInstall(bool enabled) async {
    await saveSettings(_settings.copyWith(autoInstall: enabled));
    if (!enabled) return;
    // A fresh opt-in is a fresh try, in case Android's answer has changed.
    _unattendedDeclined = false;
    _postponed = false;
    if (_available == null) {
      await checkInBackground();
    } else {
      await _advanceAutomatically();
    }
  }

  /// "Later" on the banner.
  void postponeInstall() {
    _postponed = true;
    _cancelCountdown();
    notifyListeners();
  }

  /// "Update now" on the banner: skip the rest of the countdown.
  Future<void> installNow() async {
    _cancelCountdown();
    if (_readyToInstallUnattended) await _commitUnattended();
  }

  /// Fed from the app's lifecycle in `main.dart`, so it runs whichever screen
  /// is showing. Inactive is ignored: a permission dialog or the notification
  /// shade makes the app inactive while it is still in front of the person.
  Future<void> lifecycleChanged(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        _postponed = false;
        await onResumed();
        await _installUnattended();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _foreground = false;
        await _installUnattended();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Auto-update's next step from wherever things stand: fetch the release it
  /// knows about, then install it as soon as nothing is in progress.
  ///
  /// Only where the install can be silent. A download that could only end in
  /// a sheet would be fetched again on every launch, because a new process
  /// starts by discarding what the last one left behind.
  Future<void> _advanceAutomatically() async {
    if (!installsAutomatically || busy) return;
    if (_phase == UpdatePhase.available && !await _fetch(automatic: true)) {
      return;
    }
    await _installUnattended();
  }

  /// Whether the downloaded release may be installed without a tap now, as
  /// far as the update and the person's work are concerned. Where the person
  /// is decides how: at once from the background, after a countdown in front.
  bool get _readyToInstallUnattended =>
      _downloaded != null &&
      _phase == UpdatePhase.readyToInstall &&
      !_tapped &&
      installsAutomatically &&
      !_workInFlight();

  Future<void> _installUnattended() async {
    if (!_readyToInstallUnattended) {
      // Something opened or started during the countdown: wait for it.
      _cancelCountdown();
      return;
    }
    if (!_foreground) {
      _cancelCountdown();
      return _commitUnattended();
    }
    if (_postponed || !_installInFront()) return;
    _startCountdown();
  }

  void _startCountdown() {
    if (_countdown != null) return;
    _countdownEndsAt = _clock().add(installNotice);
    _countdown = Timer(installNotice, () {
      _countdown = null;
      _countdownEndsAt = null;
      unawaited(_countdownElapsed());
    });
    notifyListeners();
  }

  Future<void> _countdownElapsed() async {
    // Checked again: the profile may have switched to easy mode meanwhile.
    final mayInstall =
        _readyToInstallUnattended &&
        (!_foreground || (!_postponed && _installInFront()));
    if (mayInstall) {
      await _commitUnattended();
    } else {
      notifyListeners();
    }
  }

  void _cancelCountdown() {
    final countdown = _countdown;
    if (countdown == null) return;
    countdown.cancel();
    _countdown = null;
    _countdownEndsAt = null;
    notifyListeners();
  }

  Future<void> _commitUnattended() async {
    final file = _downloaded!;
    _phase = UpdatePhase.installing;
    _failure = null;
    notifyListeners();
    try {
      await installer.install(file, unattended: true, notice: _notice());
    } on UpdateException catch (error) {
      _fail(error);
    }
  }

  /// Only for an install in front of the person: that is the one that closes
  /// the app under them. One that runs while they are elsewhere has nothing
  /// to bring them back from.
  UpdateNotice? _notice() {
    final version = _available?.version;
    if (!_foreground || version == null) return null;
    return _noticeFor?.call(version);
  }

  // Deferred: a route change is reported from inside the navigator's own
  // update, where a listener rebuilding widgets would throw.
  void _onWorkChanged() => scheduleMicrotask(() {
    if (!_disposed) unawaited(_installUnattended());
  });

  void cancelDownload() => _cancelToken?.cancel();

  Future<void> openInstallPermissionSettings() async {
    try {
      await installer.openInstallPermissionSettings();
    } on UpdateException catch (error) {
      _fail(error);
    }
  }

  /// Called when the app returns to the foreground. Coming back from the
  /// "install unknown apps" page with the switch on carries on where the
  /// person left off, instead of asking them to find the button again.
  ///
  /// Otherwise it is another chance to look: an app left open for days is
  /// never relaunched, so a check that ran only at launch would never run.
  Future<void> onResumed() async {
    // That same switch decides whether auto-update can install here.
    final silent = await _readSilentInstall();
    if (silent != _silentInstall) {
      _silentInstall = silent;
      notifyListeners();
    }
    if (_phase == UpdatePhase.needsPermission) {
      if (await installer.canInstallPackages()) await downloadAndInstall();
      return;
    }
    await checkInBackground();
  }

  /// Saves the source settings. A null [token] leaves the stored one alone, an
  /// empty one removes it — so editing the repository never wipes a credential
  /// the form did not show.
  Future<void> saveSettings(UpdateSettings settings, {String? token}) async {
    await settingsStore.save(settings);
    if (token != null) {
      if (token.trim().isEmpty) {
        await tokenStore.delete(settings.source);
      } else {
        await tokenStore.save(settings.source, token);
      }
    }
    final changedSource =
        settings.source != _settings.source ||
        settings.githubRepository != _settings.githubRepository ||
        settings.serverUrl != _settings.serverUrl;
    _settings = settings;
    _hasToken = await tokenStore.read(settings.source) != null;
    if (changedSource || token != null) {
      // What was learned from the old source says nothing about the new one.
      _available = null;
      _downloaded = null;
      _source = null;
      _failure = null;
      if (!busy) _phase = UpdatePhase.idle;
      await downloader.discardAll();
    }
    notifyListeners();
  }

  Future<SilentInstall> _readSilentInstall() async {
    if (!supported) return SilentInstall.unavailable;
    try {
      return await installer.silentInstallSupport();
    } on UpdateException {
      return SilentInstall.unavailable;
    }
  }

  Future<bool> _installAllowed() async {
    try {
      if (await installer.canInstallPackages()) return true;
    } on UpdateException catch (error) {
      _fail(error);
      return false;
    }
    _phase = UpdatePhase.needsPermission;
    notifyListeners();
    return false;
  }

  void _onInstallEvent(InstallEvent event) {
    switch (event.kind) {
      case InstallEventKind.awaitingConfirmation:
        _phase = UpdatePhase.awaitingConfirmation;
        notifyListeners();
      case InstallEventKind.cancelled:
        _phase = UpdatePhase.readyToInstall;
        notifyListeners();
      case InstallEventKind.confirmationRequired:
        _unattendedDeclined = true;
        _phase = UpdatePhase.readyToInstall;
        notifyListeners();
      case InstallEventKind.success:
        _available = null;
        _downloaded = null;
        _phase = UpdatePhase.upToDate;
        unawaited(downloader.discardAll());
        notifyListeners();
      case InstallEventKind.failed:
        _fail(UpdateException(UpdateFailureKind.installFailed, event.message));
    }
  }

  void _fail(UpdateException error) {
    _failure = error;
    _phase = UpdatePhase.failed;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _countdown?.cancel();
    _cancelToken?.cancel();
    _workChanges?.removeListener(_onWorkChanged);
    unawaited(_events.cancel());
    super.dispose();
  }
}
