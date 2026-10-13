import 'dart:convert';

import 'package:dio/dio.dart';

import 'app_version.dart';
import 'update_models.dart';

/// Where the newest release is learned from.
///
/// A source only answers "what is the newest release and where is its APK".
/// Whether that is newer than what is installed is the controller's question,
/// and fetching the bytes is the downloader's — so a third kind of source is
/// one small class, not a change to either.
abstract class UpdateSource {
  /// The newest published release, whether or not it is newer than this build.
  Future<AvailableUpdate> fetchLatest();

  /// Headers the *first* download request carries.
  ///
  /// The credential is attached here rather than being handed to the downloader
  /// because only the source knows which host it may be sent to. The downloader
  /// never forwards these across a redirect: GitHub answers an asset request
  /// with a signed URL on another host, and a bearer token sent there is both a
  /// leak and, for object storage, a rejected request.
  Map<String, String> downloadHeaders(AvailableUpdate update);
}

final _sha256Hex = RegExp(r'^[0-9a-fA-F]{64}$');

void _requireHttps(Uri uri) {
  if (uri.scheme != 'https' || uri.host.isEmpty) {
    throw UpdateException(UpdateFailureKind.insecureUrl, uri.toString());
  }
}

/// Maps an unsuccessful HTTP status to the failure the person can act on.
UpdateException updateExceptionForStatus(
  int status, {
  String? rateLimitRemaining,
}) {
  if (status == 401) {
    return UpdateException(UpdateFailureKind.unauthorized, 'HTTP $status');
  }
  if (status == 403 || status == 429) {
    // GitHub answers an exhausted anonymous quota with 403; telling that apart
    // from a rejected token saves the person from rotating a good one.
    if (status == 429 || rateLimitRemaining == '0') {
      return UpdateException(UpdateFailureKind.rateLimited, 'HTTP $status');
    }
    return UpdateException(UpdateFailureKind.unauthorized, 'HTTP $status');
  }
  if (status == 404) {
    return UpdateException(UpdateFailureKind.notFound, 'HTTP $status');
  }
  return UpdateException(UpdateFailureKind.network, 'HTTP $status');
}

Future<Map<String, Object?>> _getJson(
  Dio dio,
  Uri uri,
  Map<String, String> headers,
) async {
  final Response<String> response;
  try {
    response = await dio.getUri<String>(
      uri,
      options: Options(
        headers: headers,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
        followRedirects: true,
      ),
    );
  } on DioException catch (error) {
    throw UpdateException(UpdateFailureKind.network, error.message);
  }
  final status = response.statusCode ?? 0;
  if (status != 200) {
    throw updateExceptionForStatus(
      status,
      rateLimitRemaining: response.headers.value('x-ratelimit-remaining'),
    );
  }
  try {
    final decoded = jsonDecode(response.data ?? '');
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // Falls through to the shared "not an update description" failure.
  }
  throw const UpdateException(UpdateFailureKind.badResponse);
}

/// The repository's newest non-draft, non-prerelease GitHub Release.
///
/// Reads the release API rather than scraping a page or guessing a download
/// URL, because that is the one route that also works for a private repository.
class GitHubReleaseSource implements UpdateSource {
  GitHubReleaseSource({
    required this.repository,
    required Dio dio,
    this.token,
    Uri? apiBase,
  }) : _dio = dio,
       apiBase = apiBase ?? Uri.parse('https://api.github.com');

  /// `owner/name`.
  final String repository;
  final String? token;
  final Uri apiBase;
  final Dio _dio;

  Map<String, String> get _auth => {
    if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
  };

