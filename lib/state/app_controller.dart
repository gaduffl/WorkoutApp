import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/repository.dart';
import '../engine/decision_engine.dart';
import '../engine/pain_engine.dart';
import '../engine/progression_engine.dart';
import '../engine/queue_engine.dart';
import '../integrations/oura_client.dart';
import '../models/check_in.dart';
import '../models/decision_trace.dart';
import '../models/exercise_state.dart';
import '../models/floor_category.dart';
import '../models/pain.dart';
import '../models/plan.dart';
import '../models/recovery_snapshot.dart';
import '../models/session_log.dart';
import '../models/session_type.dart';
import '../models/set_log.dart';
import '../models/user_settings.dart';

/// Ties the pure engine + persistence layer to the UI. All decision logic
/// stays in `engine/`; this only orchestrates load/save around it.
class AppController extends ChangeNotifier {
  final Repository repo;

  UserSettings settings = const UserSettings();
  QueueState queueState = const QueueState();
  Map<String, ExerciseState> exerciseStates = {};
  DecisionTrace? todayTrace;
  bool loading = true;

  /// Snapshot of [exerciseStates] taken right before the first check-in
  /// submission of the day, so [resetToday] can undo the pain-lifecycle
  /// bookkeeping a mistaken check-in already wrote (e.g. a typo'd RHR).
  Map<String, ExerciseState>? _preCheckInSnapshot;

  static const _oura = OuraClient();
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  String? _oauthState;

  /// Set after a failed connect/refresh attempt so the UI can surface it;
  /// cleared on the next successful attempt.
  String? ouraError;

