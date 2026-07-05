/// §10 Oura integration - OAuth2 only. Personal access tokens were
/// deprecated by Oura in December 2025 (see docs/Oura-openapi-1.35.json),
/// so this app authenticates via the Authorization Code flow: the user
/// registers their own API Application at
/// https://cloud.ouraring.com/oauth/applications (redirect URI
/// `morningcoach://oauth-callback`) and enters its Client ID/Secret here.
class OuraConnection {
  final String? clientId;
  final String? clientSecret;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? accessTokenExpiresAt;

  const OuraConnection({
    this.clientId,
    this.clientSecret,
    this.accessToken,
    this.refreshToken,
    this.accessTokenExpiresAt,
  });

  bool get isConfigured =>
      (clientId?.isNotEmpty ?? false) && (clientSecret?.isNotEmpty ?? false);

  bool get isConnected => accessToken?.isNotEmpty ?? false;

  bool get isExpired =>
      accessTokenExpiresAt == null || !DateTime.now().isBefore(accessTokenExpiresAt!);

  OuraConnection copyWith({
    String? clientId,
    String? clientSecret,
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
    bool clearTokens = false,
  }) {
    if (clearTokens) {
      return OuraConnection(clientId: clientId ?? this.clientId, clientSecret: clientSecret ?? this.clientSecret);
    }
    return OuraConnection(
      clientId: clientId ?? this.clientId,
      clientSecret: clientSecret ?? this.clientSecret,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
    );
  }
}
