/// OneDrive backup/sync connection. Single fixed public-client app
/// registration (Microsoft Entra), authenticated via the OAuth2
/// Authorization Code + PKCE flow — no client secret is stored on device.
/// Redirect URI: `morningcoach://onedrive-callback`.
class OneDriveConnection {
  final String? accessToken;
  final String? refreshToken;
  final DateTime? accessTokenExpiresAt;

  /// Signed-in account (userPrincipalName / email), for display only.
  final String? account;

  /// Local time of the last successful backup upload.
  final DateTime? lastBackupAt;

  /// Auto-upload a backup after each completed session.
  final bool autoBackup;

  const OneDriveConnection({
    this.accessToken,
    this.refreshToken,
    this.accessTokenExpiresAt,
    this.account,
    this.lastBackupAt,
    this.autoBackup = false,
  });

  bool get isConnected => accessToken?.isNotEmpty ?? false;

  bool get isExpired =>
      accessTokenExpiresAt == null || !DateTime.now().isBefore(accessTokenExpiresAt!);

  OneDriveConnection copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
    String? account,
    DateTime? lastBackupAt,
    bool? autoBackup,
    bool clearTokens = false,
  }) {
    if (clearTokens) {
      return OneDriveConnection(autoBackup: autoBackup ?? this.autoBackup);
    }
    return OneDriveConnection(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
      account: account ?? this.account,
      lastBackupAt: lastBackupAt ?? this.lastBackupAt,
      autoBackup: autoBackup ?? this.autoBackup,
    );
  }
}
