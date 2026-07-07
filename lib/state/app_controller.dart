import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/repository.dart';
import '../engine/decision_engine.dart';
import '../engine/pain_engine.dart';
import '../engine/progression_engine.dart';
import '../engine/queue_engine.dart';
import '../integrations/onedrive_client.dart';
import '../integrations/oura_client.dart';
import '../notifications/notification_service.dart';
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

  /// Sessions logged in the trailing 3 days, so the UI can reflect what's
  /// already done today and whether a second-session REHIT is worth offering.
  List<SessionLog> _recentLogs = [];

  List<SessionLog> get _todaysLogs =>
      _recentLogs.where((l) => _isSameDate(l.date, today())).toList();

  /// Whether a counted session has been logged today (Home/Today "done" state).
  bool get sessionDoneToday => _todaysLogs.any((l) => l.countsTowardQueueAndFloor);

  bool _hasCategoryToday(FloorCategory c) =>
      _todaysLogs.any((l) => l.countsAs.contains(c) && l.countsTowardQueueAndFloor);
  bool get strengthDoneToday => _hasCategoryToday(FloorCategory.strength);

  bool get _intensityIn48h => _recentLogs.any((l) =>
      l.countsAs.contains(FloorCategory.intensity) &&
      l.countsTowardQueueAndFloor &&
      today().difference(l.date).inDays <= 2);

  /// §2.1/§12: after a strength session, offer an 8-min REHIT to cover
  /// intensity if none happened in the trailing 48 h.
  bool get canOfferSecondRehit => strengthDoneToday && !_intensityIn48h;

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
    await _reloadAll();
    unawaited(syncNotifications());
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
    if (uri.scheme != 'morningcoach') return;
    if (uri.host == 'oauth-callback') {
      final code = uri.queryParameters['code'];
      final state = uri.queryParameters['state'];
      if (code == null || _oauthState == null || state != _oauthState) return;
      _oauthState = null;
      await _completeOuraConnection(code);
    } else if (uri.host == 'onedrive-callback') {
      final code = uri.queryParameters['code'];
      final state = uri.queryParameters['state'];
      if (code == null || _odState == null || state != _odState) return;
      _odState = null;
      await _completeOneDriveConnection(code);
    }
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

  // ---- OneDrive backup / sync ----

  static const _onedrive = OneDriveClient();
  PkcePair? _odPkce;
  String? _odState;

  /// Surfaced to the UI after a failed OneDrive operation; cleared on success.
  String? oneDriveError;

  /// Opens the browser to Microsoft's consent screen (PKCE, no secret). The
  /// redirect to `morningcoach://onedrive-callback` is caught by [_handleIncomingLink].
  Future<bool> startOneDriveConnect() async {
    _odPkce = PkcePair.generate();
    _odState = _randomState();
    final url = _onedrive.buildAuthorizationUrl(state: _odState!, codeChallenge: _odPkce!.challenge);
    return launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _completeOneDriveConnection(String code) async {
    final verifier = _odPkce?.verifier;
    _odPkce = null;
    if (verifier == null) return;
    try {
      final tokens = await _onedrive.exchangeCode(code: code, codeVerifier: verifier);
      final account = await _onedrive.fetchAccount(tokens.accessToken);
      oneDriveError = null;
      settings = settings.copyWith(
        oneDrive: settings.oneDrive.copyWith(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          accessTokenExpiresAt: tokens.expiresAt,
          account: account,
        ),
      );
      await repo.saveSettings(settings);
    } catch (e) {
      oneDriveError = 'Could not connect to OneDrive: $e';
    }
    notifyListeners();
  }

  Future<void> disconnectOneDrive() async {
    settings = settings.copyWith(oneDrive: settings.oneDrive.copyWith(clearTokens: true));
    oneDriveError = null;
    await repo.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setOneDriveAutoBackup(bool on) async {
    settings = settings.copyWith(oneDrive: settings.oneDrive.copyWith(autoBackup: on));
    await repo.saveSettings(settings);
    notifyListeners();
  }

  /// Refreshes the OneDrive access token if expired. Returns null on failure.
  Future<String?> _validOneDriveToken() async {
    var od = settings.oneDrive;
    if (!od.isConnected) return null;
    if (od.isExpired) {
      if (od.refreshToken == null) return null;
      final tokens = await _onedrive.refreshAccessToken(refreshToken: od.refreshToken!);
      od = od.copyWith(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        accessTokenExpiresAt: tokens.expiresAt,
      );
      settings = settings.copyWith(oneDrive: od);
      await repo.saveSettings(settings);
    }
    return settings.oneDrive.accessToken;
  }

  /// Uploads the full local database to the OneDrive app folder. Throws on
  /// failure (the UI surfaces it); [silent] swallows errors for auto-backup.
  Future<void> backupToOneDrive({bool silent = false}) async {
    try {
      final token = await _validOneDriveToken();
      if (token == null) throw Exception('OneDrive is not connected');
      final envelope = {
        'app': 'morningcoach',
        'schema': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'data': await repo.db.exportAll(),
      };
      await _onedrive.uploadBackup(token, jsonEncode(envelope));
      oneDriveError = null;
      settings = settings.copyWith(oneDrive: settings.oneDrive.copyWith(lastBackupAt: DateTime.now()));
      await repo.saveSettings(settings);
      notifyListeners();
    } catch (e) {
      oneDriveError = 'Backup failed: $e';
      notifyListeners();
      if (!silent) rethrow;
    }
  }

  /// Downloads the OneDrive backup and replaces the local database with it,
  /// preserving this device's OneDrive connection so it stays signed in.
  /// Returns false if no backup exists yet.
  Future<bool> restoreFromOneDrive() async {
    final token = await _validOneDriveToken();
    if (token == null) throw Exception('OneDrive is not connected');
    final content = await _onedrive.downloadBackup(token);
    if (content == null) return false;
    final envelope = jsonDecode(content) as Map<String, dynamic>;
    final data = envelope['data'];
    if (data is! Map<String, dynamic>) throw Exception('Backup file is not readable');

    final keepConnection = settings.oneDrive; // don't sign out on restore
    await repo.db.importAll(data);
    await _reloadAll();
    // Re-apply this device's tokens on top of whatever the backup carried.
    settings = settings.copyWith(oneDrive: keepConnection);
    await repo.saveSettings(settings);
    notifyListeners();
    return true;
  }

  /// Reloads all in-memory state from the database (used at startup and
  /// after a OneDrive restore).
  Future<void> _reloadAll() async {
    settings = await repo.loadSettings();
    queueState = await repo.loadQueueState();
    exerciseStates = await repo.loadExerciseStates();
    todayTrace = await repo.loadDecisionTraceForDate(today());
    _recentLogs = await repo.loadSessionLogsSince(today().subtract(const Duration(days: 3)));
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
    unawaited(syncNotifications());
    notifyListeners();
  }

  /// §3.1 + §12: (re)schedule the wake-window nudge and cutoff reminder.
  /// Best-effort - never blocks or throws.
  Future<void> syncNotifications() {
    return NotificationService.sync(
      enabled: settings.notificationsEnabled,
      wakeWindow: settings.wakeWindow,
      cutoffHour: settings.checkInCutoffHour,
      checkedInToday: todayTrace != null,
    );
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
    unawaited(syncNotifications()); // check-in done -> today's cutoff nudge moves to tomorrow
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

    // §12 travel mode: bodyweight variants keep the pattern "trained"
    // (so §6.6 detraining doesn't misfire on return) but never advance
    // the load-based state machine.
    final travelKeys = plan.exercises.where((e) => e.isTravel).map((e) => e.trackKey).toSet();

    for (final entry in byTrack.entries) {
      final state = exerciseStates[entry.key];
      if (state == null) continue;
      if (travelKeys.contains(entry.key)) {
        exerciseStates[entry.key] = state.clone()..lastTrainedDate = now;
        continue;
      }
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
    _recentLogs = [..._recentLogs, log];

    if (log.countsTowardQueueAndFloor && plan.grantsQueueCredit) {
      queueState = const QueueEngine().advance(queueState, plan.sessionId);
      await repo.saveQueueState(queueState);
    }
    notifyListeners();

    // Auto-backup after a logged session, if enabled (best-effort).
    if (settings.oneDrive.autoBackup && settings.oneDrive.isConnected) {
      unawaited(backupToOneDrive(silent: true));
    }
  }

  /// Logs a cardio-only session (S3 4×4, S6 Zone 2, S7 REHIT) that has no
  /// per-set logging — either the day's primary cardio pick or an added
  /// second-session REHIT. Reuses [completeSession] with an empty set list
  /// (plannedWorkSets == 0 → completionRatio 1.0 → counts & credits).
  Future<void> logCardioSession(SessionTypeId id, {required int durationMinutes}) async {
    final def = sessionTypes[id];
    if (def == null) return;
    final plan = SessionPlan(
      sessionId: id,
      sessionName: def.name,
      tier: SessionTier.full,
      exercises: const [],
      estimatedDurationMin: durationMinutes,
      // A second-session REHIT must not move the cycle pointer; S7 isn't a
      // cycle type so advance() is already a no-op, but be explicit.
      grantsQueueCredit: cycleOrder.contains(id),
    );
    await completeSession(plan, const [], durationMinutes: durationMinutes);
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
