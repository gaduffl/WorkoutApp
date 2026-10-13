import 'app_version.dart';

/// Why an update step failed, as a kind the UI can phrase in either language.
///
/// The service never builds user-facing prose: it has no locale, and a
/// hard-coded English string here would be the one untranslated message in the
/// app.
enum UpdateFailureKind {
  /// The settings do not name a repository or server yet.
  notConfigured,
  notFound,

  /// The host rejected the token, or wanted one and was given none.
  unauthorized,
  rateLimited,
  network,

  /// The file could not be written — usually a full disk.
  storage,

  /// The release carries no APK, or none this app can use.
  noApk,

  /// The server answered with something that is not an update description.
  badResponse,

  /// A URL that is not `https`. Updates install code, so a downgraded
  /// transport is refused rather than tolerated.
  insecureUrl,
  checksumMismatch,
  sizeMismatch,
  cancelled,
  installPermissionMissing,
  installFailed,
  unsupportedPlatform,
}

class UpdateException implements Exception {
  const UpdateException(this.kind, [this.detail]);

  final UpdateFailureKind kind;

  /// Provider-supplied text kept for diagnosis (an HTTP status, the installer's
  /// own message). Shown beside the localized sentence, never instead of it.
  final String? detail;

  @override
  String toString() => detail == null
      ? 'UpdateException(${kind.name})'
      : 'UpdateException(${kind.name}: $detail)';
}

/// A release newer than the installed build, with everything needed to fetch it.
class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.downloadUri,
    this.sizeBytes,
    this.sha256,
    this.notes = '',
    this.publishedAt,
    this.assetName,
  });

  final AppVersion version;

  /// Where the APK is fetched from. For GitHub this is the asset API URL, which
  /// works for a private repository and a public one alike.
  final Uri downloadUri;
  final int? sizeBytes;

  /// Lowercase hex SHA-256 of the APK when the source published one.
  final String? sha256;
  final String notes;
  final DateTime? publishedAt;
  final String? assetName;
}
