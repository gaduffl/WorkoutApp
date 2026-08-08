import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/repository.dart';
import '../engine/analytics_engine.dart';
import '../engine/cardio_engine.dart';
import '../engine/decision_engine.dart';
import '../engine/equipment_engine.dart';
import '../engine/intensity_recovery_policy.dart';
import '../engine/lower_back_recovery_engine.dart';
import '../engine/pain_engine.dart';
import '../engine/progression_engine.dart';
import '../engine/queue_engine.dart';
import '../engine/rehit_eligibility_engine.dart';
import '../engine/rest_day_rehit_engine.dart';
import '../engine/schedule_fit_engine.dart';
import '../engine/session_templates.dart';
import '../engine/stimulus_ledger_engine.dart';
import '../engine/training_status_engine.dart';
import '../integrations/onedrive_client.dart';
import '../integrations/oura_client.dart';
import '../notifications/notification_service.dart';
import '../models/analytics_event.dart';
import '../models/cardio_protocol.dart';
import '../models/check_in.dart';
import '../models/decision_trace.dart';
import '../models/exercise_metric.dart';
import '../models/exercise_state.dart';
import '../models/floor_category.dart';
import '../models/history_data.dart';
import '../models/ladders.dart';
import '../models/lower_back_recovery.dart';
import '../models/movement_pattern.dart';
import '../models/pain.dart';
import '../models/plan.dart';
import '../models/recovery_snapshot.dart';
import '../models/rule_key.dart';
import '../models/session_log.dart';
import '../models/session_timing.dart';
import '../models/session_type.dart';
import '../models/set_log.dart';
import '../models/training_targets.dart';
import '../models/training_status.dart';
import '../models/user_settings.dart';

/// Ties the pure engine + persistence layer to the UI. All decision logic
/// stays in `engine/`; this only orchestrates load/save around it.
class AppController extends ChangeNotifier {
  final Repository repo;

  static const _intensityRecoveryPolicy = IntensityRecoveryPolicy();
  static const _lowerBackRecoveryEngine = LowerBackRecoveryEngine();

  UserSettings settings = const UserSettings();
  QueueState queueState = const QueueState();
  Map<String, ExerciseState> exerciseStates = {};
  DecisionTrace? todayTrace;
  bool loading = true;

  /// Last load the user typed into the manual progression-override dialog,
  /// keyed by `<pattern>:<ladderIndex>`. Shown back as a reference only —
  /// never auto-applied (see [setPatternProgression]).
  Map<String, double> manualLoadEntries = {};

  /// Serializes session persistence so a rapid double action cannot append
  /// the same workout twice or advance the queue twice.
  bool _completionInFlight = false;
  bool _travelModeChangeInFlight = false;
  Future<void>? _notificationSyncTask;
  bool _notificationSyncQueued = false;
  bool get travelModeChanging => _travelModeChangeInFlight;

  LowerBackRecoveryState get lowerBackRecovery =>
      settings.lowerBackRecovery;

  bool get lowerBackMorningResponseDue {
    final sessionDate =
        settings.lowerBackRecovery.pendingNextMorningSessionDate;
    final sessionDay = sessionDate == null
        ? null
        : DateTime(sessionDate.year, sessionDate.month, sessionDate.day);
    return sessionDay != null && today().isAfter(sessionDay);
  }

  /// A restored trace or a manual deload can briefly predate the current
  /// Today plan. Recheck every hard gate at the action/UI boundary so an old
  /// S3/S7 prescription cannot bypass recovery, pain, deload, or travel.
  bool isHighIntensityUsableNow({DateTime? nowLocal}) {
    final observedAt = nowLocal ?? DateTime.now();
    final trace = todayTrace;
    final currentTrace = trace != null && _isSameDate(trace.date, observedAt)
        ? trace
        : null;
    if (currentTrace == null ||
        currentTrace.recovery.bucket != ReadinessBucket.green ||
        currentTrace.firedRules.any(
          (rule) => rule.key == RuleKey.illnessGuard,
        )) {
      return false;
    }
    final safety = _intensityRecoveryPolicy.evaluateHighIntensitySafety(
      logs: _recentLogs.where(
        (log) => !log.completedAt.isAfter(observedAt),
      ),
      asOf: observedAt,
      checkInPain: currentTrace.checkin.pain,
      exerciseStates: exerciseStates.values,
      travelMode: settings.travelMode,
    );
    return !safety.blocked;
  }

  bool isPlanUsableNow(SessionPlan? plan, {DateTime? nowLocal}) =>
      plan == null ||
      (plan.sessionId != SessionTypeId.s3 &&
          plan.sessionId != SessionTypeId.s7) ||
      isHighIntensityUsableNow(nowLocal: nowLocal);

  /// Loaded from whole local calendar days so the shared recovery policy can
  /// apply its precision-aware trailing-48-hour filter and the rolling
  /// seven-day high-intensity target.
  List<SessionLog> _recentLogs = [];

  /// A wider window than [_recentLogs], used only to learn *when* the user
  /// trains. Kept separate so no recovery, ledger, or queue decision silently
  /// changes shape by seeing more history than it was designed around.
  List<SessionLog> _scheduleLogs = [];

  /// Today's analytics events, so once-per-day observations are not written
  /// again on every notification sync or app resume.
  List<AnalyticsEvent> _todayEvents = [];

  @visibleForTesting
  void replaceRecentLogsForTesting(Iterable<SessionLog> logs) {
    _recentLogs = List<SessionLog>.unmodifiable(logs);
    _scheduleLogs = List<SessionLog>.unmodifiable(logs);
  }

  @visibleForTesting
  void replaceScheduleLogsForTesting(Iterable<SessionLog> logs) {
    _scheduleLogs = List<SessionLog>.unmodifiable(logs);
  }

  List<SessionLog> get _todaysLogs =>
      _recentLogs.where((l) => _isSameDate(l.date, today())).toList();

  /// Whether today's prescription was completed (Home/Today "done" state).
  /// Stimulus/category credit is tracked separately: a fully completed
  /// 20-minute S6 recovery prescription is done without becoming base work.
  bool get sessionDoneToday => _todaysLogs.any(
        (log) => !log.isSupplemental && log.completesTodaysPlan,
      );

  /// Any persisted primary work today, including a partial primary session.
  /// Supplemental work remains visible to dose/recovery logic without
  /// changing or locking the primary prescription.
  bool get sessionLoggedToday =>
      _todaysLogs.any((log) => !log.isSupplemental);

  static const _primaryPlanLockedMessage =
      'Today\'s primary prescription is locked after any workout attempt has been logged.';

  /// The in-memory list is authoritative after [init] and after every local
  /// completion. Re-read persistence as a fail-closed action-boundary check
  /// as well, so a stale controller (for example after route restoration)
  /// cannot create a second primary attempt.
  Future<bool> _hasPersistedWorkoutToday() async {
    final hasKnownPrimary = sessionLoggedToday;
    final day = today();
    final persisted = (await repo.loadSessionLogsSince(day))
        .where((log) => _isSameDate(log.date, day))
        .toList();
    if (persisted.isEmpty) return hasKnownPrimary;

    final knownIds = _recentLogs.map((log) => log.id).toSet();
    _recentLogs = [
      ..._recentLogs,
      ...persisted.where((log) => knownIds.add(log.id)),
    ];
    return hasKnownPrimary ||
        persisted.any((log) => !log.isSupplemental);
  }

  Future<void> _assertPrimaryPlanUnlocked() async {
    if (_completionInFlight || (await _hasPersistedWorkoutToday())) {
      throw StateError(_primaryPlanLockedMessage);
    }
  }

  /// Sharp hip pain is a session-level constraint and persists in exercise
  /// state until the pain lifecycle clears it. Today must therefore filter
  /// alternatives from both the current check-in and prior frozen state.
  bool hasActiveSharpHipPain(List<PainFlag> currentCheckInPain) {
    return painEngine.hipSharpActive(currentCheckInPain) ||
        exerciseStates.values.any(
          (state) =>
              state.painFrozen &&
              state.painSeverity == PainSeverity.sharp &&
              state.painRegion == BodyRegion.hip,
        );
  }