  AppController(this.repo);

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Future<void> init() async {
    settings = await repo.loadSettings();
    queueState = await repo.loadQueueState();
    exerciseStates = await repo.loadExerciseStates();
    todayTrace = await repo.loadDecisionTraceForDate(today());
    loading = false;
    notifyListeners();

    _linkSub = _appLinks.uriLinkStream.listen(_handleIncomingLink, onError: (_) {});
    final initialLink = await _appLinks.getInitialLink();
    if (initialLink != null) await _handleIncomingLink(initialLink);
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  Future<void> _handleIncomingLink(Uri uri) async {
    if (uri.scheme != 'morningcoach' || uri.host != 'oauth-callback') return;
    final code = uri.queryParameters['code'];
    final state = uri.queryParameters['state'];
    if (code == null || _oauthState == null || state != _oauthState) return;
    _oauthState = null;
    await _completeOuraConnection(code);
  }

  /// Opens the system browser to Oura's OAuth2 consent screen. The redirect
  /// back to `morningcoach://oauth-callback` is caught by [_handleIncomingLink].
  Future<bool> startOuraConnect() async {
    final oura = settings.oura;
    if (!oura.isConfigured) return false;
    _oauthState = _randomState();
    final url = _oura.buildAuthorizationUrl(clientId: oura.clientId!, state: _oauthState!);
    return launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _completeOuraConnection(String code) async {
    final oura = settings.oura;
    if (!oura.isConfigured) return;
    try {
      final tokens = await _oura.exchangeCode(clientId: oura.clientId!, clientSecret: oura.clientSecret!, code: code);
      ouraError = null;
      settings = settings.copyWith(
        oura: oura.copyWith(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          accessTokenExpiresAt: tokens.expiresAt,
        ),
      );
      await repo.saveSettings(settings);
    } catch (e) {
      ouraError = 'Could not connect to Oura: $e';
    }
    notifyListeners();
  }

  Future<void> disconnectOura() async {
    settings = settings.copyWith(oura: settings.oura.copyWith(clearTokens: true));
    ouraError = null;
    await repo.saveSettings(settings);
    notifyListeners();
  }

  /// §10: pulls last night's HRV/RHR/sleep/readiness for [date], refreshing
  /// the access token first if it's expired. Returns null (silent
  /// fallback to manual entry) if not connected or the request fails.
  /// Also opportunistically backfills the trailing 90-day snapshot cache
  /// once per day so the §4.1 baselines have data to work with.
  Future<RecoverySnapshot?> fetchOuraRecovery(DateTime date) async {
    final token = await _validOuraAccessToken();
    if (token == null) return null;

    // Fire-and-forget: baseline math needs history (§10 "cache last 90
    // days"), but the morning check-in must not wait on it.
    unawaited(_backfillOuraHistory(token, date));

    try {
      return await _oura.fetchRecoveryForDate(accessToken: token, date: date);
    } catch (_) {
      return null; // §10 failure behavior: silent fallback to manual entry.
    }
  }

  Future<String?> _validOuraAccessToken() async {
    var oura = settings.oura;
    if (!oura.isConnected) return null;

    if (oura.isExpired) {
      if (oura.refreshToken == null || !oura.isConfigured) return null;
      try {
        final tokens = await _oura.refreshAccessToken(
          clientId: oura.clientId!,
          clientSecret: oura.clientSecret!,
          refreshToken: oura.refreshToken!,
        );
        oura = oura.copyWith(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          accessTokenExpiresAt: tokens.expiresAt,
        );
        settings = settings.copyWith(oura: oura);
        await repo.saveSettings(settings);
        ouraError = null;
        notifyListeners();
      } catch (e) {
        ouraError = 'Oura session expired and could not refresh: $e';
        notifyListeners();
        return null;
      }
    }
    return oura.accessToken;
  }

  DateTime? _lastOuraBackfillDate;

  /// Pulls the trailing 90 days of HRV/RHR/sleep into the local snapshot
  /// cache (skipping days the user entered manually). At most once per day.
  Future<void> _backfillOuraHistory(String accessToken, DateTime asOf) async {
    if (_lastOuraBackfillDate != null && _isSameDate(_lastOuraBackfillDate!, asOf)) return;
    _lastOuraBackfillDate = asOf;
    try {
      final start = asOf.subtract(const Duration(days: 90));
      final fetched = await _oura.fetchRecoveryRange(accessToken: accessToken, start: start, end: asOf);
      final existing = await repo.loadRecoverySnapshotsSince(start);
      final manualDays = existing.where((s) => s.manualEntry).map((s) => _dayKey(s.date)).toSet();
      final cachedDays = existing.map((s) => _dayKey(s.date)).toSet();
      for (final snap in fetched) {
        final key = _dayKey(snap.date);
        if (manualDays.contains(key)) continue; // manual entry wins (§3.3)
        if (cachedDays.contains(key) && _isSameDate(snap.date, asOf)) continue; // today flows through check-in
        await repo.saveRecoverySnapshot(snap);
      }
    } catch (_) {
      _lastOuraBackfillDate = null; // retry on the next open
    }
  }

  String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  String _randomState() {
    final rand = Random.secure();
    return List.generate(16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> saveSettings(UserSettings newSettings) async {
    settings = newSettings;
    await repo.saveSettings(settings);
    notifyListeners();
  }

  Future<DecisionTrace> submitCheckIn({
    required int timeMinutes,
    required int subjective,
    List<PainFlag> pain = const [],
    RecoverySnapshot? recovery,
  }) async {
    final now = today();
    _preCheckInSnapshot ??= Map.of(exerciseStates);
    final checkin = CheckIn(
      date: now,
      timeMinutes: timeMinutes,
      subjective: subjective,
      pain: pain,
      timestamp: DateTime.now(),
    );
    await repo.saveCheckIn(checkin);
    if (recovery != null) await repo.saveRecoverySnapshot(recovery);
    return _recomputeAndPersist(checkin: checkin, todaySnapshot: recovery);
  }

  /// §11 "swap session": re-runs today's decision with [sessionId] forced
  /// as the chosen candidate instead of the natural winner. Reuses the
  /// check-in/recovery already on file for today - only which session gets
  /// recommended changes, not the underlying readiness inputs.
  Future<DecisionTrace> swapToSession(SessionTypeId sessionId) async {
    final current = todayTrace;
    if (current == null) throw StateError('No check-in submitted today yet.');
    final now = today();
    final todaySnapshots =
        (await repo.loadRecoverySnapshotsSince(now)).where((s) => _isSameDate(s.date, now)).toList();
    return _recomputeAndPersist(
      checkin: current.checkin,
      todaySnapshot: todaySnapshots.isEmpty ? null : todaySnapshots.first,
      forcedSessionId: sessionId,
    );
  }

  Future<DecisionTrace> _recomputeAndPersist({
    required CheckIn checkin,
    required RecoverySnapshot? todaySnapshot,
    SessionTypeId? forcedSessionId,
  }) async {
    final now = today();
    final historyStart = now.subtract(const Duration(days: 60));
    final recoveryHistory = await repo.loadRecoverySnapshotsSince(historyStart);
    final checkinHistory = await repo.loadCheckInsSince(historyStart);
    final sessionLogs = await repo.loadSessionLogsSince(now.subtract(const Duration(days: 10)));

    final input = DecisionEngineInput(
      checkin: checkin,
      todaySnapshot: todaySnapshot,
      recoveryHistory: recoveryHistory,
      checkinHistory: checkinHistory,
      sessionLogs: sessionLogs,
      exerciseStates: exerciseStates,
      queueState: queueState,
      settings: settings,
      today: now,
      forcedSessionId: forcedSessionId,
    );
    final output = const DecisionEngine().decide(input);

    exerciseStates = output.patchedExerciseStates;
    await repo.saveExerciseStates(exerciseStates);
    await repo.saveDecisionTrace(output.trace);
    todayTrace = output.trace;
    notifyListeners();
    return output.trace;
  }

  bool _isSameDate(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// Discards today's check-in/recovery entry and recommendation so the
  /// user can redo the morning check-in (e.g. after a typo). If no session
  /// has been logged yet today, this also undoes the pain-lifecycle
  /// bookkeeping the mistaken check-in wrote. Once a session is logged,
  /// that workout data is never touched - only the check-in is cleared.
  Future<void> resetToday() async {
    final now = today();
    final loggedToday = (await repo.loadSessionLogsSince(now))
        .any((l) => l.date.year == now.year && l.date.month == now.month && l.date.day == now.day);

    if (!loggedToday && _preCheckInSnapshot != null) {
      exerciseStates = _preCheckInSnapshot!;
      await repo.saveExerciseStates(exerciseStates);
    }
    _preCheckInSnapshot = null;

    await repo.deleteCheckIn(now);
    await repo.deleteRecoverySnapshot(now);
    await repo.deleteDecisionTrace(now);
    todayTrace = null;
    notifyListeners();
  }

  Future<void> completeSession(
    SessionPlan plan,
    List<SetLog> loggedSets, {
    required int durationMinutes,
    bool rehitFinisherCompleted = false,
  }) async {
    const progression = ProgressionEngine();
    final now = today();

    final byTrack = <String, List<SetLog>>{};
    for (final s in loggedSets) {
      if (s.isWarmup) continue;
      byTrack.putIfAbsent(s.trackKey, () => []).add(s);
    }

    // Pain-flag lifecycle at completion (§7.2): a pain-free session decays a
    // mild flag; a pain-free graded re-entry test passes and resumes the
    // pattern per §6.6 precedence. Runs BEFORE progression evaluation so the
    // resume still sees the real untrained gap (evaluateSession stamps
    // lastTrainedDate = today).
    for (final entry in byTrack.entries) {
      final state = exerciseStates[entry.key];
      if (state == null || !state.painFrozen) continue;
      final ranPainFree = entry.value.every((s) => !s.painFlag);
      if (state.painReentryTestOffered && !state.painReentryTestPassed) {
        if (ranPainFree) {
          exerciseStates[entry.key] =
              progression.resolvePostReentryResume(state, now, settings.equipment);
        }
        continue;
      }
      exerciseStates[entry.key] = painEngine.advanceFlagState(
        state,
        activeFlag: null,
        patternScheduledToday: false,
        sessionRanPainFree: ranPainFree,
      );
    }

    // §6.6: a completed detraining re-entry session makes the ramp load the
    // new working load — otherwise tomorrow snaps back to the pre-break load.
    for (final e in plan.exercises) {
      if (!e.persistLoadOnCompletion || e.loadTotal == null) continue;
      final state = exerciseStates[e.trackKey];
      if (state == null || !byTrack.containsKey(e.trackKey)) continue;
      final next = state.clone()..currentLoad = e.loadTotal!;
      exerciseStates[e.trackKey] = next;
    }

    for (final entry in byTrack.entries) {
      final state = exerciseStates[entry.key];
      if (state == null) continue;
      exerciseStates[entry.key] = progression.evaluateSession(
        state,
        entry.value,
        equipmentConfig: settings.equipment,
        sessionDate: now,
      );
    }
    await repo.saveExerciseStates(exerciseStates);

    final def = sessionTypes[plan.sessionId]!;
    final countsAs = <FloorCategory>{};
    if (def.countsAs.contains(FloorCategory.strength)) countsAs.add(FloorCategory.strength);
    if (plan.sessionId == SessionTypeId.s2) {
      if (rehitFinisherCompleted) countsAs.add(FloorCategory.intensity);
    } else if (def.countsAs.contains(FloorCategory.intensity)) {
      countsAs.add(FloorCategory.intensity);
    }
    if (def.countsAs.contains(FloorCategory.aerobic)) countsAs.add(FloorCategory.aerobic);

    final log = SessionLog(
      id: '${now.toIso8601String()}-${plan.sessionId.name}-${DateTime.now().microsecondsSinceEpoch}',
      templateId: plan.sessionId,
      tier: plan.tier,
      date: now,
      setLogs: loggedSets,
      plannedWorkSets: plan.plannedWorkSets,
      completedWorkSets: loggedSets.where((s) => !s.isWarmup).length,
      durationMinutes: durationMinutes,
      countsAs: countsAs,
      rehitFinisherCompleted: rehitFinisherCompleted,
    );
    await repo.saveSessionLog(log);

    if (log.countsTowardQueueAndFloor && plan.grantsQueueCredit) {
      queueState = const QueueEngine().advance(queueState, plan.sessionId);
      await repo.saveQueueState(queueState);
    }
    notifyListeners();
  }

  /// Marks a pain re-entry test (§7.2, 50% x 8) as passed pain-free, then
  /// resumes the pattern per §6.6's precedence rule.
  Future<void> markPainReentryTestPassed(String trackKey) async {
    final state = exerciseStates[trackKey];
    if (state == null) return;
    final next = const ProgressionEngine().resolvePostReentryResume(state, today(), settings.equipment);
    exerciseStates[trackKey] = next;
    await repo.saveExerciseState(next);
    notifyListeners();
  }

  Future<void> triggerManualDeload() async {
    exerciseStates = {
      for (final e in const ProgressionEngine().forceGlobalDeload(exerciseStates.values.toList())) e.trackKey: e,
    };
    await repo.saveExerciseStates(exerciseStates);
    notifyListeners();
  }

  static const painEngine = PainEngine();
}
