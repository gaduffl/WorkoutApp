import '../models/check_in.dart';
import '../models/decision_trace.dart';
import '../models/equipment.dart';
import '../models/exercise_state.dart';
import '../models/floor_category.dart';
import '../models/movement_pattern.dart';
import '../models/oura_connection.dart';
import '../models/pain.dart';
import '../models/plan.dart';
import '../models/recovery_snapshot.dart';
import '../models/rule_key.dart';
import '../models/session_log.dart';
import '../models/session_type.dart';
import '../models/set_log.dart';
import '../models/user_settings.dart';
import '../engine/queue_engine.dart';

String _dateStr(DateTime d) => DateTime(d.year, d.month, d.day).toIso8601String();
DateTime _parseDate(String s) => DateTime.parse(s);

Map<String, dynamic> exerciseStateToJson(ExerciseState s) => {
      'trackKey': s.trackKey,
      'pattern': s.pattern.name,
      'ladderStepIndex': s.ladderStepIndex,
      'currentLoad': s.currentLoad,
      'status': s.status.name,
      'lastTrainedDate': s.lastTrainedDate?.toIso8601String(),
      'consecutiveHoldCount': s.consecutiveHoldCount,
      'regressionDates': s.regressionDates.map((d) => d.toIso8601String()).toList(),
      'painFrozen': s.painFrozen,
      'painSeverity': s.painSeverity?.name,
      'painRegion': s.painRegion?.name,
      'painFlaggedDate': s.painFlaggedDate?.toIso8601String(),
      'sessionsScheduledWhileFlagged': s.sessionsScheduledWhileFlagged,
      'prePainLoad': s.prePainLoad,
      'prePainLadderStepIndex': s.prePainLadderStepIndex,
      'painReentryTestOffered': s.painReentryTestOffered,
      'painReentryTestPassed': s.painReentryTestPassed,
      'deloadSessionsRemaining': s.deloadSessionsRemaining,
      'preDeloadLoad': s.preDeloadLoad,
      'preDeloadLadderStepIndex': s.preDeloadLadderStepIndex,
      'awaitingUndershootCheck': s.awaitingUndershootCheck,
      'microStepStage': s.microStepStage,
    };

ExerciseState exerciseStateFromJson(Map<String, dynamic> j) => ExerciseState(
      trackKey: j['trackKey'] as String,
      pattern: MovementPattern.values.byName(j['pattern'] as String),
      ladderStepIndex: j['ladderStepIndex'] as int,
      currentLoad: (j['currentLoad'] as num).toDouble(),
      status: ExerciseStatus.values.byName(j['status'] as String),
      lastTrainedDate: j['lastTrainedDate'] == null ? null : DateTime.parse(j['lastTrainedDate'] as String),
      consecutiveHoldCount: j['consecutiveHoldCount'] as int,
      regressionDates: (j['regressionDates'] as List).map((e) => DateTime.parse(e as String)).toList(),
      painFrozen: j['painFrozen'] as bool,
      painSeverity: j['painSeverity'] == null ? null : PainSeverity.values.byName(j['painSeverity'] as String),
      painRegion: j['painRegion'] == null ? null : BodyRegion.values.byName(j['painRegion'] as String),
      painFlaggedDate: j['painFlaggedDate'] == null ? null : DateTime.parse(j['painFlaggedDate'] as String),
      sessionsScheduledWhileFlagged: j['sessionsScheduledWhileFlagged'] as int,
      prePainLoad: (j['prePainLoad'] as num?)?.toDouble(),
      prePainLadderStepIndex: j['prePainLadderStepIndex'] as int?,
      painReentryTestOffered: j['painReentryTestOffered'] as bool,
      painReentryTestPassed: j['painReentryTestPassed'] as bool,
      deloadSessionsRemaining: j['deloadSessionsRemaining'] as int,
      preDeloadLoad: (j['preDeloadLoad'] as num?)?.toDouble(),
      preDeloadLadderStepIndex: j['preDeloadLadderStepIndex'] as int?,
      awaitingUndershootCheck: j['awaitingUndershootCheck'] as bool,
      microStepStage: j['microStepStage'] as int? ?? 0,
    );