  /// The single readiness/safety decision consumed by both Today and the
  /// notification scheduler. Supplying a clock keeps boundary tests exact.
  RehitEligibilityResult rehitEligibilityAt(DateTime nowLocal) {
    final visibleLogs = _recentLogs
        .where((log) => !log.completedAt.isAfter(nowLocal))
        .toList();
    final todaysLogs = visibleLogs
        .where((log) => _isSameDate(log.completedAt, nowLocal))
        .toList()
      ..sort((a, b) => a.completedAt.compareTo(b.completedAt));
    final firstLog = todaysLogs.isEmpty ? null : todaysLogs.first;
    final firstActualWorkSets = firstLog?.setLogs
            .where((setLog) => !setLog.isWarmup && setLog.value > 0)
            .length ??
        0;
    final firstSession = firstLog == null
        ? null
        : RehitFirstSessionFacts(
            // SessionLog is written only when a logger/cardio form is
            // submitted. Dose/partial qualification is checked separately.
            completed: true,
            qualifiesAsStrength:
                firstLog.countsAs.contains(FloorCategory.strength),
            plannedWorkSets: firstLog.plannedWorkSets,
            completedWorkSets: firstActualWorkSets,
            hadPainEvent: firstLog.setLogs.any((setLog) => setLog.painFlag),
            // Completion dose and an explicit early wrap-up are independent
            // facts. The engine applies the >=50% threshold itself, while an
            // explicitly ended-early session remains a separate safety stop.
            earlyAbort: firstLog.endedEarly,
          );

    return _evaluateRehitEligibility(
      nowLocal: nowLocal,
      firstSession: firstSession,
    );
  }

  /// Prospective gate for the optional-finisher hint before S2 starts. The
  /// actual logged-set threshold and pain checks are repeated at completion.
  RehitEligibilityResult rehitFinisherPreviewEligibility(
    SessionPlan? plan, {
    DateTime? nowLocal,
  }) {
    final validPlan = plan != null &&
        plan.sessionId == SessionTypeId.s2 &&
        plan.tier == SessionTier.extended &&
        plan.optionalRehitFinisherReserved &&
        sessionTemplates[plan.sessionId]?.hasOptionalRehitFinisher == true;
    final plannedWorkSets = plan?.plannedWorkSets ?? 0;
    return _evaluateRehitEligibility(
      nowLocal: nowLocal ?? DateTime.now(),
      firstSession: RehitFirstSessionFacts(
        completed: true,
        qualifiesAsStrength: validPlan,
        plannedWorkSets: plannedWorkSets,
        completedWorkSets: validPlan ? plannedWorkSets : 0,
      ),
    );
  }

  /// Completion-time gate for the immediate S2 finisher. It reuses every
  /// recovery/safety fact used by the later-day offer, but evaluates the
  /// in-memory strength work instead of requiring an already persisted log.
  RehitEligibilityResult rehitFinisherEligibility(
    SessionPlan plan,
    List<SetLog> loggedSets, {
    bool endedEarly = false,
    DateTime? nowLocal,
  }) {
    final workSets = loggedSets
        .where((setLog) => !setLog.isWarmup && setLog.value > 0)
        .toList();
    final validPlan = plan.sessionId == SessionTypeId.s2 &&
        plan.tier == SessionTier.extended &&
        plan.optionalRehitFinisherReserved &&
        sessionTemplates[plan.sessionId]?.hasOptionalRehitFinisher == true;
    return _evaluateRehitEligibility(
      nowLocal: nowLocal ?? DateTime.now(),
      firstSession: RehitFirstSessionFacts(
        completed: true,
        qualifiesAsStrength: validPlan,
        plannedWorkSets: plan.plannedWorkSets,
        completedWorkSets: workSets.length,
        hadPainEvent: loggedSets.any((setLog) => setLog.painFlag),
        earlyAbort: endedEarly,
      ),
    );
  }

  RehitEligibilityResult _evaluateRehitEligibility({
    required DateTime nowLocal,
    required RehitFirstSessionFacts? firstSession,
  }) {
    final trace = todayTrace;
    final currentTrace = trace != null && _isSameDate(trace.date, nowLocal)
        ? trace
        : null;
    final visibleLogs = _recentLogs
        .where((log) => !log.completedAt.isAfter(nowLocal))
        .toList();
    final todaysLogs = visibleLogs
        .where((log) => _isSameDate(log.completedAt, nowLocal))
        .toList();

    final checkInPain = currentTrace?.checkin.pain ?? const <PainFlag>[];
    final highIntensitySafety =
        _intensityRecoveryPolicy.evaluateHighIntensitySafety(
      logs: visibleLogs,
      asOf: nowLocal,
      checkInPain: checkInPain,
      exerciseStates: exerciseStates.values,
      travelMode: settings.travelMode,
    );
    final painEscalationActive =
        highIntensitySafety.painEscalationActive ||
        (currentTrace?.firedRules.any(
              (rule) => rule.key == RuleKey.painMedicalEscalation,
            ) ??
            false);
    final patternDeloadActive = highIntensitySafety.deloadActive ||
        (currentTrace?.firedRules.any(
              (rule) => rule.key == RuleKey.deloadActive,
            ) ??
            false);
    final targetLedger = const StimulusLedgerEngine().buildFromSessionLogs(
      logs: visibleLogs,
      asOf: nowLocal,
    );
    final targetStatus = const TrainingStatusEngine().build(
      targets: TrainingTargets(),
      ledger: targetLedger,
    );
    final highIntensityTargetDue = targetStatus.aerobic
            .firstWhere(
              (status) =>
                  status.target == AerobicTargetKind.highIntensityDistinctDays,
            )
            .distinctDayDeficit >
        0;

    return const RehitEligibilityEngine().evaluate(
      RehitEligibilityInput(
        readinessBucket:
            currentTrace?.recovery.bucket ?? ReadinessBucket.red,
        illnessGuardActive: currentTrace?.firedRules.any(
              (rule) => rule.key == RuleKey.illnessGuard,
            ) ??
            false,
        firstSession: firstSession,
        contraindicatingPainActive:
            highIntensitySafety.contraindicatingPainActive,
        painEscalationActive: painEscalationActive,
        globalDeloadActive: false,
        patternDeloadActive: patternDeloadActive,
        sessionLogsForRecovery: visibleLogs,
        rehitAlreadyCompletedToday: todaysLogs.any(_isQualifyingRehit),
        rehitUnavailableDueToTravel:
            highIntensitySafety.travelUnavailable,
        highIntensityTargetDue: highIntensityTargetDue,
        nowLocal: nowLocal,
      ),
    );
  }

  RehitEligibilityResult get secondRehitEligibility =>
      rehitEligibilityAt(DateTime.now());

  /// Compatibility convenience; all behavior delegates to the shared result.
  bool get canOfferSecondRehit => secondRehitEligibility.eligible;

  String _rehitEligibilityMessage(RehitEligibilityResult result) {
    if (result.closedReasons.contains(RehitClosedReason.highIntensityTargetMet)) {
      return 'The three-distinct-day high-intensity target in the rolling 7-day window is already met.';
    }
    return result.closedReasons.map((reason) => reason.name).join(', ');
  }

  @visibleForTesting
  bool isQualifyingRehitForTesting(SessionLog log) =>
      _isQualifyingRehit(log);

  bool _isQualifyingRehit(SessionLog log) {
    if (log.templateId == SessionTypeId.s7) {
      final completion = log.cardioCompletion;
      if (completion == null) {
        return _intensityRecoveryPolicy.isRecoveryRelevant(log);
      }
      return completion.protocol.type == CardioProtocolType.rehit &&
          completion.meetsCreditableDose;
    }
    if (log.templateId != SessionTypeId.s2) return false;
    final completion = log.cardioCompletion;
    return log.rehitFinisherCompleted ||
        (completion?.protocol.type == CardioProtocolType.rehit &&
            completion!.meetsCreditableDose);
  }

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
    if (uri.scheme == 'morningcoach' && uri.host == 'oauth-callback') {
      final code = uri.queryParameters['code'];
      final state = uri.queryParameters['state'];
      if (code == null || _oauthState == null || state != _oauthState) return;
      _oauthState = null;
      await _completeOuraConnection(code);
    } else if (uri.scheme == OneDriveClient.redirectScheme && uri.host == OneDriveClient.redirectHost) {
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
    unawaited(syncNotifications());
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
    _recentLogs = await repo.loadSessionLogsSince(
      today().subtract(const Duration(days: 7)),
    );
    _scheduleLogs = await repo.loadSessionLogsSince(
      today().subtract(const Duration(days: scheduleHabitWindowDays - 1)),
    );
    _todayEvents = await repo.loadAnalyticsEventsSince(today());
    manualLoadEntries = await repo.loadManualLoadEntries();
  }

  /// Trailing window used to learn training-time habits. Eight weeks covers a
  /// month of holidays without letting a routine from six months ago drive
  /// today's reminder.
  static const scheduleHabitWindowDays = 56;

