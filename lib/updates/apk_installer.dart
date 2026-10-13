import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_version.dart';
import 'update_models.dart';

/// What Android's installer reported after the APK was handed to it.
enum InstallEventKind {
  /// The system confirmation sheet is on screen.
  awaitingConfirmation,

  /// Installed. In practice the process is replaced before this arrives, but a
  /// build that survives (a split-screen task, a test) still gets the answer.
  success,

  /// The person dismissed the confirmation sheet.
  cancelled,

  /// An unattended install that Android still wanted confirmed. The sheet was
  /// declined rather than put over whatever the person is doing, and the
  /// session given up.
  confirmationRequired,

  /// Android refused: a signature that does not match, a downgrade, a corrupt
  /// package, no space.
  failed,
}

/// Whether Android installs an update of this app without its confirmation
/// sheet and, if not, which condition on this device stands in the way.
enum SilentInstall {
  supported,

  /// Android 11 or older, which confirms every install.
  androidTooOld,

  /// "Install unknown apps" is off for MorningCoach.
  installNotAllowed,

  /// Another app store has claimed this app's updates (Android 14+).
  anotherStore,

  /// Not reported, or a reason this build has no name for.
  unavailable,
}

/// The notification Android posts once an install has closed the app in front
/// of the person, so they get back with a tap. Written in their language by
/// the caller: the new process that posts it has no Flutter engine to ask.
class UpdateNotice {
  const UpdateNotice({
    required this.channelName,
    required this.title,
    required this.body,
    required this.versionCode,
  });

  /// How the notification's channel is listed in Android's settings.
  final String channelName;
  final String title;
  final String body;

  /// The build being installed. A replacement by anything older — a manual
  /// downgrade, another install — posts nothing.
  final int versionCode;
}

class InstallEvent {
  const InstallEvent(this.kind, [this.message]);

  final InstallEventKind kind;
  final String? message;
}

/// The Android half of the updater: which build is installed, whether this app
/// may install packages, and the hand-off to `PackageInstaller`.
abstract class ApkInstaller {
  /// False off Android, where there is nothing to install into.
  bool get isSupported;

  Future<AppVersion> installedVersion();

  /// Whether the person has allowed this app to install packages. Android 8+
  /// makes that a per-app switch that is off until they turn it on.
  Future<bool> canInstallPackages();

  /// Opens the system page where that switch lives.
  Future<void> openInstallPermissionSettings();

  /// Whether an install would skip Android's confirmation sheet. The same
  /// question the platform answers when the session is committed, asked first
  /// so auto-update never commits one that would need a sheet.
  Future<SilentInstall> silentInstallSupport();

  /// Streams [apk] into a package-installer session and commits it.
  ///
  /// [unattended] marks an install nobody tapped: if Android wants it
  /// confirmed after all, the sheet is declined instead of shown and
  /// [InstallEventKind.confirmationRequired] reported. [notice], when given,
  /// is posted by the new build once it has replaced this one.
  ///
  /// Returns once the session is committed; what happens next arrives on
  /// [events].
  Future<void> install(
    File apk, {
    bool unattended = false,
    UpdateNotice? notice,
  });

  Stream<InstallEvent> get events;
}

class MethodChannelApkInstaller implements ApkInstaller {
  MethodChannelApkInstaller({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onCall);
  }

  /// Must match `ApkUpdater.CHANNEL` in `MainActivity`'s Kotlin sources.
  static const channelName = 'com.morningcoach.morningcoach/updater';

  final MethodChannel _channel;
  final _events = StreamController<InstallEvent>.broadcast();

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Stream<InstallEvent> get events => _events.stream;

  @override
  Future<AppVersion> installedVersion() async {
    final result = await _invoke<Map<Object?, Object?>>('installedVersion');
    final name = result?['versionName'];
    final code = result?['versionCode'];
    if (name is! String || code is! int) {
      throw const UpdateException(UpdateFailureKind.unsupportedPlatform);
    }
    // The platform's own name may carry a suffix; the numbers are what order.
    final parsed = AppVersion.tryParse(name);
    return AppVersion(name: parsed?.name ?? name, build: code);
  }

  @override
  Future<bool> canInstallPackages() async =>
      await _invoke<bool>('canInstallPackages') ?? false;

  @override
  Future<void> openInstallPermissionSettings() =>
      _invoke<void>('openInstallPermissionSettings');

  @override
  Future<SilentInstall> silentInstallSupport() async {
    final reason = await _invoke<String>('silentInstallSupport');
    return SilentInstall.values.firstWhere(
      (value) => value.name == reason,
      orElse: () => SilentInstall.unavailable,
    );
  }

  @override
  Future<void> install(
    File apk, {
    bool unattended = false,
    UpdateNotice? notice,
  }) async {
    try {
      await _channel.invokeMethod<void>('install', {
        'path': apk.path,
        'unattended': unattended,
        if (notice != null) ...{
          'noticeChannel': notice.channelName,
          'noticeTitle': notice.title,
          'noticeBody': notice.body,
          'noticeVersionCode': notice.versionCode,
        },
      });
    } on PlatformException catch (error) {
      throw UpdateException(
        error.code == 'permission'
            ? UpdateFailureKind.installPermissionMissing
            : UpdateFailureKind.installFailed,
        error.message,
      );
    }
  }

  Future<T?> _invoke<T>(String method) async {
    if (!isSupported) {
      throw const UpdateException(UpdateFailureKind.unsupportedPlatform);
    }
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      throw const UpdateException(UpdateFailureKind.unsupportedPlatform);
    } on PlatformException catch (error) {
      throw UpdateException(UpdateFailureKind.installFailed, error.message);
    }
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'installStatus') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final message = arguments['message'];
    final kind = switch (arguments['status']) {
      'awaitingConfirmation' => InstallEventKind.awaitingConfirmation,
      'success' => InstallEventKind.success,
      'cancelled' => InstallEventKind.cancelled,
      'confirmationRequired' => InstallEventKind.confirmationRequired,
      _ => InstallEventKind.failed,
    };
    _events.add(InstallEvent(kind, message is String ? message : null));
  }
}
