import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/recovery_snapshot.dart';

class OuraTokens {
  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  const OuraTokens({required this.accessToken, this.refreshToken, required this.expiresAt});
}

/// §10 Oura integration. Personal access tokens were deprecated by Oura in
/// December 2025 - OAuth2 Authorization Code is now the only supported
/// auth path (see docs/Oura-openapi-1.35.json, `info.description`).
///
/// Redirect URI registered with the user's Oura API Application must match
/// [redirectUri] exactly: `morningcoach://oauth-callback`.
class OuraClient {
  const OuraClient();

  static const redirectUri = 'morningcoach://oauth-callback';
  static const authorizationEndpoint = 'https://cloud.ouraring.com/oauth/authorize';
  static const tokenEndpoint = 'https://api.ouraring.com/oauth/token';
  static const apiBase = 'https://api.ouraring.com/v2/usercollection';

  /// `daily`: daily_readiness/daily_sleep scores. `heartrate` covers the
  /// nightly HRV/RHR series read from the `sleep` collection.
  static const scopes = 'daily heartrate';

  Uri buildAuthorizationUrl({required String clientId, required String state}) {
    return Uri.parse(authorizationEndpoint).replace(queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scopes,
      'state': state,
    });
  }

  Future<OuraTokens> exchangeCode({
    required String clientId,
    required String clientSecret,
    required String code,
  }) {
    return _tokenRequest({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'client_id': clientId,
      'client_secret': clientSecret,
    });
  }

  Future<OuraTokens> refreshAccessToken({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
  }) {
    return _tokenRequest({
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      'client_secret': clientSecret,
    });
  }

  Future<OuraTokens> _tokenRequest(Map<String, String> body) async {
    final response = await http.post(
      Uri.parse(tokenEndpoint),
      headers: const {'content-type': 'application/x-www-form-urlencoded'},
      body: body,
    );
    if (response.statusCode != 200) {
      throw Exception('Oura token request failed (${response.statusCode}): ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 86400;
    return OuraTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }

  /// §10 endpoints: daily_readiness, daily_sleep, sleep (nightly average
  /// rMSSD + lowest RHR). Returns null if nothing came back for that date
  /// (caller falls back to manual entry per §10's failure behavior).
  Future<RecoverySnapshot?> fetchRecoveryForDate({
    required String accessToken,
    required DateTime date,
  }) async {
    final dateStr = _isoDate(date);
    final readiness = await _fetchScore('daily_readiness', accessToken, dateStr);
    final sleepScore = await _fetchScore('daily_sleep', accessToken, dateStr);
    final sleepDetail = await _fetchSleepDetail(accessToken, dateStr);

    if (readiness == null && sleepScore == null && sleepDetail == null) return null;

    return RecoverySnapshot(
      date: DateTime(date.year, date.month, date.day),
      hrvRmssd: sleepDetail?.hrv,
      restingHr: sleepDetail?.lowestHr,
      sleepScore: sleepScore,
      ouraReadinessScore: readiness,
      manualEntry: false,
    );
  }

  Future<int?> _fetchScore(String collection, String accessToken, String dateStr) async {
    final data = await _fetchDocuments(collection, accessToken, dateStr);
    if (data == null || data.isEmpty) return null;
    return (data.last)['score'] as int?;
  }

  Future<_SleepDetail?> _fetchSleepDetail(String accessToken, String dateStr) async {
    final data = await _fetchDocuments('sleep', accessToken, dateStr);
    if (data == null || data.isEmpty) return null;
    // A day can have multiple sleep periods (naps); the longest one is the
    // best proxy for "last night's" main sleep.
    final main = data.reduce(
      (a, b) => ((a['total_sleep_duration'] as num?) ?? 0).compareTo((b['total_sleep_duration'] as num?) ?? 0) >= 0 ? a : b,
    );
    final hrv = (main['average_hrv'] as num?)?.toDouble();
    final rhr = (main['lowest_heart_rate'] as num?)?.toDouble();
    if (hrv == null && rhr == null) return null;
    return _SleepDetail(hrv, rhr);
  }

  Future<List<Map<String, dynamic>>?> _fetchDocuments(String collection, String accessToken, String dateStr) async {
    final uri = Uri.parse('$apiBase/$collection').replace(queryParameters: {'start_date': dateStr, 'end_date': dateStr});
    final response = await http.get(uri, headers: {'Authorization': 'Bearer $accessToken'});
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as List?;
    return data?.cast<Map<String, dynamic>>();
  }

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _SleepDetail {
  final double? hrv;
  final double? lowestHr;

  const _SleepDetail(this.hrv, this.lowestHr);
}
