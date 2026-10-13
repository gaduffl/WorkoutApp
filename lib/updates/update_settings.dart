import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UpdateSourceKind { github, server }

/// The repository releases are published by `.github/workflows/flutter-ci.yml`.
const defaultUpdateRepository = 'gaduffl/WorkoutApp';

/// Accepts `owner/name` or a pasted `https://github.com/owner/name` link and
/// returns `owner/name`, or null for anything else.
///
/// The value ends up inside an API path, so it is validated to the characters
/// GitHub allows rather than escaped: a stray `?` or `..` is a typo to reject,
/// not input to carry.
String? normalizeGitHubRepository(String raw) {
  var text = raw.trim();
  final link = RegExp(
    r'^https://(?:www\.)?github\.com/',
    caseSensitive: false,
  ).firstMatch(text);
  if (link != null) text = text.substring(link.end);
  if (text.endsWith('.git')) text = text.substring(0, text.length - 4);
  text = text.replaceAll(RegExp(r'/+$'), '');
  final match = RegExp(
    r'^([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/([A-Za-z0-9._-]{1,100})$',
  ).firstMatch(text);
  if (match == null || match.group(2) == '.' || match.group(2) == '..') {
    return null;
  }
  return text;
}

/// An `https` URL with a host, or null. Plain `http` is rejected: an update is
/// code the phone will run.
Uri? parseSecureUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri;
}

class UpdateSettings {
  const UpdateSettings({
    this.source = UpdateSourceKind.github,
    this.githubRepository = defaultUpdateRepository,
    this.serverUrl = '',
    this.autoCheck = true,
    this.autoInstall = false,
  });

  final UpdateSourceKind source;
  final String githubRepository;
  final String serverUrl;

  /// Whether the app looks for an update by itself when it is opened.
  final bool autoCheck;

  /// Auto-update: download a new release and install it without a tap.
  ///
  /// Off by default, because it replaces the running app. Where Android would
  /// still ask for confirmation it degrades to looking only; see
  /// `UpdateController.installsInBackground`.
  final bool autoInstall;

  /// Auto-update has to look before it can fetch, so it implies the check.
  bool get checksAutomatically => autoCheck || autoInstall;

  bool get isConfigured => switch (source) {
    UpdateSourceKind.github =>
      normalizeGitHubRepository(githubRepository) != null,
    UpdateSourceKind.server => parseSecureUrl(serverUrl) != null,
  };

  UpdateSettings copyWith({
    UpdateSourceKind? source,
    String? githubRepository,
    String? serverUrl,
    bool? autoCheck,
    bool? autoInstall,
  }) => UpdateSettings(
    source: source ?? this.source,
    githubRepository: githubRepository ?? this.githubRepository,
    serverUrl: serverUrl ?? this.serverUrl,
    autoCheck: autoCheck ?? this.autoCheck,
    autoInstall: autoInstall ?? this.autoInstall,
  );
}

/// Device-level, deliberately not per profile and not in the database: which
/// server a phone updates from says nothing about anyone's health, and a
/// synced or backed-up copy would point another device at it.
class UpdateSettingsStore {
  static const _source = 'update_source';
  static const _repository = 'update_github_repository';
  static const _serverUrl = 'update_server_url';
  static const _autoCheck = 'update_auto_check';
  static const _autoInstall = 'update_auto_install';
  static const _lastChecked = 'update_last_checked_at';

  Future<UpdateSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    const fallback = UpdateSettings();
    return UpdateSettings(
      source: UpdateSourceKind.values.firstWhere(
        (kind) => kind.name == preferences.getString(_source),
        orElse: () => fallback.source,
      ),
      githubRepository:
          preferences.getString(_repository) ?? fallback.githubRepository,
      serverUrl: preferences.getString(_serverUrl) ?? fallback.serverUrl,
      autoCheck: preferences.getBool(_autoCheck) ?? fallback.autoCheck,
      autoInstall: preferences.getBool(_autoInstall) ?? fallback.autoInstall,
    );
  }

  Future<void> save(UpdateSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_source, settings.source.name);
    await preferences.setString(_repository, settings.githubRepository);
    await preferences.setString(_serverUrl, settings.serverUrl);
    await preferences.setBool(_autoCheck, settings.autoCheck);
    await preferences.setBool(_autoInstall, settings.autoInstall);
  }

  Future<DateTime?> lastCheckedAt() async {
    final preferences = await SharedPreferences.getInstance();
    return DateTime.tryParse(preferences.getString(_lastChecked) ?? '');
  }

  Future<void> recordCheck(DateTime at) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_lastChecked, at.toUtc().toIso8601String());
  }
}

/// Access tokens for a private repository or server, in Android encrypted
/// storage beside the AI keys and outside every export allowlist.
///
/// One slot per source kind: a GitHub token must never be sent to a server URL
/// someone later types into the other field.
class UpdateTokenStore {
  UpdateTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());

  final FlutterSecureStorage _storage;

  static String _key(UpdateSourceKind kind) => 'update_token_${kind.name}';

  Future<String?> read(UpdateSourceKind kind) async {
    final value = await _storage.read(key: _key(kind));
    return value == null || value.trim().isEmpty ? null : value.trim();
  }

  Future<void> save(UpdateSourceKind kind, String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return delete(kind);
    await _storage.write(key: _key(kind), value: trimmed);
  }

  Future<void> delete(UpdateSourceKind kind) =>
      _storage.delete(key: _key(kind));
}

