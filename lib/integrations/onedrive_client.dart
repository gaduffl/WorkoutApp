import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class OneDriveTokens {
  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  const OneDriveTokens({required this.accessToken, this.refreshToken, required this.expiresAt});
}

/// PKCE code verifier + its S256 challenge (RFC 7636).
class PkcePair {
  final String verifier;
  final String challenge;
  const PkcePair(this.verifier, this.challenge);

  static PkcePair generate() {
    final rand = Random.secure();
    final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
    final verifier = _b64url(bytes);
    final challenge = _b64url(sha256.convert(utf8.encode(verifier)).bytes);
    return PkcePair(verifier, challenge);
  }

  static String _b64url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', ''); // base64url without padding
}

/// Microsoft Graph OneDrive client for the app-data-folder backup blob.
/// Public-client OAuth2 Authorization Code + PKCE — no client secret.
///
/// Entra app registration: "Mobile and desktop applications" platform with
/// the custom redirect URI below, delegated Graph permissions
/// `Files.ReadWrite.AppFolder offline_access User.Read`.
class OneDriveClient {
  const OneDriveClient();

  static const clientId = '29d50c5e-c912-4a00-8de0-99c0f8e8c44d';
  static const redirectUri = 'morningcoach://onedrive-callback';
  static const authorizationEndpoint = 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
  static const tokenEndpoint = 'https://login.microsoftonline.com/common/oauth2/v2.0/token';
  static const graphBase = 'https://graph.microsoft.com/v1.0';

  /// approot = the app's own dedicated folder (Files.ReadWrite.AppFolder).
  static const backupPath = '/me/drive/special/approot:/morningcoach-backup.json';

  static const scopes = 'Files.ReadWrite.AppFolder offline_access User.Read';

  Uri buildAuthorizationUrl({required String state, required String codeChallenge}) {
    return Uri.parse(authorizationEndpoint).replace(queryParameters: {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'response_mode': 'query',
      'scope': scopes,
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    });
  }

  Future<OneDriveTokens> exchangeCode({required String code, required String codeVerifier}) {
    return _tokenRequest({
      'client_id': clientId,
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': codeVerifier,
      'scope': scopes,
    });
  }

  Future<OneDriveTokens> refreshAccessToken({required String refreshToken}) {
    return _tokenRequest({
      'client_id': clientId,
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'redirect_uri': redirectUri,
      'scope': scopes,
    });
  }

  Future<OneDriveTokens> _tokenRequest(Map<String, String> body) async {
    final res = await http.post(
      Uri.parse(tokenEndpoint),
      headers: const {'content-type': 'application/x-www-form-urlencoded'},
      body: body,
    );
    if (res.statusCode != 200) {
      throw Exception('OneDrive token request failed (${res.statusCode}): ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    return OneDriveTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn - 60)), // refresh 1 min early
    );
  }

  /// Signed-in account email/UPN, for display. Null on any failure.
  Future<String?> fetchAccount(String accessToken) async {
    try {
      final res = await http.get(
        Uri.parse('$graphBase/me'),
        headers: {'authorization': 'Bearer $accessToken'},
      );
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      return (j['userPrincipalName'] ?? j['mail']) as String?;
    } catch (_) {
      return null;
    }
  }

  /// Uploads the backup blob (replaces any existing one).
  Future<void> uploadBackup(String accessToken, String jsonContent) async {
    final res = await http.put(
      Uri.parse('$graphBase$backupPath:/content'),
      headers: {'authorization': 'Bearer $accessToken', 'content-type': 'application/json'},
      body: utf8.encode(jsonContent),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('OneDrive upload failed (${res.statusCode}): ${res.body}');
    }
  }

  /// Downloads the backup blob, or null if none exists yet (404).
  Future<String?> downloadBackup(String accessToken) async {
    final res = await http.get(
      Uri.parse('$graphBase$backupPath:/content'),
      headers: {'authorization': 'Bearer $accessToken'},
    );
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw Exception('OneDrive download failed (${res.statusCode}): ${res.body}');
    }
    return utf8.decode(res.bodyBytes);
  }
}
