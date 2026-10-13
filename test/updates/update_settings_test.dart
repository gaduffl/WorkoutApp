import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:morningcoach/updates/update_settings.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a repository is accepted as owner/name or as a pasted link', () {
    expect(
      normalizeGitHubRepository('gaduffl/WorkoutApp'),
      'gaduffl/WorkoutApp',
    );
    expect(
      normalizeGitHubRepository('https://github.com/gaduffl/WorkoutApp/'),
      'gaduffl/WorkoutApp',
    );
    expect(
      normalizeGitHubRepository('https://github.com/gaduffl/WorkoutApp.git'),
      'gaduffl/WorkoutApp',
    );
  });

  test('a repository that could change the API path is rejected', () {
    for (final raw in [
      '',
      'morningcoach',
      'a/b/c',
      '../etc',
      'a/..',
      'a/b?x=1',
      'a b/c',
      'http://example.org/a/b',
    ]) {
      expect(normalizeGitHubRepository(raw), isNull, reason: raw);
    }
  });

  test('only https server addresses are accepted', () {
    expect(
      parseSecureUrl('https://updates.example.org/latest.json'),
      isNotNull,
    );
    expect(parseSecureUrl('http://updates.example.org/latest.json'), isNull);
    expect(parseSecureUrl('updates.example.org'), isNull);
    expect(parseSecureUrl('https://'), isNull);
  });

  test('defaults point at the release repository and check on start', () async {
    final settings = await UpdateSettingsStore().load();
    expect(settings.source, UpdateSourceKind.github);
    expect(settings.githubRepository, defaultUpdateRepository);
    expect(settings.autoCheck, isTrue);
    expect(settings.isConfigured, isTrue);
    expect(
      const UpdateSettings(source: UpdateSourceKind.server).isConfigured,
      isFalse,
    );
  });

  test(
    'auto update is off by default, survives a reload, and implies the check',
    () async {
      expect((await UpdateSettingsStore().load()).autoInstall, isFalse);

      await UpdateSettingsStore().save(
        const UpdateSettings(autoCheck: false, autoInstall: true),
      );
      final loaded = await UpdateSettingsStore().load();
      expect(loaded.autoInstall, isTrue);
      expect(loaded.autoCheck, isFalse, reason: 'its own choice is kept');
      expect(loaded.checksAutomatically, isTrue);
      expect(
        loaded.copyWith(serverUrl: 'https://x.example').autoInstall,
        isTrue,
        reason: 'editing the source carries it',
      );
    },
  );

  test('saved settings and the last check survive a reload', () async {
    final store = UpdateSettingsStore();
    await store.save(
      const UpdateSettings(
        source: UpdateSourceKind.server,
        serverUrl: 'https://updates.example.org/latest.json',
        autoCheck: false,
      ),
    );
    final at = DateTime.utc(2026, 10, 1, 8);
    await store.recordCheck(at);

    final loaded = await UpdateSettingsStore().load();
    expect(loaded.source, UpdateSourceKind.server);
    expect(loaded.serverUrl, 'https://updates.example.org/latest.json');
    expect(loaded.autoCheck, isFalse);
    expect(await store.lastCheckedAt(), at);
  });
}