Map<String, dynamic> painFlagToJson(PainFlag f) => {
      'region': f.region.name,
      'severity': f.severity.name,
      'flaggedDate': f.flaggedDate.toIso8601String(),
      'tags': f.tags.map((t) => t.name).toList(),
    };

PainFlag painFlagFromJson(Map<String, dynamic> j) => PainFlag(
      region: BodyRegion.values.byName(j['region'] as String),
      severity: PainSeverity.values.byName(j['severity'] as String),
      flaggedDate: DateTime.parse(j['flaggedDate'] as String),
      tags: (j['tags'] as List).map((t) => PainTag.values.byName(t as String)).toSet(),
    );

Map<String, dynamic> checkInToJson(CheckIn c) => {
      'date': _dateStr(c.date),
      'timeMinutes': c.timeMinutes,
      'subjective': c.subjective,
      'pain': c.pain.map(painFlagToJson).toList(),
      'notes': c.notes,
      'timestamp': c.timestamp.toIso8601String(),
    };

CheckIn checkInFromJson(Map<String, dynamic> j) => CheckIn(
      date: _parseDate(j['date'] as String),
      timeMinutes: j['timeMinutes'] as int,
      subjective: j['subjective'] as int,
      pain: (j['pain'] as List).map((e) => painFlagFromJson(e as Map<String, dynamic>)).toList(),
      notes: j['notes'] as String?,
      timestamp: DateTime.parse(j['timestamp'] as String),
    );

Map<String, dynamic> recoverySnapshotToJson(RecoverySnapshot s) => {
      'date': _dateStr(s.date),
      'hrvRmssd': s.hrvRmssd,
      'restingHr': s.restingHr,
      'sleepScore': s.sleepScore,
      'ouraReadinessScore': s.ouraReadinessScore,
      'manualEntry': s.manualEntry,
    };

RecoverySnapshot recoverySnapshotFromJson(Map<String, dynamic> j) => RecoverySnapshot(
      date: _parseDate(j['date'] as String),
      hrvRmssd: (j['hrvRmssd'] as num?)?.toDouble(),
      restingHr: (j['restingHr'] as num?)?.toDouble(),
      sleepScore: j['sleepScore'] as int?,
      ouraReadinessScore: j['ouraReadinessScore'] as int?,
      manualEntry: j['manualEntry'] as bool? ?? true,
    );

Map<String, dynamic> setLogToJson(SetLog s) => {
      'trackKey': s.trackKey,
      'pattern': s.pattern.name,
      'exerciseName': s.exerciseName,
      'weight': s.weight,
      'reps': s.reps,
      'rir': s.rir.name,
      'painFlag': s.painFlag,
      'isWarmup': s.isWarmup,
      'timestamp': s.timestamp.toIso8601String(),
    };

SetLog setLogFromJson(Map<String, dynamic> j) => SetLog(
      trackKey: j['trackKey'] as String,
      pattern: MovementPattern.values.byName(j['pattern'] as String),
      exerciseName: j['exerciseName'] as String,
      weight: (j['weight'] as num).toDouble(),
      reps: j['reps'] as int,
      rir: Rir.values.byName(j['rir'] as String),
      painFlag: j['painFlag'] as bool,
      isWarmup: j['isWarmup'] as bool,
      timestamp: DateTime.parse(j['timestamp'] as String),
    );

Map<String, dynamic> sessionLogToJson(SessionLog l) => {
      'id': l.id,
      'templateId': l.templateId.name,
      'tier': l.tier.name,
      'date': _dateStr(l.date),
      'setLogs': l.setLogs.map(setLogToJson).toList(),
      'plannedWorkSets': l.plannedWorkSets,
      'completedWorkSets': l.completedWorkSets,
      'durationMinutes': l.durationMinutes,
      'notes': l.notes,
      'countsAs': l.countsAs.map((c) => c.name).toList(),
      'rehitFinisherCompleted': l.rehitFinisherCompleted,
    };

