import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/updates/update_models.dart';
import 'package:morningcoach/updates/update_source.dart';

import 'fakes.dart';

const _latest = 'https://api.github.com/repos/o/r/releases/latest';

Future<UpdateException> _failure(Future<Object?> call) async {
  try {
    await call;
  } on UpdateException catch (error) {
    return error;
  }
  fail('expected an UpdateException');
}

void main() {
  GitHubReleaseSource github(FakeAdapter adapter, {String? token}) =>
      GitHubReleaseSource(
        repository: 'o/r',
        dio: dioFor(adapter),
        token: token,
      );

  group('GitHub releases', () {
    test('reads the version, asset, size, digest and notes', () async {
      final digest = sha256Of([1, 2, 3, 4]);
      final adapter = FakeAdapter({
        _latest: Reply(
          200,
          body: githubRelease(
            assets: [
              githubAsset(size: 4, digest: 'sha256:${digest.toUpperCase()}'),
            ],
          ),
        ),
      });
      final update = await github(adapter).fetchLatest();

      expect(update.version.toString(), '0.43.0+72');
      expect(update.sizeBytes, 4);
      expect(update.sha256, digest, reason: 'normalised to lowercase');
      expect(update.notes, 'Private signed Android build.');
      expect(update.downloadUri.path, '/repos/o/r/releases/assets/9');
      expect(update.publishedAt, DateTime.utc(2026, 10, 1, 8));
    });

    test(
      'a private repository is read with the token, an open one without',
      () async {
        final adapter = FakeAdapter({
          _latest: Reply(200, body: githubRelease()),
        });
        await github(adapter, token: 'ghp_secret').fetchLatest();
        await github(adapter).fetchLatest();

        expect(
          adapter.requests[0].headers['Authorization'],
          'Bearer ghp_secret',
        );
        expect(
          adapter.requests[1].headers.containsKey('Authorization'),
          isFalse,
        );
        expect(
          adapter.requests[0].headers['Accept'],
          'application/vnd.github+json',
        );
      },
    );

    test('the asset request asks for the bytes, not the description', () async {
      final adapter = FakeAdapter({_latest: Reply(200, body: githubRelease())});
      final source = github(adapter, token: 't');
      final update = await source.fetchLatest();
      expect(source.downloadHeaders(update), {
        'Accept': 'application/octet-stream',
        'Authorization': 'Bearer t',
      });
    });

    test('prefers this app\'s own APK among several attachments', () async {
      final adapter = FakeAdapter({
        _latest: Reply(
          200,
          body: githubRelease(
            assets: [
              githubAsset(
                name: 'other-tool.apk',
                url: 'https://api.github.com/a/1',
              ),
              githubAsset(name: 'notes.txt', url: 'https://api.github.com/a/2'),
              githubAsset(),
            ],
          ),
        ),
      });
      final update = await github(adapter).fetchLatest();
      expect(update.assetName, 'morningcoach-0.43.0-72.apk');
    });

    test('a release without an APK says so', () async {
      final adapter = FakeAdapter({
        _latest: Reply(200, body: githubRelease(assets: [])),
      });
      expect(
        (await _failure(github(adapter).fetchLatest())).kind,
        UpdateFailureKind.noApk,
      );
    });

    test(
      'an unreadable tag is a bad response, not a silent "no update"',
      () async {
        final adapter = FakeAdapter({
          _latest: Reply(200, body: githubRelease(tag: 'nightly')),
        });
        expect(
          (await _failure(github(adapter).fetchLatest())).kind,
          UpdateFailureKind.badResponse,
        );
      },
    );

    test('statuses map to the problem the person can act on', () async {
      Future<UpdateFailureKind> kindFor(Reply reply) async => (await _failure(
        github(FakeAdapter({_latest: reply})).fetchLatest(),
      )).kind;

      expect(await kindFor(Reply(404)), UpdateFailureKind.notFound);
      expect(await kindFor(Reply(401)), UpdateFailureKind.unauthorized);
      expect(await kindFor(Reply(403)), UpdateFailureKind.unauthorized);
      expect(
        await kindFor(Reply(403, headers: {'x-ratelimit-remaining': '0'})),
        UpdateFailureKind.rateLimited,
        reason: 'an exhausted quota is not a rejected token',
      );
      expect(await kindFor(Reply(500)), UpdateFailureKind.network);
      expect(
        await kindFor(Reply(200, body: 'not json')),
        UpdateFailureKind.badResponse,
      );
    });

    test('an asset served over plain http is refused', () async {
      final adapter = FakeAdapter({
        _latest: Reply(
          200,
          body: githubRelease(
            assets: [githubAsset(url: 'http://api.github.com/a/1')],
          ),
        ),
      });
      expect(
        (await _failure(github(adapter).fetchLatest())).kind,
        UpdateFailureKind.insecureUrl,
      );
    });
  });

  group('release manifest', () {
    final manifest = Uri.parse('https://updates.example.org/app/latest.json');
    ManifestUpdateSource server(FakeAdapter adapter, {String? token}) =>
        ManifestUpdateSource(
          manifestUri: manifest,
          dio: dioFor(adapter),
          token: token,
        );
    final digest = sha256Of([9, 9]);

    String body({String? apk, String? sha, String version = '0.43.0+72'}) =>
        '{"version":"$version","apk_url":"${apk ?? 'morningcoach.apk'}",'
        '"sha256":"${sha ?? digest}","size":2,"notes":" Fixes "}';

    test('resolves a relative APK path against the manifest', () async {
      final adapter = FakeAdapter({
        manifest.toString(): Reply(200, body: body()),
      });
      final update = await server(adapter).fetchLatest();
      expect(
        update.downloadUri.toString(),
        'https://updates.example.org/app/morningcoach.apk',
      );
      expect(update.sha256, digest);
      expect(update.notes, 'Fixes');
    });

    test(
      'a manifest without a checksum is rejected: nothing else vouches for the file',
      () async {
        final adapter = FakeAdapter({
          manifest.toString(): Reply(
            200,
            body: '{"version":"0.43.0+72","apk_url":"a.apk"}',
          ),
        });
        expect(
          (await _failure(server(adapter).fetchLatest())).kind,
          UpdateFailureKind.badResponse,
        );
      },
    );

    test('a manifest over http is never requested', () async {
      final adapter = FakeAdapter({});
      final source = ManifestUpdateSource(
        manifestUri: Uri.parse('http://updates.example.org/latest.json'),
        dio: dioFor(adapter),
      );
      expect(
        (await _failure(source.fetchLatest())).kind,
        UpdateFailureKind.insecureUrl,
      );
      expect(adapter.requests, isEmpty);
    });

    test('the token goes only to the manifest\'s own host', () async {
      final adapter = FakeAdapter({
        manifest.toString(): Reply(
          200,
          body: body(apk: 'https://cdn.example.net/morningcoach.apk'),
        ),
      });
      final source = server(adapter, token: 'secret');
      final update = await source.fetchLatest();
      expect(source.downloadHeaders(update), isEmpty);

      final sameHost = AvailableUpdate(
        version: update.version,
        downloadUri: Uri.parse('https://updates.example.org/a.apk'),
      );
      expect(source.downloadHeaders(sameHost), {
        'Authorization': 'Bearer secret',
      });
    });
  });
}