  static const _scheduleFitEngine = ScheduleFitEngine();
  static const _analyticsEngine = AnalyticsEngine();
  static const _restDayRehitEngine = RestDayRehitEngine();

  /// The user's observed training rhythm, from the wider schedule window.
  ScheduleHabits scheduleHabitsAt(DateTime nowLocal) =>
      _scheduleFitEngine.buildHabits(
        logs: _scheduleLogs,
        asOf: nowLocal,
        windowDays: scheduleHabitWindowDays,
      );

  /// Records one analytics observation. Best-effort by design: an analytics
  /// write must never fail a check-in or a completed workout.
  ///
  /// [oncePerDay] events are skipped when the same type already exists for
  /// today, which is what makes "when did the app first suggest this" a
  /// meaningful timestamp rather than the most recent re-evaluation.
  Future<void> recordAnalyticsEvent(
    AnalyticsEventType type, {
    Map<String, String> properties = const {},
    bool oncePerDay = false,
    DateTime? at,
  }) async {
    try {
      final timestamp = at ?? DateTime.now();
      final day = DateTime(timestamp.year, timestamp.month, timestamp.day);
      _todayEvents = _todayEvents
          .where((event) => _isSameDate(event.date, day))
          .toList();
      if (oncePerDay && _todayEvents.any((event) => event.type == type)) {
        return;
      }
      final event = AnalyticsEvent(
        id: '${day.toIso8601String()}-${type.name}-'
            '${timestamp.microsecondsSinceEpoch}',
        type: type,
        timestamp: timestamp,
        date: day,
        properties: properties,
      );
      _todayEvents = [..._todayEvents, event];
      await repo.saveAnalyticsEvent(event);
    } catch (_) {
      // Analytics is observation, never a precondition for training.
    }
  }

  /// Called when the user actually begins a session, so the gap between the
  /// plan being ready and training starting is measurable.
  Future<void> markSessionStarted(SessionPlan plan, {DateTime? at}) =>
      recordAnalyticsEvent(
        AnalyticsEventType.sessionStarted,
        at: at,
        properties: {
          'sessionId': plan.sessionId.name,
          'tier': plan.tier.name,
          'estimatedDurationMin': '${plan.estimatedDurationMin}',
          'plannedWorkSets': '${plan.plannedWorkSets}',
        },
      );

  /// The rest-day REHIT reminder decision: is today going unused, is a short
  /// high-intensity exposure safe, and when would it fit?
  RestDayRehitResult restDayRehitEligibilityAt(DateTime nowLocal) {
    final trace = todayTrace;
    final currentTrace =
        trace != null && _isSameDate(trace.date, nowLocal) ? trace : null;
    final visibleLogs = _recentLogs
        .where((log) => !log.completedAt.isAfter(nowLocal))
        .toList();
    final safety = _intensityRecoveryPolicy.evaluateHighIntensitySafety(
      logs: visibleLogs,
      asOf: nowLocal,
      checkInPain: currentTrace?.checkin.pain ?? const <PainFlag>[],
      exerciseStates: exerciseStates.values,
      travelMode: settings.travelMode,
    );
    final ledger = const StimulusLedgerEngine().buildFromSessionLogs(
      logs: visibleLogs,
      asOf: nowLocal,
    );
    final status = const TrainingStatusEngine()
        .build(targets: TrainingTargets(), ledger: ledger);
    final highIntensityTargetDue = status.aerobic
            .firstWhere(
              (entry) =>
                  entry.target == AerobicTargetKind.highIntensityDistinctDays,
            )
            .distinctDayDeficit >
        0;

    final slot = _scheduleFitEngine.suggestSlot(
      habits: scheduleHabitsAt(nowLocal),
      nowLocal: nowLocal,
      earliestHour: settings.restDayRehitNudgeEarliestHour,
      latestHour: settings.restDayRehitNudgeLatestHour,
    );

    return _restDayRehitEngine.evaluate(
      _restDayRehitEngine.inputFromSafety(
        safety: safety,
        trainingLoggedToday:
            RestDayRehitEngine.hasTrainingOn(_recentLogs, nowLocal),
        readinessBucket: currentTrace?.recovery.bucket,
        illnessGuardActive: currentTrace?.firedRules.any(
              (rule) => rule.key == RuleKey.illnessGuard,
            ) ??
            false,
        highIntensityTargetDue: highIntensityTargetDue,
        scheduleSlot: slot,
        nowLocal: nowLocal,
      ),
    );
  }

  RestDayRehitResult get restDayRehitEligibility =>
      restDayRehitEligibilityAt(DateTime.now());

  /// Whether a rest-day REHIT may be *logged* right now, not merely
  /// suggested.
  ///
  /// Stricter than the reminder: the reminder may go out on a day with no
  /// check-in (inviting one), but nothing high-intensity is recorded through
  /// this path without a GREEN readiness decision on file. Every other gate
  /// is the same, and all of them are re-checked inside [logCardioSession].
  bool canLogRestDayRehitAt(DateTime nowLocal) {
    final result = restDayRehitEligibilityAt(nowLocal);
    return result.eligible && !result.checkInMissing;
  }

  bool get canLogRestDayRehit => canLogRestDayRehitAt(DateTime.now());

  /// Loads the full analytics surface. Uses the same 84-day read window as
  /// History so both screens describe the same stretch of training.
  Future<TrainingTimeInsights> loadInsights({
    DateTime? asOf,
    int windowDays = 56,
  }) async {
    final effectiveAsOf = asOf ?? DateTime.now();
    final day = DateTime(
      effectiveAsOf.year,
      effectiveAsOf.month,
      effectiveAsOf.day,
    );
    final since = day.subtract(Duration(days: windowDays - 1));
    final logs = await repo.loadSessionLogsSince(since);
    final events = await repo.loadAnalyticsEventsSince(since);
    return _analyticsEngine.build(
      logs: logs,
      events: events,
      asOf: effectiveAsOf,
      windowDays: windowDays,
    );
  }

  /// Loads the complete History surface and calculates its read-only dose
  /// feedback from the same persisted records. Eighty-four days preserves the
  /// existing 12-week heatmap and comfortably covers the inclusive trailing
  /// 28-day stimulus window (29 calendar dates including today).
  Future<HistoryData> loadHistoryData({DateTime? asOf}) async {
    final effectiveAsOf = asOf ?? DateTime.now();
    final historyDay = DateTime(
      effectiveAsOf.year,
      effectiveAsOf.month,
      effectiveAsOf.day,
    );
    final logs = await repo.loadSessionLogsSince(
      historyDay.subtract(const Duration(days: 84)),
    );
    final recoverySnapshots = await repo.loadRecoverySnapshotsSince(
      historyDay.subtract(const Duration(days: 28)),
    );
    final targets = TrainingTargets();
    final ledger = const StimulusLedgerEngine().buildFromSessionLogs(
      logs: logs,
      asOf: effectiveAsOf,
    );
    final trainingStatus = const TrainingStatusEngine().build(
      targets: targets,
      ledger: ledger,
    );
    return HistoryData(
      asOf: effectiveAsOf,
      logs: logs,
      recoverySnapshots: recoverySnapshots,
      targets: targets,
      ledger: ledger,
      trainingStatus: trainingStatus,
    );
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
    final travelModeChanged = settings.travelMode != newSettings.travelMode;
    // The REHIT day marker is internal state, not an editable preference.
    // Preserve a marker written while a settings screen held an older copy.
    settings = newSettings.copyWith(
      secondRehitNudgeScheduledDay: settings.secondRehitNudgeScheduledDay,
      secondRehitNudgeScheduledFor: settings.secondRehitNudgeScheduledFor,
      restDayRehitNudgeScheduledDay: settings.restDayRehitNudgeScheduledDay,
      restDayRehitNudgeScheduledFor: settings.restDayRehitNudgeScheduledFor,
      lowerBackRecovery: settings.lowerBackRecovery,
    );
    await repo.saveSettings(settings);
    unawaited(syncNotifications());
    if (travelModeChanged && todayTrace != null && !sessionLoggedToday) {
      await _refreshPendingPlanForSettings();
      return;
    }
    notifyListeners();
  }

  /// Starts the training modification only after the UI has presented and
  /// the user has explicitly denied neurological/emergency warning signs.
  Future<void> activateLowerBackRecovery({
    required DateTime symptomOnsetDate,
    required bool confirmedNoRedFlags,
  }) async {
    if (!confirmedNoRedFlags) {
      throw StateError(
        'Recovery mode cannot start while emergency warning signs are present.',
      );
    }
    final now = today();
    settings = settings.copyWith(
      lowerBackRecovery: _lowerBackRecoveryEngine.activate(
        now: now,
        symptomOnsetDate: symptomOnsetDate,
        hingeState: exerciseStates[MovementPattern.hinge.name],
      ),
    );
    await repo.saveSettings(settings);
    if (todayTrace != null && !sessionLoggedToday) {
      await _refreshPendingPlanForSettings();
      return;
    }
    notifyListeners();
  }