SessionLog sessionLogFromJson(Map<String, dynamic> j) => SessionLog(
      id: j['id'] as String,
      templateId: SessionTypeId.values.byName(j['templateId'] as String),
      tier: SessionTier.values.byName(j['tier'] as String),
      date: _parseDate(j['date'] as String),
      setLogs: (j['setLogs'] as List).map((e) => setLogFromJson(e as Map<String, dynamic>)).toList(),
      plannedWorkSets: j['plannedWorkSets'] as int,
      completedWorkSets: j['completedWorkSets'] as int,
      durationMinutes: j['durationMinutes'] as int,
      notes: j['notes'] as String?,
      countsAs: (j['countsAs'] as List).map((c) => FloorCategory.values.byName(c as String)).toSet(),
      rehitFinisherCompleted: j['rehitFinisherCompleted'] as bool? ?? false,
    );

Map<String, dynamic> queueStateToJson(QueueState q) => {
      'pointer': q.pointer.name,
      'served': q.served.map((s) => s.name).toList(),
    };

QueueState queueStateFromJson(Map<String, dynamic> j) => QueueState(
      pointer: SessionTypeId.values.byName(j['pointer'] as String),
      served: (j['served'] as List).map((s) => SessionTypeId.values.byName(s as String)).toSet(),
    );

Map<String, dynamic> equipmentConfigToJson(EquipmentConfig e) => {
      'blocks': e.blocks
          .map((b) => {'id': b.id, 'label': b.label, 'steps': b.perDumbbellSteps})
          .toList(),
      'unevenPairModeEnabled': e.unevenPairModeEnabled,
    };

EquipmentConfig equipmentConfigFromJson(Map<String, dynamic> j) => EquipmentConfig(
      blocks: (j['blocks'] as List)
          .map((b) => DumbbellBlock(
                id: b['id'] as String,
                label: b['label'] as String,
                perDumbbellSteps: (b['steps'] as List).map((v) => (v as num).toDouble()).toList(),
              ))
          .toList(),
      unevenPairModeEnabled: j['unevenPairModeEnabled'] as bool,
    );

Map<String, dynamic> ouraConnectionToJson(OuraConnection o) => {
      'clientId': o.clientId,
      'clientSecret': o.clientSecret,
      'accessToken': o.accessToken,
      'refreshToken': o.refreshToken,
      'accessTokenExpiresAt': o.accessTokenExpiresAt?.toIso8601String(),
    };

OuraConnection ouraConnectionFromJson(Map<String, dynamic> j) => OuraConnection(
      clientId: j['clientId'] as String?,
      clientSecret: j['clientSecret'] as String?,
      accessToken: j['accessToken'] as String?,
      refreshToken: j['refreshToken'] as String?,
      accessTokenExpiresAt: j['accessTokenExpiresAt'] == null ? null : DateTime.parse(j['accessTokenExpiresAt'] as String),
    );

Map<String, dynamic> userSettingsToJson(UserSettings u) => {
      'equipment': equipmentConfigToJson(u.equipment),
      'weeklyFloor': u.weeklyFloor.map((k, v) => MapEntry(k.name, v)),
      'units': u.units.name,
      'language': u.language.name,
      'age': u.age,
      'hrMaxOverride': u.hrMaxOverride,
      'oura': ouraConnectionToJson(u.oura),
      'anthropicApiKey': u.anthropicApiKey,
      'aiExplanationsEnabled': u.aiExplanationsEnabled,
      'aiTone': u.aiTone,
      'wakeWindow': u.wakeWindow,
      'checkInCutoffHour': u.checkInCutoffHour,
      'travelMode': u.travelMode,
      'notificationsEnabled': u.notificationsEnabled,
    };