  @override
  Future<AvailableUpdate> fetchLatest() async {
    _requireHttps(apiBase);
    final json = await _getJson(
      _dio,
      apiBase.resolve('/repos/$repository/releases/latest'),
      {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        ..._auth,
      },
    );
    final version =
        AppVersion.tryParse('${json['tag_name'] ?? ''}') ??
        AppVersion.tryParse('${json['name'] ?? ''}');
    if (version == null) {
      throw const UpdateException(UpdateFailureKind.badResponse);
    }
    final assets = json['assets'];
    final apks = <Map<String, Object?>>[
      if (assets is List)
        for (final asset in assets)
          if (asset is Map<String, Object?> &&
              '${asset['name']}'.toLowerCase().endsWith('.apk') &&
              asset['url'] is String)
            asset,
    ];
    if (apks.isEmpty) throw const UpdateException(UpdateFailureKind.noApk);
    // The workflow publishes exactly one, but a release someone attached a
    // second build to by hand should still resolve to this app's own APK.
    final asset = apks.firstWhere(
      (candidate) =>
          '${candidate['name']}'.toLowerCase().startsWith('morningcoach'),
      orElse: () => apks.first,
    );
    final uri = Uri.parse(asset['url']! as String);
    _requireHttps(uri);
    final digest = RegExp(
      r'^sha256:([0-9a-fA-F]{64})$',
    ).firstMatch('${asset['digest'] ?? ''}');
    final size = asset['size'];
    return AvailableUpdate(
      version: version,
      downloadUri: uri,
      sizeBytes: size is int && size > 0 ? size : null,
      sha256: digest?.group(1)!.toLowerCase(),
      notes: '${json['body'] ?? ''}'.trim(),
      publishedAt: DateTime.tryParse('${json['published_at'] ?? ''}'),
      assetName: '${asset['name']}',
    );
  }

  @override
  Map<String, String> downloadHeaders(AvailableUpdate update) => {
    // Without this the asset endpoint returns the asset's JSON description
    // instead of redirecting to its bytes.
    'Accept': 'application/octet-stream',
    ..._auth,
  };
}

/// A self-hosted release server publishing one small JSON document:
///
/// ```json
/// {
///   "version": "0.43.0+72",
///   "apk_url": "https://updates.example.org/morningcoach-0.43.0-72.apk",
///   "sha256": "<64 hex characters>",
///   "size": 52428800,
///   "notes": "What changed",
///   "published_at": "2026-10-01T08:00:00Z"
/// }
/// ```
///
/// `sha256` is required, unlike on GitHub: a plain file server publishes no
/// digest of its own, so the manifest is the only thing that can vouch for the
/// bytes between the server and the installer. (Android still refuses a build
/// signed by a different key, which is the backstop, not the first check.)
class ManifestUpdateSource implements UpdateSource {
  ManifestUpdateSource({
    required this.manifestUri,
    required Dio dio,
    this.token,
  }) : _dio = dio;

  final Uri manifestUri;
  final String? token;
  final Dio _dio;

  Map<String, String> get _auth => {
    if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
  };

  @override
  Future<AvailableUpdate> fetchLatest() async {
    _requireHttps(manifestUri);
    final json = await _getJson(_dio, manifestUri, {
      'Accept': 'application/json',
      ..._auth,
    });
    final version = AppVersion.tryParse('${json['version'] ?? ''}');
    final apkUrl = json['apk_url'];
    final digest = '${json['sha256'] ?? ''}';
    if (version == null || apkUrl is! String || !_sha256Hex.hasMatch(digest)) {
      throw const UpdateException(UpdateFailureKind.badResponse);
    }
    // Resolved against the manifest so a server can publish a relative path.
    final uri = manifestUri.resolve(apkUrl);
    _requireHttps(uri);
    final size = json['size'];
    return AvailableUpdate(
      version: version,
      downloadUri: uri,
      sizeBytes: size is int && size > 0 ? size : null,
      sha256: digest.toLowerCase(),
      notes: '${json['notes'] ?? ''}'.trim(),
      publishedAt: DateTime.tryParse('${json['published_at'] ?? ''}'),
      assetName: uri.pathSegments.isEmpty ? null : uri.pathSegments.last,
    );
  }

  @override
  Map<String, String> downloadHeaders(AvailableUpdate update) => {
    // The APK may live on a CDN the manifest merely points at; the credential
    // belongs to the manifest's host and goes nowhere else.
    if (update.downloadUri.host == manifestUri.host) ..._auth,
  };
}