  Future<void> deactivateLowerBackRecovery() async {
    if (!settings.lowerBackRecovery.active) return;
    settings = settings.copyWith(
      lowerBackRecovery: _lowerBackRecoveryEngine.deactivate(
        settings.lowerBackRecovery,
        now: today(),
      ),
    );
    await repo.saveSettings(settings);
    if (todayTrace != null && !sessionLoggedToday) {
      await _refreshPendingPlanForSettings();
      return;
    }
    notifyListeners();
  }

  Future<void> recordLowerBackNextMorningResponse(
    LowerBackSymptomResponse response,
  ) async {
    final previous = settings.lowerBackRecovery;
    final next = _lowerBackRecoveryEngine.recordNextMorningResponse(
      previous,
      response: response,
      responseDate: today(),
    );
    if (identical(next, previous)) return;

    settings = settings.copyWith(lowerBackRecovery: next);
    if (previous.stage == LowerBackRecoveryStage.deadliftReentry &&
        previous.active &&
        !next.active &&
        next.lastReentryLoad != null) {
      final existing = exerciseStates[MovementPattern.hinge.name] ??
          ExerciseState(
            trackKey: MovementPattern.hinge.name,
            pattern: MovementPattern.hinge,
          );
      final resumed = existing.clone()
        ..currentLoad = next.lastReentryLoad!
        ..status = ExerciseStatus.progress
        ..lastTrainedDate = today()
        ..consecutiveHoldCount = 0
        ..microStepStage = 0
        ..lastPrescriptionChange =
            'Graded lower-back recovery re-entry baseline retained';
      exerciseStates[resumed.trackKey] = resumed;
      await repo.saveExerciseState(resumed);
    }
    await repo.saveSettings(settings);
    if (todayTrace != null && !sessionLoggedToday) {
      await _refreshPendingPlanForSettings();
      return;
    }
    notifyListeners();
  }

  /// Enables or disables no-equipment travel mode immediately. If today's
  /// session has not started/completed, regenerate it from the persisted
  /// check-in so the visible prescription can never lag behind the toggle.
  Future<DecisionTrace?> setTravelMode(bool enabled) async {
    if (_travelModeChangeInFlight) return todayTrace;
    if (settings.travelMode == enabled) return todayTrace;
    _travelModeChangeInFlight = true;
    notifyListeners();
    try {
      await saveSettings(settings.copyWith(travelMode: enabled));
      return todayTrace;
    } finally {
      _travelModeChangeInFlight = false;
      notifyListeners();
    }
  }

  Future<void> _refreshPendingPlanForSettings() async {
    final current = todayTrace;
    if (current == null) return;
    if (await _hasPersistedWorkoutToday()) {
      notifyListeners();
      return;
    }
    final now = today();
    final todaySnapshots = (await repo.loadRecoverySnapshotsSince(now))
        .where((snapshot) => _isSameDate(snapshot.date, now))
        .toList();
    await _recomputeAndPersist(
      checkin: current.checkin,
      todaySnapshot: todaySnapshots.isEmpty ? null : todaySnapshots.first,
      forcedSessionId: current.plan?.sessionId,
      forcedSessionProvenance: ForcedSessionProvenance.internalRefresh,
    );
  }

  /// §3.1 + §12: (re)schedule the wake-window nudge and cutoff reminder.
  /// Best-effort - never blocks or throws.
  Future<void> syncNotifications() {
    _notificationSyncQueued = true;
    return _notificationSyncTask ??= _drainNotificationSyncs();
  }

  Future<void> _drainNotificationSyncs() async {
    try {
      while (_notificationSyncQueued) {
        _notificationSyncQueued = false;
        await _syncNotificationsOnce();
      }
    } finally {
      _notificationSyncTask = null;
    }
  }

  Future<void> _syncNotificationsOnce() async {
    try {
      await NotificationService.sync(
        enabled: settings.notificationsEnabled,
        wakeWindow: settings.wakeWindow,
        cutoffHour: settings.checkInCutoffHour,
        checkedInToday: todayTrace != null,
      );

      final rehitEligibility = secondRehitEligibility;
      if (rehitEligibility.eligible) {
        // The first moment the app judged a second REHIT worthwhile. Recorded
        // whether or not a push nudge is enabled, so the suggestion→completion
        // latency is measurable for a user who never turns notifications on.
        await recordAnalyticsEvent(
          AnalyticsEventType.rehitSuggested,
          at: rehitEligibility.observedAt,
          oncePerDay: true,
          properties: {
            'suggestedNudgeTime':
                rehitEligibility.suggestedNudgeTime?.toIso8601String() ?? '',
          },
        );
      }
      final rehitNudgeSync = await NotificationService.syncSecondRehitNudge(
        enabled: settings.secondRehitNudgeEnabled,
        eligibility: rehitEligibility,
        scheduledDay: settings.secondRehitNudgeScheduledDay,
        scheduledFor: settings.secondRehitNudgeScheduledFor,
      );
      if (rehitNudgeSync.stateChanged) {
        settings = settings.copyWith(
          secondRehitNudgeScheduledDay: rehitNudgeSync.scheduledDay,
          secondRehitNudgeScheduledFor: rehitNudgeSync.scheduledFor,
          clearSecondRehitNudgeScheduledDay:
              rehitNudgeSync.scheduledDay == null,
        );
        await repo.saveSettings(settings);
        if (rehitNudgeSync.scheduledFor != null) {
          await recordAnalyticsEvent(
            AnalyticsEventType.rehitNudgeScheduled,
            oncePerDay: true,
            properties: {
              'scheduledFor': rehitNudgeSync.scheduledFor!.toIso8601String(),
            },
          );
        }
      }

      final restDayEligibility = restDayRehitEligibility;
      if (restDayEligibility.eligible) {
        await recordAnalyticsEvent(
          AnalyticsEventType.restDayRehitSuggested,
          at: restDayEligibility.observedAt,
          oncePerDay: true,
          properties: {
            'suggestedNudgeTime':
                restDayEligibility.suggestedNudgeTime?.toIso8601String() ?? '',
            'slotSource': restDayEligibility.slotSource?.name ?? '',
            'checkInMissing': '${restDayEligibility.checkInMissing}',
          },
        );
      }
      final restDayNudgeSync = await NotificationService.syncRestDayRehitNudge(
        enabled: settings.restDayRehitNudgeEnabled,
        eligibility: restDayEligibility,
        scheduledDay: settings.restDayRehitNudgeScheduledDay,
        scheduledFor: settings.restDayRehitNudgeScheduledFor,
      );
      if (restDayNudgeSync.stateChanged) {
        settings = settings.copyWith(
          restDayRehitNudgeScheduledDay: restDayNudgeSync.scheduledDay,
          restDayRehitNudgeScheduledFor: restDayNudgeSync.scheduledFor,
          clearRestDayRehitNudgeScheduledDay:
              restDayNudgeSync.scheduledDay == null,
        );
        await repo.saveSettings(settings);
        if (restDayNudgeSync.scheduledFor != null) {
          await recordAnalyticsEvent(
            AnalyticsEventType.restDayRehitNudgeScheduled,
            oncePerDay: true,
            properties: {
              'scheduledFor': restDayNudgeSync.scheduledFor!.toIso8601String(),
            },
          );
        }
      }
    } catch (_) {
      // best-effort only
    }
  }

  Future<DecisionTrace> submitCheckIn({
    required int timeMinutes,
    required int subjective,
    List<PainFlag> pain = const [],
    RecoverySnapshot? recovery,
  }) async {
    await _assertPrimaryPlanUnlocked();
    final now = today();
    await _ensureDayStartSnapshot(now);
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
    await recordAnalyticsEvent(
      AnalyticsEventType.checkInSubmitted,
      at: checkin.timestamp,
      oncePerDay: true,
      properties: {
        'timeMinutes': '$timeMinutes',
        'subjective': '$subjective',
        'painFlags': '${pain.length}',
        'recoverySource': recovery == null
            ? 'none'
            : recovery.manualEntry
                ? 'manual'
                : 'oura',
      },
    );
    return _recomputeAndPersist(checkin: checkin, todaySnapshot: recovery);
  }

