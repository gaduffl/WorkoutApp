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
    final data = await _fetchDocuments(collection, accessToken, startDate: dateStr, endDate: dateStr);
    if (data == null || data.isEmpty) return null;
    return (data.last)['score'] as int?;
  }

  Future<_SleepDetail?> _fetchSleepDetail(String accessToken, String dateStr) async {
    // KNOWN-BUG FIX (HRV/RHR never prefilled): unlike the daily_* routes,
    // querying the sleep-periods route with start_date == end_date reliably
    // misses last night's period (the period spans midnight and Oura's range
    // filter on this route does not behave inclusively the way daily_* does).
    // Query a [date-1, date+1] window instead and pick the period whose
    // `day` is the target date.
    final target = DateTime.parse(dateStr);
    final data = await _fetchDocuments(
      'sleep',
      accessToken,
      startDate: _isoDate(target.subtract(const Duration(days: 1))),
      endDate: _isoDate(target.add(const Duration(days: 1))),
    );
    if (data == null || data.isEmpty) return null;
    final forDay = data.where((d) => d['day'] == dateStr).toList();
    final pool = forDay.isNotEmpty ? forDay : data;
    // A day can have multiple sleep periods (naps): prefer the main
    // long_sleep period, otherwise the longest one.
    final longSleeps = pool.where((d) => d['type'] == 'long_sleep').toList();
    final candidates = longSleeps.isNotEmpty ? longSleeps : pool;
    final main = candidates.reduce(
      (a, b) => ((a['total_sleep_duration'] as num?) ?? 0).compareTo((b['total_sleep_duration'] as num?) ?? 0) >= 0 ? a : b,
    );
    final hrv = (main['average_hrv'] as num?)?.toDouble();
    final rhr = (main['lowest_heart_rate'] as num?)?.toDouble();
    if (hrv == null && rhr == null) return null;
    return _SleepDetail(hrv, rhr);
  }

  /// §10: ranged pull ("cache last 90 days locally for baseline math").
  /// One paginated request per collection instead of 3 x N daily calls.
  Future<List<RecoverySnapshot>> fetchRecoveryRange({
    required String accessToken,
    required DateTime start,
    required DateTime end,
  }) async {
    final startStr = _isoDate(start.subtract(const Duration(days: 1)));
    final endStr = _isoDate(end.add(const Duration(days: 1)));
    final sleepPeriods = await _fetchDocuments('sleep', accessToken, startDate: startStr, endDate: endStr) ?? const [];
    final dailySleep = await _fetchDocuments('daily_sleep', accessToken, startDate: _isoDate(start), endDate: _isoDate(end)) ?? const [];
    final dailyReadiness =
        await _fetchDocuments('daily_readiness', accessToken, startDate: _isoDate(start), endDate: _isoDate(end)) ?? const [];

    final byDay = <String, _MutableSnapshot>{};
    _MutableSnapshot ensure(String day) => byDay.putIfAbsent(day, () => _MutableSnapshot(day));

    for (final p in sleepPeriods) {
      final day = p['day'] as String?;
      if (day == null) continue;
      final s = ensure(day);
      final dur = (p['total_sleep_duration'] as num?) ?? 0;
      final isLong = p['type'] == 'long_sleep';
      if (s.bestDuration == null || isLong && !s.bestIsLong || (isLong == s.bestIsLong && dur > s.bestDuration!)) {
        final hrv = (p['average_hrv'] as num?)?.toDouble();
        final rhr = (p['lowest_heart_rate'] as num?)?.toDouble();
        if (hrv != null || rhr != null) {
          s.hrv = hrv ?? s.hrv;
          s.rhr = rhr ?? s.rhr;
          s.bestDuration = dur;
          s.bestIsLong = isLong;
        }
      }
    }
    for (final d in dailySleep) {
      final day = d['day'] as String?;
      if (day != null) ensure(day).sleepScore = (d['score'] as num?)?.toInt();
    }
    for (final d in dailyReadiness) {
      final day = d['day'] as String?;
      if (day != null) ensure(day).readiness = (d['score'] as num?)?.toInt();
    }

    final out = <RecoverySnapshot>[];
    for (final s in byDay.values) {
      final date = DateTime.parse(s.day);
      if (date.isBefore(start) || date.isAfter(end)) continue;
      out.add(RecoverySnapshot(
        date: DateTime(date.year, date.month, date.day),
        hrvRmssd: s.hrv,
        restingHr: s.rhr,
        sleepScore: s.sleepScore,
        ouraReadinessScore: s.readiness,
        manualEntry: false,
      ));
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  Future<List<Map<String, dynamic>>?> _fetchDocuments(
    String collection,
    String accessToken, {
    required String startDate,
    required String endDate,
  }) async {
    final all = <Map<String, dynamic>>[];
    String? nextToken;
    do {
      final params = {'start_date': startDate, 'end_date': endDate, if (nextToken != null) 'next_token': nextToken};
      final uri = Uri.parse('$apiBase/$collection').replace(queryParameters: params);
      final response = await http.get(uri, headers: {'Authorization': 'Bearer $accessToken'});
      if (response.statusCode != 200) return all.isEmpty ? null : all;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final data = body['data'] as List?;
      if (data != null) all.addAll(data.cast<Map<String, dynamic>>());
      nextToken = body['next_token'] as String?;
    } while (nextToken != null);
    return all;
  }

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _SleepDetail {
  final double? hrv;
  final double? lowestHr;

  const _SleepDetail(this.hrv, this.lowestHr);
}

class _MutableSnapshot {
  final String day;
  double? hrv;
  double? rhr;
  int? sleepScore;
  int? readiness;
  num? bestDuration;
  bool bestIsLong = false;

  _MutableSnapshot(this.day);
}
