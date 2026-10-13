import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/updates/app_version.dart';
import 'package:morningcoach/updates/update_downloader.dart';
import 'package:morningcoach/updates/update_models.dart';
import 'package:morningcoach/updates/update_source.dart';

import 'fakes.dart';

const _asset = 'https://api.github.com/repos/o/r/releases/assets/9';
const _signed = 'https://objects.githubusercontent.com/signed?sig=abc';
final _bytes = List<int>.generate(1000, (i) => i % 251);

AvailableUpdate _update({int? size, String? sha, String url = _asset}) =>
    AvailableUpdate(
      version: const AppVersion(name: '0.43.0', build: 72),
      downloadUri: Uri.parse(url),
      sizeBytes: size,
      sha256: sha,
      assetName: '../../evil.apk',
    );

Future<UpdateException> _failure(Future<Object?> call) async {
  try {
    await call;
  } on UpdateException catch (error) {
    return error;
  }
  fail('expected an UpdateException');
}

void main() {
  late Directory dir;
  setUp(() => dir = tempDir());

  UpdateDownloader downloader(FakeAdapter adapter) =>
      UpdateDownloader(dio: dioFor(adapter), directory: () async => dir);

  UpdateSource source(FakeAdapter adapter) => GitHubReleaseSource(
    repository: 'o/r',
    dio: dioFor(adapter),
    token: 'ghp_secret',
  );

  test(
    'follows GitHub\'s redirect without forwarding the token to the new host',
    () async {
      final adapter = FakeAdapter({
        _asset: Reply(302, headers: {'location': _signed}),
        _signed: Reply(200, bytes: _bytes),
      });
      final file = await downloader(
        adapter,
      ).download(_update(size: 1000, sha: sha256Of(_bytes)), source(adapter));

      expect(await file.readAsBytes(), _bytes);
      expect(adapter.requests[0].headers['Authorization'], 'Bearer ghp_secret');
      expect(adapter.requests[0].headers['Accept'], 'application/octet-stream');
      expect(adapter.requests[1].uri.host, 'objects.githubusercontent.com');
      expect(
        adapter.requests[1].headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
        reason:
            'the signed URL is its own credential; a bearer token breaks it and leaks',
      );
    },
  );

  test(
    'the file name comes from the parsed version, never from the server',
    () async {
      final adapter = FakeAdapter({_asset: Reply(200, bytes: _bytes)});
      final file = await downloader(
        adapter,
      ).download(_update(), source(adapter));
      expect(file.path, '${dir.path}/morningcoach-0.43.0-72.apk');
      expect(File('${file.path}.part').existsSync(), isFalse);
    },
  );

  test('reports progress against the declared length', () async {
    final adapter = FakeAdapter({
      _asset: Reply(
        200,
        chunks: [_bytes.sublist(0, 400), _bytes.sublist(400)],
        headers: {'content-length': '1000'},
      ),
    });
    final seen = <(int, int?)>[];
    await downloader(adapter).download(
      _update(),
      source(adapter),
      onProgress: (received, total) => seen.add((received, total)),
    );
    expect(seen.last, (1000, 1000));
    expect(seen.length, 2);
  });

  test('a checksum mismatch discards the file and says so', () async {
    final adapter = FakeAdapter({_asset: Reply(200, bytes: _bytes)});
    final error = await _failure(
      downloader(
        adapter,
      ).download(_update(sha: sha256Of([1])), source(adapter)),
    );
    expect(error.kind, UpdateFailureKind.checksumMismatch);
    expect(
      dir.listSync(),
      isEmpty,
      reason: 'nothing installable is left behind',
    );
  });

  test('a truncated download is refused by size before it is hashed', () async {
    final adapter = FakeAdapter({
      _asset: Reply(200, bytes: _bytes.sublist(0, 500)),
    });
    final error = await _failure(
      downloader(adapter).download(_update(size: 1000), source(adapter)),
    );
    expect(error.kind, UpdateFailureKind.sizeMismatch);
    expect(dir.listSync(), isEmpty);
  });

  test('an empty body is never accepted as an APK', () async {
    final adapter = FakeAdapter({_asset: Reply(200, bytes: const [])});
    final error = await _failure(
      downloader(adapter).download(_update(), source(adapter)),
    );
    expect(error.kind, UpdateFailureKind.sizeMismatch);
  });

  test('a redirect to plain http is refused', () async {
    final adapter = FakeAdapter({
      _asset: Reply(302, headers: {'location': 'http://evil.example/a.apk'}),
    });
    final error = await _failure(
      downloader(adapter).download(_update(), source(adapter)),
    );
    expect(error.kind, UpdateFailureKind.insecureUrl);
    expect(adapter.requests, hasLength(1));
  });

  test('a redirect loop is bounded', () async {
    final adapter = FakeAdapter({
      _asset: Reply(302, headers: {'location': _asset}),
    });
    final error = await _failure(
      downloader(adapter).download(_update(), source(adapter)),
    );
    expect(error.kind, UpdateFailureKind.badResponse);
    expect(adapter.requests.length, lessThan(10));
  });

  test('error statuses surface as the failure they are', () async {
    final adapter = FakeAdapter({_asset: Reply(404)});
    final error = await _failure(
      downloader(adapter).download(_update(), source(adapter)),
    );
    expect(error.kind, UpdateFailureKind.notFound);
  });

  test('cancelling mid-transfer stops it and leaves no partial file', () async {
    final adapter = FakeAdapter({
      _asset: Reply(
        200,
        chunks: [for (var i = 0; i < 50; i++) List.filled(20, i)],
        headers: {'content-length': '1000'},
      ),
    });
    final token = CancelToken();
    final error = await _failure(
      downloader(adapter).download(
        _update(),
        source(adapter),
        cancelToken: token,
        onProgress: (received, _) {
          if (received >= 100) token.cancel();
        },
      ),
    );
    expect(error.kind, UpdateFailureKind.cancelled);
    expect(dir.listSync(), isEmpty);
  });

  test(
    'discardAll removes only the APKs it owns and tolerates a missing folder',
    () async {
      File('${dir.path}/morningcoach-0.1.0-1.apk').writeAsBytesSync([1]);
      File('${dir.path}/morningcoach-0.2.0-2.apk.part').writeAsBytesSync([1]);
      File('${dir.path}/notes.txt').writeAsBytesSync([1]);
      File('${dir.path}/morningcoach-backup.json').writeAsBytesSync([1]);
      Directory('${dir.path}/nested').createSync();
      File('${dir.path}/nested/morningcoach-0.3.0-3.apk').writeAsBytesSync([1]);
      final adapter = FakeAdapter({});

      await downloader(adapter).discardAll();

      expect(
        dir
            .listSync()
            .map(
              (entry) => entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
            )
            .toSet(),
        {'notes.txt', 'morningcoach-backup.json', 'nested'},
      );
      expect(
        File('${dir.path}/nested/morningcoach-0.3.0-3.apk').existsSync(),
        isTrue,
      );

      final gone = UpdateDownloader(
        dio: dioFor(adapter),
        directory: () async => Directory('${dir.path}/missing'),
      );
      await gone.discardAll();
    },
  );
}
