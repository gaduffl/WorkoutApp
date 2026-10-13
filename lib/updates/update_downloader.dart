import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'update_models.dart';
import 'update_source.dart';

typedef DownloadProgress = void Function(int received, int? total);

/// Fetches an APK to disk and refuses to hand back one that does not match what
/// the source promised.
class UpdateDownloader {
  UpdateDownloader({required Dio dio, required this.directory}) : _dio = dio;

  final Dio _dio;

  /// Resolved per call: the temporary directory is a platform lookup, and a
  /// test supplies its own.
  final Future<Directory> Function() directory;

  /// Redirects followed by hand. GitHub needs one (asset API → signed object
  /// URL); a handful is generous and bounds a redirect loop.
  static const _maxRedirects = 5;

  static String fileNameFor(AvailableUpdate update) {
    final version = update.version;
    final build = version.build;
    // Built from the parsed version, never from the server's asset name, so a
    // hostile name cannot steer where the file lands.
    return 'morningcoach-${version.name}${build == null ? '' : '-$build'}.apk';
  }

  Future<File> download(
    AvailableUpdate update,
    UpdateSource source, {
    DownloadProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    final folder = await directory();
    await folder.create(recursive: true);
    final target = File('${folder.path}/${fileNameFor(update)}');
    final partial = File('${target.path}.part');
    try {
      await _fetch(update, source, partial, onProgress, cancelToken);
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } on DioException catch (error) {
      await _discard(partial);
      throw error.type == DioExceptionType.cancel
          ? const UpdateException(UpdateFailureKind.cancelled)
          : UpdateException(UpdateFailureKind.network, error.message);
    } on FileSystemException catch (error) {
      await _discard(partial);
      throw UpdateException(UpdateFailureKind.storage, error.message);
    } on SocketException catch (error) {
      await _discard(partial);
      throw UpdateException(UpdateFailureKind.network, error.message);
    } catch (_) {
      // A partial file is never left to be mistaken for a download.
      await _discard(partial);
      rethrow;
    }
  }

  Future<void> _fetch(
    AvailableUpdate update,
    UpdateSource source,
    File partial,
    DownloadProgress? onProgress,
    CancelToken? cancelToken,
  ) async {
    var uri = update.downloadUri;
    var headers = source.downloadHeaders(update);
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (uri.scheme != 'https') {
        throw UpdateException(UpdateFailureKind.insecureUrl, uri.toString());
      }
      final response = await _dio.getUri<ResponseBody>(
        uri,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      final body = response.data!;
      if (const {301, 302, 303, 307, 308}.contains(status)) {
        final location = response.headers.value('location');
        // The body of a redirect is never read; leaving the stream untouched
        // would hold the connection open.
        unawaited(body.stream.listen((_) {}).cancel());
        if (location == null) {
          throw const UpdateException(UpdateFailureKind.badResponse);
        }
        uri = uri.resolve(location);
        // Credentials stop at the first hop.
        headers = const {};
        continue;
      }
      if (status != 200) {
        unawaited(body.stream.listen((_) {}).cancel());
        throw updateExceptionForStatus(
          status,
          rateLimitRemaining: response.headers.value('x-ratelimit-remaining'),
        );
      }
      final declared = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      await _write(body, partial, declared ?? update.sizeBytes, onProgress);
      await _verify(partial, update);
      return;
    }
    throw const UpdateException(UpdateFailureKind.badResponse, 'redirects');
  }

  Future<void> _write(
    ResponseBody body,
    File partial,
    int? total,
    DownloadProgress? onProgress,
  ) async {
    final sink = partial.openWrite();
    var received = 0;
    try {
      await for (final chunk in body.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<void> _verify(File partial, AvailableUpdate update) async {
    final length = await partial.length();
    final expectedSize = update.sizeBytes;
    if (expectedSize != null && length != expectedSize) {
      throw UpdateException(
        UpdateFailureKind.sizeMismatch,
        '$length of $expectedSize bytes',
      );
    }
    if (length == 0) {
      throw const UpdateException(UpdateFailureKind.sizeMismatch, 'empty');
    }
    final expectedDigest = update.sha256;
    if (expectedDigest == null) return;
    // Streamed through the hash: an APK is tens of megabytes.
    final digest = await sha256.bind(partial.openRead()).first;
    if (digest.toString() != expectedDigest) {
      throw const UpdateException(UpdateFailureKind.checksumMismatch);
    }
  }

  /// The files this class writes: a finished APK or its `.part`.
  static final _owned = RegExp(
    r'^morningcoach-[0-9.]+(-[0-9]+)?\.apk(\.part)?$',
  );

  /// Removes every APK this downloader left behind, finished or partial.
  ///
  /// Deletes by name, not by emptying the folder. The directory is injected, and
  /// a recursive delete of whatever it points at turns one wrong path into data
  /// loss.
  ///
  /// Synchronous I/O on purpose: a folder of a few files is microseconds of work,
  /// and a clean-up that must complete before a screen can load would otherwise
  /// never finish under a widget test's fake clock.
  Future<void> discardAll() async {
    final folder = await directory();
    try {
      if (!folder.existsSync()) return;
      for (final entry in folder.listSync(followLinks: false)) {
        if (entry is! File) continue;
        if (_owned.hasMatch(entry.uri.pathSegments.last)) entry.deleteSync();
      }
    } on FileSystemException {
      // Housekeeping only: a file Android still holds open is retried on the
      // next check, and must not turn a successful update into an error.
    }
  }

  Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Same as above.
    }
  }
}
