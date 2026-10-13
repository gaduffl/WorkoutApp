import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
// ignore: implementation_imports
import 'package:dio/src/response/response_stream_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/updates/apk_installer.dart';
import 'package:morningcoach/updates/app_version.dart';
import 'package:morningcoach/updates/update_models.dart';
import 'package:morningcoach/updates/update_settings.dart';
import 'package:morningcoach/updates/update_source.dart';

class Reply {
  Reply(
    this.status, {
    this.body = '',
    this.bytes,
    this.headers = const {},
    this.chunks,
  });

  final int status;
  final String body;
  final List<int>? bytes;
  final Map<String, String> headers;

  /// When set, delivered one by one with the pause between them, so a test can
  /// act (cancel) while a download is genuinely in flight.
  final List<List<int>>? chunks;
}

/// Answers by URL and remembers every request exactly as it was sent.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.routes);

  final Map<String, Reply> routes;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final reply = routes[options.uri.toString()];
    if (reply == null) return ResponseBody.fromString('', 404);
    final headers = {
      for (final entry in reply.headers.entries) entry.key: [entry.value],
    };
    final chunks = reply.chunks;
    if (chunks != null) {
      Stream<Uint8List> body() async* {
        for (final chunk in chunks) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          yield Uint8List.fromList(chunk);
        }
      }

      // The same wrapper Dio's own adapters apply: it is what turns a
      // CancelToken into an error on an in-flight body.
      return ResponseBody(
        handleResponseStream(options, ResponseBody(body(), reply.status)),
        reply.status,
        headers: headers,
      );
    }
    final bytes = reply.bytes;
    if (bytes != null) {
      return ResponseBody.fromBytes(bytes, reply.status, headers: headers);
    }
    return ResponseBody.fromString(reply.body, reply.status, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

Dio dioFor(FakeAdapter adapter) => Dio()..httpClientAdapter = adapter;

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

String githubRelease({
  String tag = 'v0.43.0+72',
  List<Map<String, Object?>>? assets,
  String body = 'Private signed Android build.',
}) => jsonEncode({
  'tag_name': tag,
  'body': body,
  'published_at': '2026-10-01T08:00:00Z',
  'assets': assets ?? [githubAsset()],
});

Map<String, Object?> githubAsset({
  String name = 'morningcoach-0.43.0-72.apk',
  String url = 'https://api.github.com/repos/o/r/releases/assets/9',
  int size = 4,
  String? digest,
}) => {
  'name': name,
  'url': url,
  'size': size,
  if (digest != null) 'digest': digest,
};

class FakeInstaller implements ApkInstaller {
  FakeInstaller({
    this.version = const AppVersion(name: '0.42.0', build: 71),
    this.allowed = true,
    this.supported = true,
    this.silent = SilentInstall.unavailable,
  });

  AppVersion version;
  bool allowed;
  bool supported;
  SilentInstall silent;
  final installed = <File>[];

  /// Parallel to [installed]: whether each install was committed unattended.
  final unattended = <bool>[];
  var permissionPageOpened = 0;
  Object? installError;
  final _events = StreamController<InstallEvent>.broadcast();

  @override
  bool get isSupported => supported;

  @override
  Stream<InstallEvent> get events => _events.stream;

  void emit(InstallEvent event) => _events.add(event);

  @override
  Future<AppVersion> installedVersion() async => version;

  /// Runs while the permission question is in flight, so a test can land an
  /// event in the middle of an install.
  Future<void> Function()? whileAskingPermission;

  @override
  Future<bool> canInstallPackages() async {
    await whileAskingPermission?.call();
    return allowed;
  }

  @override
  Future<void> openInstallPermissionSettings() async => permissionPageOpened++;

  @override
  Future<SilentInstall> silentInstallSupport() async => silent;

  /// Parallel to [installed]: the notice each install asked Android to post.
  final notices = <UpdateNotice?>[];

  @override
  Future<void> install(
    File apk, {
    bool unattended = false,
    UpdateNotice? notice,
  }) async {
    if (installError case final Object error) throw error;
    installed.add(apk);
    this.unattended.add(unattended);
    notices.add(notice);
  }
}

class MemoryTokens extends UpdateTokenStore {
  final values = <UpdateSourceKind, String>{};

  @override
  Future<String?> read(UpdateSourceKind kind) async => values[kind];

  @override
  Future<void> save(UpdateSourceKind kind, String value) async =>
      values[kind] = value.trim();

  @override
  Future<void> delete(UpdateSourceKind kind) async => values.remove(kind);
}

/// Returns a fixed release and says what a download would carry.
class FixedSource implements UpdateSource {
  FixedSource(this.update);

  AvailableUpdate update;
  Object? error;
  var fetches = 0;

  @override
  Future<AvailableUpdate> fetchLatest() async {
    fetches++;
    if (error case final Object e) throw e;
    return update;
  }

  @override
  Map<String, String> downloadHeaders(AvailableUpdate update) => const {};
}

Directory tempDir() {
  final dir = Directory.systemTemp.createTempSync('updates_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}