  /// §11 "swap session": re-runs today's decision with [sessionId] forced
  /// as the chosen candidate instead of the natural winner. Reuses the
  /// check-in/recovery already on file for today - only which session gets
  /// recommended changes, not the underlying readiness inputs.
  Future<DecisionTrace> swapToSession(SessionTypeId sessionId) async {
    await _assertPrimaryPlanUnlocked();
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
    ForcedSessionProvenance forcedSessionProvenance =
        ForcedSessionProvenance.manualOverride,
  }) async {
    await _assertPrimaryPlanUnlocked();
    final now = today();
    final historyStart = now.subtract(const Duration(days: 60));
    final recoveryHistory = await repo.loadRecoverySnapshotsSince(historyStart);
    final checkinHistory = await repo.loadCheckInsSince(historyStart);
    // Decision Engine v2 evaluates exact trailing 7- and 28-day stimulus
    // windows. Load one extra day so timestamp boundaries cannot truncate the
    // oldest qualifying event.
    final sessionLogs = await repo.loadSessionLogsSince(
      now.subtract(const Duration(days: 29)),
    );

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
      forcedSessionProvenance: forcedSessionProvenance,
    );
    final output = const DecisionEngine().decide(input);

    exerciseStates = output.patchedExerciseStates;
    await repo.saveExerciseStates(exerciseStates);
    await repo.saveDecisionTrace(output.trace);
    todayTrace = output.trace;
    // First plan of the day only: a swap or a settings refresh must not reset
    // the "plan was ready at" instant the start latency is measured from.
    await recordAnalyticsEvent(
      AnalyticsEventType.planGenerated,
      oncePerDay: true,
      properties: {
        'sessionId': output.trace.plan?.sessionId.name ?? 'rest',
        'tier': output.trace.plan?.tier.name ?? 'none',
        'estimatedDurationMin':
            '${output.trace.plan?.estimatedDurationMin ?? 0}',
        'readiness': output.trace.recovery.bucket.name,
        'forced': '${forcedSessionId != null}',
      },
    );
    unawaited(syncNotifications()); // check-in done -> today's cutoff nudge moves to tomorrow
    notifyListeners();
    return output.trace;
  }

  bool _isSameDate(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// Discards today's check-in/recovery entry and recommendation so the
  /// user can redo the morning check-in (e.g. after a typo). This also undoes
  /// the pain-lifecycle bookkeeping the mistaken check-in wrote. Once any
  /// primary attempt is logged, the check-in and plan are immutable today;
  /// supplemental work does not lock them.
  Future<void> resetToday() async {
    await _assertPrimaryPlanUnlocked();
    final now = today();
    if (_preCheckInSnapshot != null) {
      final beforeCheckIn = _preCheckInSnapshot!;
      // saveExerciseStates is an upsert, so restoring the old map alone
      // would leave any pain-affected tracks materialized by this check-in
      // in the database. Delete only keys absent from the exact in-memory
      // pre-check-in snapshot, then restore every original state below.
      for (final key
          in exerciseStates.keys.where((key) => !beforeCheckIn.containsKey(key))) {
        await repo.deleteExerciseState(key);
      }
      exerciseStates = beforeCheckIn;
    } else {
      // The in-memory snapshot is lost across an app restart. Reconstruct
      // the inverse of today's pain bookkeeping from persisted dates so
      // "Redo check-in" still removes a mistaken flag/schedule tick.
      exerciseStates = {
        for (final entry in exerciseStates.entries)
          entry.key: _painStateBeforeTodaysCheckIn(entry.value, now),
      };
    }
    await repo.saveExerciseStates(exerciseStates);
    _preCheckInSnapshot = null;

    await repo.deleteCheckIn(now);
    await repo.deleteRecoverySnapshot(now);
    await repo.deleteDecisionTrace(now);
    todayTrace = null;
    unawaited(syncNotifications());
    notifyListeners();
  }

  /// Persists a start-of-day snapshot of progression + queue the first time
  /// the day is touched, so [resetDay] can roll them back. Keyed by date, so
  /// a snapshot from a previous day is replaced rather than reused.
  Future<void> _ensureDayStartSnapshot(DateTime now) async {
    final existing = await repo.loadDayStartSnapshot();
    if (existing != null && existing['date'] == repo.ymd(now)) return;
    await repo.saveDayStartSnapshot(now, exerciseStates, queueState);
  }

  /// Full "Reset day": deletes ONLY today's check-in, recovery entry, plan,
  /// and logged sessions, and rolls progression + queue back to the start of
  /// today (from the day-start snapshot). No other day is touched. Works even
  /// after a session is logged — that's the point.
  Future<void> resetDay() async {
    final now = today();

    // Roll progression + queue back to the start of today, if we have the
    // snapshot. Delete any exercise-state tracks that only came into existence
    // today (absent from the snapshot) so nothing from today survives.
    final snap = await repo.loadDayStartSnapshotFor(now);
    if (snap != null) {
      for (final key in exerciseStates.keys.where((k) => !snap.states.containsKey(k))) {
        await repo.deleteExerciseState(key);
      }
      exerciseStates = snap.states;
      queueState = snap.queue;
      await repo.saveExerciseStates(exerciseStates);
      await repo.saveQueueState(queueState);
    }

    // Remove today's dated rows (check-in, recovery, trace, session logs).
    await repo.deleteDayData(now);
    await repo.deleteDayStartSnapshot();
    _preCheckInSnapshot = null;

    await _reloadAll();
    todayTrace = null;
    unawaited(syncNotifications());
    notifyListeners();
  }

  /// Manual progression override: jump a compound pattern to a chosen ladder
  /// step (and starting load), for when the user is already well past the
  /// entry step (e.g. push-ups). Resets deload/hold/micro state to a clean
  /// PROGRESS at the new step; the first session ramps quickly if it's easy.
  Future<void> setPatternProgression(
    MovementPattern pattern,
    int ladderIndex, {
    double? startLoad,
  }) async {
    final ladder = ladders[pattern];
    if (ladder == null) return;
    final idx = ladderIndex.clamp(0, ladder.steps.length - 1);
    final step = ladder.steps[idx];
    final key = pattern.name;
    final st = (exerciseStates[key] ?? ExerciseState(trackKey: key, pattern: pattern)).clone()
      ..ladderStepIndex = idx
      ..status = ExerciseStatus.progress
      ..microStepStage = 0
      ..consecutiveHoldCount = 0
      ..deloadSessionsRemaining = 0
      ..preDeloadLoad = null
      ..preDeloadLadderStepIndex = null
      ..awaitingUndershootCheck = true
      ..currentTargetValue = step.metric == ExerciseMetric.seconds
          ? (step.targetRange ?? pattern.repRange).$1
          : null
      ..lastPrescriptionChange = 'Set manually to "${step.name}"';

    const eq = EquipmentEngine();
    if (step.backpackLoaded) {
      st.currentLoad = startLoad != null ? max(0.0, startLoad) : 0;
    } else if (step.dumbbells == 0) {
      st.currentLoad = 0; // bodyweight
    } else {
      final achievable = step.dumbbells == 1
          ? eq.singleDbAchievableTotals(settings.equipment)
          : eq.twoDbAchievableTotals(settings.equipment, allowUneven: !step.unilateral);
      final target = startLoad ?? (st.currentLoad > 0 ? st.currentLoad : achievable.first);
      st.currentLoad = eq.roundDownToAchievable(target, achievable);
    }

    exerciseStates = {...exerciseStates, key: st};
    await repo.saveExerciseState(st);

    // Remember the load the user actually typed, per pattern+level, so the
    // dialog can show it back next time as a reference. This is informational
    // only — it is never auto-applied; a blank field still means "auto".
    if (startLoad != null) {
      manualLoadEntries = {...manualLoadEntries, _manualLoadKey(pattern, idx): startLoad};
      await repo.saveManualLoadEntries(manualLoadEntries);
    }
    notifyListeners();
  }

  String _manualLoadKey(MovementPattern pattern, int ladderIndex) =>
      '${pattern.name}:$ladderIndex';

  /// The load the user last typed for [pattern] at [ladderIndex] in the manual
  /// override dialog, or null if they never entered one. Reference only.
  double? lastManualLoad(MovementPattern pattern, int ladderIndex) =>
      manualLoadEntries[_manualLoadKey(pattern, ladderIndex)];

  /// The current ladder-step index for a compound pattern (Settings picker).
  int currentLadderIndex(MovementPattern pattern) =>
      exerciseStates[pattern.name]?.ladderStepIndex ?? 0;

  bool _completedFormalPainReentry({
    required SessionPlan plan,
    required String trackKey,
    required List<SetLog> allTrackSets,
  }) {
    if (plan.travelMode) return false;
    final entries = plan.exercises
        .where(
          (exercise) =>
              exercise.trackKey == trackKey &&
              exercise.isPainReentryTest &&
              !exercise.isWarmup &&
              !exercise.isTravel,
        )
        .toList();
    if (entries.length != 1) return false;

    final entry = entries.single;
    final submittedWorkSets =
        allTrackSets.where((setLog) => !setLog.isWarmup).toList();
    final requiredMinimum = switch (entry.metric) {
      ExerciseMetric.reps => 8,
      ExerciseMetric.seconds => 10,
      ExerciseMetric.minutes => null,
    };
    if (requiredMinimum == null ||
        entry.sets != 1 ||
        entry.targetRange != (requiredMinimum, requiredMinimum) ||
        entry.rirTarget != Rir.rir4plus ||
        submittedWorkSets.length < entry.sets ||
        allTrackSets.any((setLog) => setLog.painFlag)) {
      return false;
    }

    const loadTolerance = 0.000001;
    return submittedWorkSets.every(
      (setLog) =>
          setLog.pattern == entry.pattern &&
          setLog.metric == entry.metric &&
          setLog.value >= requiredMinimum &&
          setLog.rir == Rir.rir4plus &&
          !setLog.painFlag &&
          (entry.loadTotal == null ||
              (setLog.weight - entry.loadTotal!).abs() <= loadTolerance),
    );
  }

  /// A detraining plan carries no persisted ladder index, so recover it only
  /// from an exact built-in track/pattern/name/metric/target match. Requiring
  /// the canonical pattern track key keeps named accessories, pain
  /// substitutes, imported plans, and arbitrary exercise names from mutating
  /// an unrelated movement ladder.
  int? _exactBuiltInLadderStepIndex(PlannedExercise exercise) {
    if (exercise.trackKey != exercise.pattern.name) return null;
    final ladder = ladders[exercise.pattern];
    if (ladder == null) return null;

    int? match;
    for (var index = 0; index < ladder.steps.length; index++) {
      final step = ladder.steps[index];
      final targetRange = step.targetRange ?? exercise.pattern.repRange;
      if (step.name != exercise.name ||
          step.metric != exercise.metric ||
          targetRange != exercise.targetRange) {
        continue;
      }
      // Fail closed if a future ladder ever contains an ambiguous duplicate.
      if (match != null) return null;
      match = index;
    }
    return match;
  }

  bool _isExactNamedProgressionTrack(PlannedExercise exercise) {
    final named = substituteRegistry[exercise.trackKey];
    return named != null &&
        named.pattern == exercise.pattern &&
        named.name == exercise.name &&
        exercise.metric == ExerciseMetric.reps &&
        exercise.targetRange == const (8, 15);
  }

  Future<void> completeSession(
    SessionPlan plan,
    List<SetLog> loggedSets, {
    required int durationMinutes,
    DateTime? startedAt,
    int? elapsedSeconds,
    CardioCompletion? cardioCompletion,
    CardioCompletion? rehitFinisherCompletion,
    bool endedEarly = false,
    LowerBackSymptomResponse? lowerBackSameDayResponse,
  }) {
    return _completeSession(
      plan,
      loggedSets,
      durationMinutes: durationMinutes,
      startedAt: startedAt,
      elapsedSeconds: elapsedSeconds,
      cardioCompletion: cardioCompletion,
      rehitFinisherCompletion: rehitFinisherCompletion,
      endedEarly: endedEarly,
      lowerBackSameDayResponse: lowerBackSameDayResponse,
      isSupplemental: false,
    );
  }

  Future<void> _completeSession(
    SessionPlan plan,
    List<SetLog> loggedSets, {
    required int durationMinutes,
    required bool isSupplemental,
    DateTime? startedAt,
    int? elapsedSeconds,
    bool isUnplanned = false,
    bool bypassProspectiveHighIntensityGate = false,
    CardioCompletion? cardioCompletion,
    CardioCompletion? rehitFinisherCompletion,
    bool endedEarly = false,
    LowerBackSymptomResponse? lowerBackSameDayResponse,
  }) async {
    assert(!isUnplanned || isSupplemental);
    if (!isSupplemental) {
      await _assertPrimaryPlanUnlocked();
    }
    if (!bypassProspectiveHighIntensityGate && !isPlanUsableNow(plan)) {
      throw StateError(
        'This high-intensity session does not pass the current recovery/safety gate.',
      );
    }
    final completedLowerBackRecovery = loggedSets.any(
      (setLog) =>
          !setLog.isWarmup &&
          setLog.value > 0 &&
          setLog.trackKey == lowerBackRecoveryTrackKey,
    );
    if (completedLowerBackRecovery && lowerBackSameDayResponse == null) {
      throw ArgumentError.notNull('lowerBackSameDayResponse');
    }
    const cardioEngine = CardioEngine();
    final cardioOnly = sessionTemplates[plan.sessionId]?.isCardioOnly == true;
    CardioPrescription? primaryCardioPrescription;
    if (cardioOnly) {
      final prescription = cardioEngine.resolvePrescription(
        sessionId: plan.sessionId,
        persistedPrescription: plan.cardioPrescription,
        durationMinutes: plan.estimatedDurationMin,
        heartRateMaxBpm: settings.hrMax,
      );
      primaryCardioPrescription = prescription;
      if (cardioCompletion == null) {
        throw ArgumentError.notNull('cardioCompletion');
      }
      if (rehitFinisherCompletion != null) {
        throw ArgumentError(
          'A cardio-only session cannot also contain a REHIT finisher.',
        );
      }
      cardioEngine.validateSessionMatch(
        sessionId: plan.sessionId,
        prescription: prescription,
        completion: cardioCompletion,
      );
    } else {
      if (cardioCompletion != null) {
        throw ArgumentError(
          'Primary cardio completion is only valid for a cardio-only plan.',
        );
      }
      if (rehitFinisherCompletion != null) {
        if (plan.sessionId != SessionTypeId.s2 ||
            plan.tier != SessionTier.extended ||
            !plan.optionalRehitFinisherReserved ||
            sessionTemplates[plan.sessionId]?.hasOptionalRehitFinisher !=
                true) {
          throw ArgumentError(
            'A REHIT finisher is only valid for the extended S2 strength plan.',
          );
        }
        final finisherEligibility = rehitFinisherEligibility(
          plan,
          loggedSets,
          endedEarly: endedEarly,
        );
        if (!finisherEligibility.eligible) {
          throw StateError(
            'The optional REHIT finisher is not currently eligible: '
            '${_rehitEligibilityMessage(finisherEligibility)}',
          );
        }
        final finisherPrescription = cardioEngine.prescriptionFor(
          sessionId: SessionTypeId.s7,
          durationMinutes:
              sessionTypes[SessionTypeId.s7]!.fullDurationMin,
          heartRateMaxBpm: settings.hrMax,
        );
        cardioEngine.validateSessionMatch(
          sessionId: SessionTypeId.s7,
          prescription: finisherPrescription,
          completion: rehitFinisherCompletion,
        );
      }
    }
    if (durationMinutes <= 0) {
      throw ArgumentError.value(
        durationMinutes,
        'durationMinutes',
        'Must be positive',
      );
    }
    if (_completionInFlight) {
      throw StateError('A workout completion is already being saved.');
    }
    _completionInFlight = true;

    try {
      const progression = ProgressionEngine();
      final now = today();
      final completedAt = DateTime.now();

      // Keep every submitted set for pain safety, while progression and
      // completion math use only positive-value work. A zero-second hold or
      // zero-rep entry is an attempted step, not completed training work.
      final allSetsByTrack = <String, List<SetLog>>{};
      final byTrack = <String, List<SetLog>>{};
      for (final s in loggedSets) {
        allSetsByTrack.putIfAbsent(s.trackKey, () => []).add(s);
        if (s.isWarmup || s.value <= 0) continue;
        byTrack.putIfAbsent(s.trackKey, () => []).add(s);
      }
      final painFlaggedTodayKeys = allSetsByTrack.entries
          .where((entry) => entry.value.any((setLog) => setLog.painFlag))
          .map((entry) => entry.key)
          .toSet();

      // Snapshot this before the pain lifecycle below can clear a mild freeze
      // or resolve a graded re-entry. A session that began frozen records that
      // the pattern was trained, but never feeds the progression state machine.
      final startedPainFrozenKeys =
          byTrack.keys.where((key) => exerciseStates[key]?.painFrozen == true).toSet();
      final travelKeys = plan.exercises.where((e) => e.isTravel).map((e) => e.trackKey).toSet();
      final prescribedWorkSetsByTrack = <String, int>{};
      for (final exercise
          in plan.exercises.where((exercise) => !exercise.isWarmup && exercise.sets > 0)) {
        prescribedWorkSetsByTrack.update(
          exercise.trackKey,
          (sets) => sets + exercise.sets,
          ifAbsent: () => exercise.sets,
        );
      }

      // Pain-flag lifecycle at completion (§7.2): a pain-free session decays a
      // mild flag; a pain-free graded re-entry test passes and resumes the
      // pattern per §6.6 precedence. Runs BEFORE progression evaluation so the
      // resume still sees the real untrained gap (evaluateSession stamps
      // lastTrainedDate = today).
      for (final entry in byTrack.entries) {
        final state = exerciseStates[entry.key];
        if (state == null || !state.painFrozen) continue;
        final ranPainFree =
            allSetsByTrack[entry.key]!.every((s) => !s.painFlag);
        if (state.painReentryTestOffered && !state.painReentryTestPassed) {
          if (_completedFormalPainReentry(
            plan: plan,
            trackKey: entry.key,
            allTrackSets: allSetsByTrack[entry.key]!,
          )) {
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

      // §6.6: any real positive work on an exact canonical detraining entry
      // makes the emitted ladder step/load the new safe baseline. Full work
      // may then be evaluated normally; partial or YELLOW/RED work only
      // retains that baseline and stamps recency. Waiting for every set would
      // stamp the old state as recently trained and make the next plan snap
      // back to the harder pre-break prescription. Zero work, pain, travel,
      // deload, substitutes, and malformed entries remain fail-closed.
      final safeDetrainingBaselineKeys = <String>{};
      for (final e in plan.exercises) {
        if (!e.persistLoadOnCompletion ||
            e.isWarmup ||
            e.isTravel ||
            e.isPainReentryTest ||
            plan.travelMode ||
            e.substitutedFrom != null) {
          continue;
        }
        if (startedPainFrozenKeys.contains(e.trackKey) ||
            painFlaggedTodayKeys.contains(e.trackKey)) {
          continue;
        }
        final state = exerciseStates[e.trackKey];
        final prescribedWorkSets = prescribedWorkSetsByTrack[e.trackKey];
        final hasValidPositiveWork = byTrack[e.trackKey]?.any(
              (setLog) =>
                  setLog.pattern == e.pattern &&
                  setLog.exerciseName == e.name &&
                  setLog.metric == e.metric,
            ) ==
            true;
        if (state == null ||
            state.painFrozen ||
            state.status == ExerciseStatus.deload ||
            state.lastTrainedDate == null ||
            state.daysUntrained(now) < 10 ||
            prescribedWorkSets == null ||
            !hasValidPositiveWork) {
          continue;
        }

        final resolvedLadderStep = _exactBuiltInLadderStepIndex(e);
        final exactNamedTrack = _isExactNamedProgressionTrack(e);
        if (resolvedLadderStep == null && !exactNamedTrack) continue;
        safeDetrainingBaselineKeys.add(e.trackKey);

        final next = state.clone()..status = ExerciseStatus.progress;
        if (resolvedLadderStep != null) {
          next.ladderStepIndex = resolvedLadderStep;
        }
        if (e.loadTotal != null) next.currentLoad = e.loadTotal!;
        if (e.metric == ExerciseMetric.seconds && e.suggestedValue != null) {
          next.currentTargetValue = e.suggestedValue;
        }
        exerciseStates[e.trackKey] = next;
      }

      // §12 travel mode: bodyweight variants keep the pattern "trained"
      // (so §6.6 detraining doesn't misfire on return) but never advance
      // the load-based state machine.
      final progressionEligibility = <String, bool>{
        for (final e in plan.exercises.where((e) => !e.isWarmup))
          e.trackKey: e.progressionEligible &&
              (!e.persistLoadOnCompletion ||
                  safeDetrainingBaselineKeys.contains(e.trackKey)),
      };
      final prescribedDeloadKeys = <String>{
        for (final e in plan.exercises)
          if (!e.isWarmup &&
              !e.isTravel &&
              !plan.travelMode &&
              !e.isPainReentryTest &&
              e.substitutedFrom == null &&
              e.rirTarget == Rir.rir4plus &&
              exerciseStates[e.trackKey]?.status == ExerciseStatus.deload)
            e.trackKey,
      };

      for (final entry in byTrack.entries) {
        final state = exerciseStates[entry.key];
        if (state == null) continue;
        final prescribedWorkSets = prescribedWorkSetsByTrack[entry.key];
        final completedAllPrescribedWork = prescribedWorkSets != null &&
            entry.value.length >= prescribedWorkSets;
        // A deload touch is lifecycle completion, not normal progression.
        // YELLOW/RED deliberately disable load/ladder progression, but a
        // fully completed, explicitly prescribed RIR>=4 deload entry must
        // still consume one of its two touches. Travel variants, pain work,
        // substitutes, and partial attempts stay excluded by the same hard
        // safeguards used for ordinary progression.
        final mayConsumePrescribedDeloadTouch =
            prescribedDeloadKeys.contains(entry.key);
        if (travelKeys.contains(entry.key) ||
            startedPainFrozenKeys.contains(entry.key) ||
            painFlaggedTodayKeys.contains(entry.key) ||
            (progressionEligibility[entry.key] != true &&
                !mayConsumePrescribedDeloadTouch) ||
            !completedAllPrescribedWork) {
          // Partial positive work remains real work: retain it in the log and
          // ledger, process pain above, and stamp recency. It cannot advance
          // load/micro-stage until this track's final prescribed set count is
          // complete. Other fully completed tracks remain independently
          // eligible even when later exercises are wrapped.
          exerciseStates[entry.key] = state.clone()
            ..lastTrainedDate = now
            ..lastPrescriptionChange = null;
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
        if (rehitFinisherCompletion?.meetsCreditableDose == true) {
          countsAs.add(FloorCategory.intensity);
        }
      } else if (def.countsAs.contains(FloorCategory.intensity) &&
          (!cardioOnly || cardioCompletion!.meetsCreditableDose)) {
        countsAs.add(FloorCategory.intensity);
      }
      if (def.countsAs.contains(FloorCategory.aerobic) &&
          (!cardioOnly || cardioCompletion!.meetsCreditableDose)) {
        countsAs.add(FloorCategory.aerobic);
      }

      // A bike-guided attempt has no in-app stopwatch, but its completed dose
      // *is* its duration, so its start instant is exactly recoverable.
      final measuredElapsedSeconds =
          elapsedSeconds ?? cardioCompletion?.completedDurationSeconds;
      final resolvedStartedAt = startedAt ??
          (measuredElapsedSeconds == null
              ? null
              : completedAt
                  .subtract(Duration(seconds: measuredElapsedSeconds)));
      final timings = SessionTimings(
        startedAt: resolvedStartedAt,
        elapsedSeconds: measuredElapsedSeconds,
        plannedDurationMinutes: plan.estimatedDurationMin,
      );

      final log = SessionLog(
        id: '${now.toIso8601String()}-${plan.sessionId.name}-${completedAt.microsecondsSinceEpoch}',
        templateId: plan.sessionId,
        tier: plan.tier,
        date: now,
        completedAt: completedAt,
        setLogs: loggedSets,
        plannedWorkSets: plan.plannedWorkSets,
        completedWorkSets:
            loggedSets.where((s) => !s.isWarmup && s.value > 0).length,
        durationMinutes: durationMinutes,
        timings: timings,
        countsAs: countsAs,
        cardioCompletion: cardioCompletion ?? rehitFinisherCompletion,
        cardioCompletedAsPrescribed: cardioOnly
            ? !endedEarly &&
                cardioCompletion!.completesPrescription(
                  primaryCardioPrescription!,
                )
            : null,
        rehitFinisherCompleted:
            rehitFinisherCompletion?.meetsCreditableDose == true,
        isSupplemental: isSupplemental,
        isUnplanned: isUnplanned,
        travelMode: plan.travelMode,
        endedEarly: endedEarly,
      );
      await repo.saveSessionLog(log);
      _recentLogs = [..._recentLogs, log];
      _scheduleLogs = [..._scheduleLogs, log];
      if (completedLowerBackRecovery) {
        final recoveryExercise = plan.exercises.firstWhere(
          (exercise) => exercise.trackKey == lowerBackRecoveryTrackKey,
        );
        final recoveryPainFlagged = loggedSets.any(
          (setLog) =>
              setLog.trackKey == lowerBackRecoveryTrackKey &&
              setLog.painFlag,
        );
        settings = settings.copyWith(
          lowerBackRecovery: _lowerBackRecoveryEngine.recordSession(
            settings.lowerBackRecovery,
            sessionDate: now,
            sameDayResponse: recoveryPainFlagged
                ? LowerBackSymptomResponse.worse
                : lowerBackSameDayResponse!,
            performedLoad: recoveryExercise.loadTotal,
          ),
        );
        await repo.saveSettings(settings);
      }
      await recordAnalyticsEvent(
        AnalyticsEventType.sessionCompleted,
        at: completedAt,
        properties: {
          'sessionId': plan.sessionId.name,
          'tier': plan.tier.name,
          'plannedDurationMin': '${plan.estimatedDurationMin}',
          'elapsedSeconds': '${measuredElapsedSeconds ?? durationMinutes * 60}',
          'plannedWorkSets': '${plan.plannedWorkSets}',
          'completedWorkSets': '${log.completedWorkSets}',
          'endedEarly': '$endedEarly',
          'supplemental': '$isSupplemental',
        },
      );
      if (AnalyticsEngine.isQualifyingRehitLog(log)) {
        await recordAnalyticsEvent(
          AnalyticsEventType.rehitCompleted,
          at: completedAt,
          properties: {
            'sessionId': plan.sessionId.name,
            'asFinisher': '${log.rehitFinisherCompleted}',
            'unplanned': '$isUnplanned',
          },
        );
      }
      unawaited(syncNotifications());

      if (log.countsTowardQueueAndFloor && plan.grantsQueueCredit) {
        queueState = const QueueEngine().advance(queueState, plan.sessionId);
        await repo.saveQueueState(queueState);
      }
      notifyListeners();

      // Auto-backup after a logged session, if enabled (best-effort).
      if (settings.oneDrive.autoBackup && settings.oneDrive.isConnected) {
        unawaited(backupToOneDrive(silent: true));
      }
    } finally {
      _completionInFlight = false;
    }
  }

  /// Logs a structured cardio attempt (S3 4×4, S6 Zone 2, or S7 REHIT).
  /// Partial attempts are persisted but do not earn category/queue credit.
  Future<void> logCardioSession(
    SessionTypeId id, {
    required CardioCompletion completion,
    SessionPlan? plan,
  }) async {
    if ((id == SessionTypeId.s3 || id == SessionTypeId.s7) &&
        !isHighIntensityUsableNow()) {
      throw StateError(
        'This high-intensity session does not pass the current recovery/safety gate.',
      );
    }
    final def = sessionTypes[id];
    if (def == null || sessionTemplates[id]?.isCardioOnly != true) {
      throw ArgumentError.value(id, 'id', 'Must identify a cardio-only session');
    }
    if (plan != null && plan.sessionId != id) {
      throw ArgumentError.value(plan.sessionId, 'plan', 'Session ID does not match');
    }

    // Today's primary plan is passed through intact so readiness/time
    // substitutions retain their tier, prescription, and queue-credit
    // decision. With no plan this is an added second-session REHIT.
    const cardioEngine = CardioEngine();
    if (plan == null && id != SessionTypeId.s7) {
      throw ArgumentError(
        'Only the optional second-session REHIT can be logged without a plan.',
      );
    }
    // Two independent openings for a plan-less REHIT: after a qualifying
    // first session, or on a day with no training at all. Both carry the same
    // recovery, pain, deload, travel, and target gates.
    if (plan == null &&
        !secondRehitEligibility.eligible &&
        !canLogRestDayRehit) {
      throw StateError(
        'An optional REHIT is not currently eligible.',
      );
    }
    final effectivePlan = plan ??
        SessionPlan(
          sessionId: id,
          sessionName: def.name,
          tier: SessionTier.full,
          exercises: const [],
          estimatedDurationMin: def.fullDurationMin,
          cardioPrescription: cardioEngine.prescriptionFor(
            sessionId: id,
            durationMinutes: def.fullDurationMin,
            heartRateMaxBpm: settings.hrMax,
          ),
          grantsQueueCredit: cycleOrder.contains(id),
          travelMode: settings.travelMode,
        );
    final prescription = cardioEngine.resolvePrescription(
      sessionId: id,
      persistedPrescription: effectivePlan.cardioPrescription,
      durationMinutes: effectivePlan.estimatedDurationMin,
      heartRateMaxBpm: settings.hrMax,
    );
    cardioEngine.validateSessionMatch(
      sessionId: id,
      prescription: prescription,
      completion: completion,
    );
    await _completeSession(
      effectivePlan,
      const [],
      durationMinutes: (completion.completedDurationSeconds + 59) ~/ 60,
      cardioCompletion: completion,
      isSupplemental: plan == null,
    );
  }

  /// Records a fixed CAROL REHIT attempt that already happened outside the
  /// app's prospective plan. Retrospective entry validates the real dose but
  /// deliberately does not re-run readiness, travel, recovery-window, first-
  /// session, or primary-plan gates that can no longer prevent the workout.
  Future<void> logUnplannedRehit({
    required CardioCompletion completion,
  }) async {
    const cardioEngine = CardioEngine();
    final def = sessionTypes[SessionTypeId.s7]!;
    final prescription = cardioEngine.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: def.fullDurationMin,
      heartRateMaxBpm: settings.hrMax,
    );
    cardioEngine.validateSessionMatch(
      sessionId: SessionTypeId.s7,
      prescription: prescription,
      completion: completion,
    );
    final plan = SessionPlan(
      sessionId: SessionTypeId.s7,
      sessionName: def.name,
      tier: SessionTier.full,
      exercises: const [],
      estimatedDurationMin: def.fullDurationMin,
      cardioPrescription: prescription,
      grantsQueueCredit: false,
      travelMode: false,
    );
    await _completeSession(
      plan,
      const [],
      durationMinutes: (completion.completedDurationSeconds + 59) ~/ 60,
      cardioCompletion: completion,
      isSupplemental: true,
      isUnplanned: true,
      bypassProspectiveHighIntensityGate: true,
    );
  }

  /// Marks a pain re-entry test (§7.2, 50% x 8) as passed pain-free, then
  /// resumes the pattern per §6.6's precedence rule.
  Future<void> markPainReentryTestPassed(String trackKey) async {
    final state = exerciseStates[trackKey];
    if (state == null) return;
    final next = const ProgressionEngine().resolvePostReentryResume(state, today(), settings.equipment);
    exerciseStates[trackKey] = next;
    await repo.saveExerciseState(next);
    unawaited(syncNotifications());
    notifyListeners();
  }

  /// Explicit user override for a pain freeze that is no longer relevant.
  /// This clears only pain-protocol metadata; progression, load, regression,
  /// and deload state remain exactly where they were.
  Future<void> clearPainFreeze(String trackKey) async {
    final state = exerciseStates[trackKey];
    if (state == null || !state.painFrozen) return;
    final next = _withoutPainFreeze(state);
    exerciseStates[trackKey] = next;
    await repo.saveExerciseState(next);
    unawaited(syncNotifications());
    notifyListeners();
  }

  ExerciseState _painStateBeforeTodaysCheckIn(ExerciseState state, DateTime date) {
    if (state.painFrozen &&
        state.painFlaggedDate != null &&
        _isSameDate(state.painFlaggedDate!, date)) {
      return _withoutPainFreeze(state);
    }
    if (state.painFrozen &&
        state.lastPainScheduledDate != null &&
        _isSameDate(state.lastPainScheduledDate!, date)) {
      final next = state.clone()
        ..sessionsScheduledWhileFlagged = max(0, state.sessionsScheduledWhileFlagged - 1)
        ..lastPainScheduledDate = null;
      if (next.sessionsScheduledWhileFlagged < 2) {
        next.painReentryTestOffered = false;
      }
      return next;
    }
    return state;
  }

  ExerciseState _withoutPainFreeze(ExerciseState state) => state.clone()
    ..painFrozen = false
    ..painSeverity = null
    ..painRegion = null
    ..painTags = {}
    ..painFlaggedDate = null
    ..sessionsScheduledWhileFlagged = 0
    ..lastPainScheduledDate = null
    ..prePainLoad = null
    ..prePainLadderStepIndex = null
    ..painReentryTestOffered = false
    ..painReentryTestPassed = false;

  Future<void> triggerManualDeload() async {
    exerciseStates = const ProgressionEngine()
        .forceGlobalDeloadForBuiltInTracks(exerciseStates);
    await repo.saveExerciseStates(exerciseStates);
    unawaited(syncNotifications());
    if (todayTrace != null && !sessionLoggedToday) {
      await _refreshPendingPlanForSettings();
      return;
    }
    notifyListeners();
  }

  static const painEngine = PainEngine();
}