UserSettings userSettingsFromJson(Map<String, dynamic> j) => UserSettings(
      equipment: equipmentConfigFromJson(j['equipment'] as Map<String, dynamic>),
      weeklyFloor: (j['weeklyFloor'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(FloorCategory.values.byName(k), v as int)),
      units: Units.values.byName(j['units'] as String),
      language: AppLanguage.values.byName(j['language'] as String),
      age: j['age'] as int,
      hrMaxOverride: (j['hrMaxOverride'] as num?)?.toDouble(),
      oura: j['oura'] == null ? const OuraConnection() : ouraConnectionFromJson(j['oura'] as Map<String, dynamic>),
      anthropicApiKey: j['anthropicApiKey'] as String?,
      aiExplanationsEnabled: j['aiExplanationsEnabled'] as bool? ?? true,
      aiTone: j['aiTone'] as String,
      wakeWindow: j['wakeWindow'] as String,
      checkInCutoffHour: j['checkInCutoffHour'] as int,
      travelMode: j['travelMode'] as bool? ?? false,
      notificationsEnabled: j['notificationsEnabled'] as bool? ?? false,
    );

Map<String, dynamic> firedRuleToJson(FiredRule r) => {
      'key': r.key.name,
      'pattern': r.pattern,
      'params': r.params,
    };

FiredRule firedRuleFromJson(Map<String, dynamic> j) => FiredRule(
      RuleKey.values.byName(j['key'] as String),
      pattern: j['pattern'] as String?,
      params: (j['params'] as Map).map((k, v) => MapEntry(k as String, v as String)),
    );

Map<String, dynamic> plannedExerciseToJson(PlannedExercise e) => {
      'trackKey': e.trackKey,
      'pattern': e.pattern.name,
      'name': e.name,
      'sets': e.sets,
      'repRangeLow': e.repRange.$1,
      'repRangeHigh': e.repRange.$2,
      'loadTotal': e.loadTotal,
      'loadDisplay': e.loadDisplay,
      'rirTarget': e.rirTarget.name,
      'substitutedFrom': e.substitutedFrom,
      'isWarmup': e.isWarmup,
      'instruction': e.instruction,
      'persistLoadOnCompletion': e.persistLoadOnCompletion,
      'isTravel': e.isTravel,
      'loadSteps': e.loadSteps,
      'supersetGroup': e.supersetGroup,
    };

PlannedExercise plannedExerciseFromJson(Map<String, dynamic> j) => PlannedExercise(
      trackKey: j['trackKey'] as String,
      pattern: MovementPattern.values.byName(j['pattern'] as String),
      name: j['name'] as String,
      sets: j['sets'] as int,
      repRange: (j['repRangeLow'] as int, j['repRangeHigh'] as int),
      loadTotal: (j['loadTotal'] as num?)?.toDouble(),
      loadDisplay: j['loadDisplay'] as String?,
      rirTarget: Rir.values.byName(j['rirTarget'] as String),
      substitutedFrom: j['substitutedFrom'] as String?,
      isWarmup: j['isWarmup'] as bool? ?? false,
      instruction: j['instruction'] as String?,
      persistLoadOnCompletion: j['persistLoadOnCompletion'] as bool? ?? false,
      isTravel: j['isTravel'] as bool? ?? false,
      loadSteps: (j['loadSteps'] as List?)?.map((e) => (e as num).toDouble()).toList(),
      supersetGroup: j['supersetGroup'] as int?,
    );

Map<String, dynamic> sessionPlanToJson(SessionPlan p) => {
      'sessionId': p.sessionId.name,
      'sessionName': p.sessionName,
      'tier': p.tier.name,
      'exercises': p.exercises.map(plannedExerciseToJson).toList(),
      'estimatedDurationMin': p.estimatedDurationMin,
      'grantsQueueCredit': p.grantsQueueCredit,
    };

SessionPlan sessionPlanFromJson(Map<String, dynamic> j) => SessionPlan(
      sessionId: SessionTypeId.values.byName(j['sessionId'] as String),
      sessionName: j['sessionName'] as String,
      tier: SessionTier.values.byName(j['tier'] as String),
      exercises: (j['exercises'] as List).map((e) => plannedExerciseFromJson(e as Map<String, dynamic>)).toList(),
      estimatedDurationMin: j['estimatedDurationMin'] as int,
      grantsQueueCredit: j['grantsQueueCredit'] as bool? ?? true,
    );

Map<String, dynamic> decisionTraceToJson(DecisionTrace t) => {
      'date': _dateStr(t.date),
      'checkin': checkInToJson(t.checkin),
      'recovery': {
        'hrvZToday': t.recovery.hrvZToday,
        'hrvTrend3': t.recovery.hrvTrend3,
        'sleepScore': t.recovery.sleepScore,
        'rhrDev': t.recovery.rhrDev,
        'bucket': t.recovery.bucket.name,
        'compositeScore': t.recovery.compositeScore,
        'inputsMissing': t.recovery.inputsMissing,
      },
      'candidates': t.candidates
          .map((c) => {
                'sessionId': c.sessionId.name,
                'tier': c.tier.name,
                'score': c.score,
                'scoreTerms': c.scoreTerms,
              })
          .toList(),
      'firedRules': t.firedRules.map(firedRuleToJson).toList(),
      'plan': t.plan == null ? null : sessionPlanToJson(t.plan!),
      'restReason': t.restReason,
      'queue': {
        'pointerBefore': t.queue.pointerBefore.name,
        'servedBefore': t.queue.servedBefore.map((s) => s.name).toList(),
        'pointerAfterIfCompleted': t.queue.pointerAfterIfCompleted?.name,
      },
    };

DecisionTrace decisionTraceFromJson(Map<String, dynamic> j) {
  final rec = j['recovery'] as Map<String, dynamic>;
  final q = j['queue'] as Map<String, dynamic>;
  return DecisionTrace(
    date: _parseDate(j['date'] as String),
    checkin: checkInFromJson(j['checkin'] as Map<String, dynamic>),
    recovery: RecoveryTrace(
      hrvZToday: (rec['hrvZToday'] as num?)?.toDouble(),
      hrvTrend3: (rec['hrvTrend3'] as num?)?.toDouble(),
      sleepScore: rec['sleepScore'] as int?,
      rhrDev: (rec['rhrDev'] as num?)?.toDouble(),
      bucket: ReadinessBucket.values.byName(rec['bucket'] as String),
      compositeScore: (rec['compositeScore'] as num).toDouble(),
      inputsMissing: (rec['inputsMissing'] as List).cast<String>(),
    ),
    candidates: (j['candidates'] as List)
        .map((c) => ScoredCandidate(
              sessionId: SessionTypeId.values.byName(c['sessionId'] as String),
              tier: SessionTier.values.byName(c['tier'] as String),
              score: c['score'] as int,
              scoreTerms: (c['scoreTerms'] as Map).map((k, v) => MapEntry(k as String, v as int)),
            ))
        .toList(),
    firedRules: (j['firedRules'] as List).map((e) => firedRuleFromJson(e as Map<String, dynamic>)).toList(),
    plan: j['plan'] == null ? null : sessionPlanFromJson(j['plan'] as Map<String, dynamic>),
    restReason: j['restReason'] as String?,
    queue: QueueTraceInfo(
      pointerBefore: SessionTypeId.values.byName(q['pointerBefore'] as String),
      servedBefore: (q['servedBefore'] as List).map((s) => SessionTypeId.values.byName(s as String)).toSet(),
      pointerAfterIfCompleted:
          q['pointerAfterIfCompleted'] == null ? null : SessionTypeId.values.byName(q['pointerAfterIfCompleted'] as String),
    ),
  );
}
