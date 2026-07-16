import '../models/cardio_protocol.dart';
import '../models/check_in.dart';
import '../models/decision_trace.dart';
import '../models/equipment.dart';
import '../models/exercise_metric.dart';
import '../models/exercise_state.dart';
import '../models/floor_category.dart';
import '../models/movement_pattern.dart';
import '../models/onedrive_connection.dart';
import '../models/oura_connection.dart';
import '../models/pain.dart';
import '../models/plan.dart';
import '../models/recovery_snapshot.dart';
import '../models/rule_key.dart';
import '../models/session_log.dart';
import '../models/session_type.dart';
import '../models/set_log.dart';
import '../models/training_status.dart';
import '../models/training_targets.dart';
import '../models/user_settings.dart';
import '../engine/queue_engine.dart';

String _dateStr(DateTime d) => DateTime(d.year, d.month, d.day).toIso8601String();
DateTime _parseDate(String s) => DateTime.parse(s);

DateTime? _tryParseOptionalDateTime(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

ExerciseMetric _exerciseMetricFromJson(Object? value) {
  if (value is String) {
    for (final metric in ExerciseMetric.values) {
      if (metric.name == value) return metric;
    }
  }
  return ExerciseMetric.reps;
}

bool _plannedExerciseIsCompoundWorkFromJson(Map<String, dynamic> json) {
  final explicit = json['isCompoundWork'];
  if (explicit is bool) return explicit;

  // Plans saved before compound-role metadata was introduced used the
  // movement pattern itself as the normal progression track key. Infer only
  // that narrow legacy shape: named S5 work and pain substitutes use their
  // own `sub:` track keys, while warm-ups are never work entries.
  if (json['isWarmup'] as bool? ?? false) return false;
  final pattern =
      MovementPattern.values.byName(json['pattern'] as String);
  return pattern.patternClass == PatternClass.compound &&
      json['trackKey'] == pattern.name;
}

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
      'painTags': s.painTags.map((tag) => tag.name).toList(),
      'sessionsScheduledWhileFlagged': s.sessionsScheduledWhileFlagged,
      'lastPainScheduledDate': s.lastPainScheduledDate?.toIso8601String(),
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
      painTags: (j['painTags'] as List? ?? const [])
          .map((tag) => PainTag.values.byName(tag as String))
          .toSet(),
      sessionsScheduledWhileFlagged: j['sessionsScheduledWhileFlagged'] as int,
      lastPainScheduledDate: j['lastPainScheduledDate'] == null
          ? null
          : DateTime.parse(j['lastPainScheduledDate'] as String),
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
      'metric': s.metric.name,
      'value': s.value,
      // Retain the legacy field so older app builds can still import a
      // backup. Its meaning is superseded by metric/value in new builds.
      'reps': s.value,
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
      metric: _exerciseMetricFromJson(j['metric']),
      value: (j['value'] ?? j['reps']) as int,
      rir: Rir.values.byName(j['rir'] as String),
      painFlag: j['painFlag'] as bool? ?? false,
      isWarmup: j['isWarmup'] as bool? ?? false,
      timestamp: DateTime.parse(j['timestamp'] as String),
    );

Map<String, dynamic> cardioProtocolToJson(CardioProtocol protocol) => {
      'type': protocol.type.name,
      'name': protocol.name,
    };

CardioProtocol cardioProtocolFromJson(Map<String, dynamic> j) =>
    CardioProtocol(
      type: CardioProtocolType.values.byName(j['type'] as String),
      name: j['name'] as String,
    );

Map<String, dynamic> cardioPrescriptionToJson(
  CardioPrescription prescription,
) =>
    {
      'protocol': cardioProtocolToJson(prescription.protocol),
      'plannedWorkIntervals': prescription.plannedWorkIntervals,
      'plannedWorkSeconds': prescription.plannedWorkSeconds,
      'plannedRecoveryIntervals': prescription.plannedRecoveryIntervals,
      'plannedRecoverySeconds': prescription.plannedRecoverySeconds,
      'plannedDurationSeconds': prescription.plannedDurationSeconds,
      'targetHeartRateMinBpm': prescription.targetHeartRateMinBpm,
      'targetHeartRateMaxBpm': prescription.targetHeartRateMaxBpm,
      'targetRpeMin': prescription.targetRpeMin,
      'targetRpeMax': prescription.targetRpeMax,
    };

CardioPrescription cardioPrescriptionFromJson(Map<String, dynamic> j) =>
    CardioPrescription(
      protocol:
          cardioProtocolFromJson(j['protocol'] as Map<String, dynamic>),
      plannedWorkIntervals: j['plannedWorkIntervals'] as int,
      plannedWorkSeconds: j['plannedWorkSeconds'] as int,
      plannedRecoveryIntervals: j['plannedRecoveryIntervals'] as int,
      plannedRecoverySeconds: j['plannedRecoverySeconds'] as int,
      plannedDurationSeconds: j['plannedDurationSeconds'] as int,
      targetHeartRateMinBpm:
          (j['targetHeartRateMinBpm'] as num?)?.toDouble(),
      targetHeartRateMaxBpm:
          (j['targetHeartRateMaxBpm'] as num?)?.toDouble(),
      targetRpeMin: (j['targetRpeMin'] as num?)?.toDouble(),
      targetRpeMax: (j['targetRpeMax'] as num?)?.toDouble(),
    );

Map<String, dynamic> cardioCompletionToJson(CardioCompletion completion) => {
      'protocol': cardioProtocolToJson(completion.protocol),
      'completedWorkIntervals': completion.completedWorkIntervals,
      'completedWorkSeconds': completion.completedWorkSeconds,
      'completedRecoveryIntervals': completion.completedRecoveryIntervals,
      'completedRecoverySeconds': completion.completedRecoverySeconds,
      'completedDurationSeconds': completion.completedDurationSeconds,
      'averageHeartRateBpm': completion.averageHeartRateBpm,
      'peakHeartRateBpm': completion.peakHeartRateBpm,
      'rpe': completion.rpe,
    };

CardioCompletion cardioCompletionFromJson(Map<String, dynamic> j) =>
    CardioCompletion(
      protocol:
          cardioProtocolFromJson(j['protocol'] as Map<String, dynamic>),
      completedWorkIntervals: j['completedWorkIntervals'] as int,
      completedWorkSeconds: j['completedWorkSeconds'] as int,
      completedRecoveryIntervals: j['completedRecoveryIntervals'] as int,
      completedRecoverySeconds: j['completedRecoverySeconds'] as int,
      completedDurationSeconds: j['completedDurationSeconds'] as int,
      averageHeartRateBpm:
          (j['averageHeartRateBpm'] as num?)?.toDouble(),
      peakHeartRateBpm: (j['peakHeartRateBpm'] as num?)?.toDouble(),
      rpe: (j['rpe'] as num?)?.toDouble(),
    );

Map<String, dynamic> sessionLogToJson(SessionLog l) => {
      'id': l.id,
      'templateId': l.templateId.name,
      'tier': l.tier.name,
      'date': _dateStr(l.date),
      'completedAt': l.completedAt.toIso8601String(),
      'completedAtPrecision': l.completedAtPrecision.name,
      'setLogs': l.setLogs.map(setLogToJson).toList(),
      'plannedWorkSets': l.plannedWorkSets,
      'completedWorkSets': l.completedWorkSets,
      'durationMinutes': l.durationMinutes,
      'notes': l.notes,
      'cardioCompletion': l.cardioCompletion == null
          ? null
          : cardioCompletionToJson(l.cardioCompletion!),
      'cardioCompletedAsPrescribed': l.cardioCompletedAsPrescribed,
      'countsAs': l.countsAs.map((c) => c.name).toList(),
      'rehitFinisherCompleted': l.rehitFinisherCompleted,
      'isSupplemental': l.isSupplemental,
      'isUnplanned': l.isUnplanned,
      'travelMode': l.travelMode,
      'endedEarly': l.endedEarly,
    };

DateTime? _sessionCompletedAtFromJson(Map<String, dynamic> json) {
  final value = json['completedAt'];
  return value is String ? DateTime.tryParse(value) : null;
}

CompletionTimePrecision _sessionCompletionTimePrecisionFromJson(
  Map<String, dynamic> json,
) {
  // A missing or malformed timestamp has only calendar-date precision,
  // regardless of any contradictory metadata.
  if (_sessionCompletedAtFromJson(json) == null) {
    return CompletionTimePrecision.dateOnlyInferred;
  }
  final value = json['completedAtPrecision'];
  if (value is String) {
    for (final precision in CompletionTimePrecision.values) {
      if (precision.name == value) return precision;
    }
  }
  // Rows written after exact timestamps were introduced but before explicit
  // precision metadata are exact and remain backward compatible.
  return CompletionTimePrecision.exact;
}

SessionLog sessionLogFromJson(Map<String, dynamic> j) => SessionLog(
      id: j['id'] as String,
      templateId: SessionTypeId.values.byName(j['templateId'] as String),
      tier: SessionTier.values.byName(j['tier'] as String),
      date: _parseDate(j['date'] as String),
      completedAt: _sessionCompletedAtFromJson(j),
      completedAtPrecision: _sessionCompletionTimePrecisionFromJson(j),
      setLogs: (j['setLogs'] as List).map((e) => setLogFromJson(e as Map<String, dynamic>)).toList(),
      plannedWorkSets: j['plannedWorkSets'] as int,
      completedWorkSets: j['completedWorkSets'] as int,
      durationMinutes: j['durationMinutes'] as int,
      notes: j['notes'] as String?,
      cardioCompletion: j['cardioCompletion'] == null
          ? null
          : cardioCompletionFromJson(
              j['cardioCompletion'] as Map<String, dynamic>,
            ),
      cardioCompletedAsPrescribed:
          j['cardioCompletedAsPrescribed'] as bool?,
      countsAs: (j['countsAs'] as List).map((c) => FloorCategory.values.byName(c as String)).toSet(),
      rehitFinisherCompleted: j['rehitFinisherCompleted'] as bool? ?? false,
      isSupplemental: (j['isSupplemental'] as bool? ?? false) ||
          (j['isUnplanned'] as bool? ?? false),
      isUnplanned: j['isUnplanned'] as bool? ?? false,
      travelMode: j['travelMode'] as bool? ?? false,
      endedEarly: j['endedEarly'] as bool? ?? false,
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

Map<String, dynamic> oneDriveConnectionToJson(OneDriveConnection o) => {
      'accessToken': o.accessToken,
      'refreshToken': o.refreshToken,
      'accessTokenExpiresAt': o.accessTokenExpiresAt?.toIso8601String(),
      'account': o.account,
      'lastBackupAt': o.lastBackupAt?.toIso8601String(),
      'autoBackup': o.autoBackup,
    };

OneDriveConnection oneDriveConnectionFromJson(Map<String, dynamic> j) => OneDriveConnection(
      accessToken: j['accessToken'] as String?,
      refreshToken: j['refreshToken'] as String?,
      accessTokenExpiresAt: j['accessTokenExpiresAt'] == null ? null : DateTime.parse(j['accessTokenExpiresAt'] as String),
      account: j['account'] as String?,
      lastBackupAt: j['lastBackupAt'] == null ? null : DateTime.parse(j['lastBackupAt'] as String),
      autoBackup: j['autoBackup'] as bool? ?? false,
    );

Map<String, dynamic> userSettingsToJson(UserSettings u) => {
      'equipment': equipmentConfigToJson(u.equipment),
      'weeklyFloor': u.weeklyFloor.map((k, v) => MapEntry(k.name, v)),
      'units': u.units.name,
      'language': u.language.name,
      'age': u.age,
      'hrMaxOverride': u.hrMaxOverride,
      'oura': ouraConnectionToJson(u.oura),
      'oneDrive': oneDriveConnectionToJson(u.oneDrive),
      'anthropicApiKey': u.anthropicApiKey,
      'aiExplanationsEnabled': u.aiExplanationsEnabled,
      'aiTone': u.aiTone,
      'wakeWindow': u.wakeWindow,
      'checkInCutoffHour': u.checkInCutoffHour,
      'travelMode': u.travelMode,
      'notificationsEnabled': u.notificationsEnabled,
      'secondRehitNudgeScheduledDay': u.secondRehitNudgeScheduledDay,
      'secondRehitNudgeScheduledFor':
          u.secondRehitNudgeScheduledFor?.toIso8601String(),
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
      oneDrive: j['oneDrive'] == null ? const OneDriveConnection() : oneDriveConnectionFromJson(j['oneDrive'] as Map<String, dynamic>),
      anthropicApiKey: j['anthropicApiKey'] as String?,
      aiExplanationsEnabled: j['aiExplanationsEnabled'] as bool? ?? true,
      aiTone: j['aiTone'] as String,
      wakeWindow: j['wakeWindow'] as String,
      checkInCutoffHour: j['checkInCutoffHour'] as int,
      travelMode: j['travelMode'] as bool? ?? false,
      notificationsEnabled: j['notificationsEnabled'] as bool? ?? false,
      secondRehitNudgeScheduledDay: j['secondRehitNudgeScheduledDay'] as String?,
      secondRehitNudgeScheduledFor:
          _tryParseOptionalDateTime(j['secondRehitNudgeScheduledFor']),
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
      'metric': e.metric.name,
      'targetRangeLow': e.targetRange.$1,
      'targetRangeHigh': e.targetRange.$2,
      // Legacy aliases keep decision traces importable by an older build.
      'repRangeLow': e.targetRange.$1,
      'repRangeHigh': e.targetRange.$2,
      'loadTotal': e.loadTotal,
      'loadDisplay': e.loadDisplay,
      'rirTarget': e.rirTarget.name,
      'substitutedFrom': e.substitutedFrom,
      'isWarmup': e.isWarmup,
      'instruction': e.instruction,
      'persistLoadOnCompletion': e.persistLoadOnCompletion,
      'progressionEligible': e.progressionEligible,
      'isTravel': e.isTravel,
      'loadSteps': e.loadSteps,
      'supersetGroup': e.supersetGroup,
      'isCompoundWork': e.isCompoundWork,
      'isFeederWarmup': e.isFeederWarmup,
      'isPainReentryTest': e.isPainReentryTest,
    };

PlannedExercise plannedExerciseFromJson(Map<String, dynamic> j) => PlannedExercise(
      trackKey: j['trackKey'] as String,
      pattern: MovementPattern.values.byName(j['pattern'] as String),
      name: j['name'] as String,
      sets: j['sets'] as int,
      metric: _exerciseMetricFromJson(j['metric']),
      targetRange: (
        (j['targetRangeLow'] ?? j['repRangeLow']) as int,
        (j['targetRangeHigh'] ?? j['repRangeHigh']) as int,
      ),
      loadTotal: (j['loadTotal'] as num?)?.toDouble(),
      loadDisplay: j['loadDisplay'] as String?,
      rirTarget: Rir.values.byName(j['rirTarget'] as String),
      substitutedFrom: j['substitutedFrom'] as String?,
      isWarmup: j['isWarmup'] as bool? ?? false,
      instruction: j['instruction'] as String?,
      persistLoadOnCompletion: j['persistLoadOnCompletion'] as bool? ?? false,
      progressionEligible: j['progressionEligible'] as bool? ?? true,
      isTravel: j['isTravel'] as bool? ?? false,
      loadSteps: (j['loadSteps'] as List?)?.map((e) => (e as num).toDouble()).toList(),
      supersetGroup: j['supersetGroup'] as int?,
      isCompoundWork: _plannedExerciseIsCompoundWorkFromJson(j),
      isFeederWarmup: j['isFeederWarmup'] as bool? ?? false,
      isPainReentryTest: j['isPainReentryTest'] as bool? ?? false,
    );

Map<String, dynamic> sessionPlanToJson(SessionPlan p) => {
      'sessionId': p.sessionId.name,
      'sessionName': p.sessionName,
      'tier': p.tier.name,
      'exercises': p.exercises.map(plannedExerciseToJson).toList(),
      'estimatedDurationMin': p.estimatedDurationMin,
      'cardioPrescription': p.cardioPrescription == null
          ? null
          : cardioPrescriptionToJson(p.cardioPrescription!),
      'grantsQueueCredit': p.grantsQueueCredit,
      'travelMode': p.travelMode,
      'optionalRehitFinisherReserved': p.optionalRehitFinisherReserved,
    };

SessionPlan sessionPlanFromJson(Map<String, dynamic> j) => SessionPlan(
      sessionId: SessionTypeId.values.byName(j['sessionId'] as String),
      sessionName: j['sessionName'] as String,
      tier: SessionTier.values.byName(j['tier'] as String),
      exercises: (j['exercises'] as List).map((e) => plannedExerciseFromJson(e as Map<String, dynamic>)).toList(),
      estimatedDurationMin: j['estimatedDurationMin'] as int,
      cardioPrescription: j['cardioPrescription'] == null
          ? null
          : cardioPrescriptionFromJson(
              j['cardioPrescription'] as Map<String, dynamic>,
            ),
      grantsQueueCredit: j['grantsQueueCredit'] as bool? ?? true,
      travelMode: j['travelMode'] as bool? ?? false,
      optionalRehitFinisherReserved:
          j['optionalRehitFinisherReserved'] as bool? ?? false,
    );

Map<String, dynamic> effectiveSetTargetBandToJson(
  EffectiveSetTargetBand band,
) =>
    {
      'minimum': band.minimum,
      'center': band.center,
      'maximum': band.maximum,
    };

EffectiveSetTargetBand effectiveSetTargetBandFromJson(
  Map<String, dynamic> j,
) =>
    EffectiveSetTargetBand(
      minimum: (j['minimum'] as num).toDouble(),
      center: (j['center'] as num).toDouble(),
      maximum: (j['maximum'] as num).toDouble(),
    );

Map<String, dynamic> trainingTargetsToJson(TrainingTargets targets) => {
      'hardTimeWindowsMinutes': targets.hardTimeWindowsMinutes,
      'hypertrophyTargetBands': targets.hypertrophyTargetBands.map(
        (group, band) => MapEntry(
          group.name,
          effectiveSetTargetBandToJson(band),
        ),
      ),
      'hypertrophyEvaluationWindowDays':
          targets.hypertrophyEvaluationWindowDays,
      'intensityRollingWindowDays': targets.intensityRollingWindowDays,
      'preferredNorwegian4x4Exposures':
          targets.preferredNorwegian4x4Exposures,
      'fallbackRehitExposures': targets.fallbackRehitExposures,
      'fallbackRehitRequiresSeparateDays':
          targets.fallbackRehitRequiresSeparateDays,
      'baseAerobicRollingWindowDays':
          targets.baseAerobicRollingWindowDays,
      'baseLongExposureCount': targets.baseLongExposureCount,
      'baseLongExposureMinutes': targets.baseLongExposureMinutes,
      'baseShortExposureCount': targets.baseShortExposureCount,
      'baseShortExposureMinutes': targets.baseShortExposureMinutes,
    };

TrainingTargets trainingTargetsFromJson(Map<String, dynamic> j) {
  final defaults = TrainingTargets();
  final bandsJson = j['hypertrophyTargetBands'] as Map?;
  final bands = <MajorMuscleGroup, EffectiveSetTargetBand>{
    ...defaults.hypertrophyTargetBands,
    if (bandsJson != null)
      ...bandsJson.map(
        (key, value) => MapEntry(
          MajorMuscleGroup.values.byName(key as String),
          effectiveSetTargetBandFromJson(
            (value as Map).cast<String, dynamic>(),
          ),
        ),
      ),
  };

  return TrainingTargets(
    hardTimeWindowsMinutes:
        (j['hardTimeWindowsMinutes'] as List?)?.cast<int>() ??
            defaults.hardTimeWindowsMinutes,
    hypertrophyTargetBands: bands,
    hypertrophyEvaluationWindowDays:
        j['hypertrophyEvaluationWindowDays'] as int? ??
            defaults.hypertrophyEvaluationWindowDays,
    intensityRollingWindowDays:
        j['intensityRollingWindowDays'] as int? ??
            defaults.intensityRollingWindowDays,
    preferredNorwegian4x4Exposures:
        j['preferredNorwegian4x4Exposures'] as int? ??
            defaults.preferredNorwegian4x4Exposures,
    fallbackRehitExposures: j['fallbackRehitExposures'] as int? ??
        defaults.fallbackRehitExposures,
    fallbackRehitRequiresSeparateDays:
        j['fallbackRehitRequiresSeparateDays'] as bool? ??
            defaults.fallbackRehitRequiresSeparateDays,
    baseAerobicRollingWindowDays:
        j['baseAerobicRollingWindowDays'] as int? ??
            defaults.baseAerobicRollingWindowDays,
    baseLongExposureCount: j['baseLongExposureCount'] as int? ??
        defaults.baseLongExposureCount,
    baseLongExposureMinutes: j['baseLongExposureMinutes'] as int? ??
        defaults.baseLongExposureMinutes,
    baseShortExposureCount: j['baseShortExposureCount'] as int? ??
        defaults.baseShortExposureCount,
    baseShortExposureMinutes:
        (j['baseShortExposureMinutes'] as List?)?.cast<int>() ??
            defaults.baseShortExposureMinutes,
  );
}

Map<String, dynamic> muscleTrainingStatusToJson(
  MuscleTrainingStatus status,
) =>
    {
      'muscleGroup': status.muscleGroup.name,
      'completedEffectiveSets': status.completedEffectiveSets,
      'minimumTargetEffectiveSets': status.minimumTargetEffectiveSets,
      'centerTargetEffectiveSets': status.centerTargetEffectiveSets,
      'maximumTargetEffectiveSets': status.maximumTargetEffectiveSets,
      'deficitToMinimumEffectiveSets':
          status.deficitToMinimumEffectiveSets,
    };

MuscleTrainingStatus muscleTrainingStatusFromJson(Map<String, dynamic> j) =>
    MuscleTrainingStatus(
      muscleGroup:
          MajorMuscleGroup.values.byName(j['muscleGroup'] as String),
      completedEffectiveSets:
          (j['completedEffectiveSets'] as num).toDouble(),
      minimumTargetEffectiveSets:
          (j['minimumTargetEffectiveSets'] as num).toDouble(),
      centerTargetEffectiveSets:
          (j['centerTargetEffectiveSets'] as num).toDouble(),
      maximumTargetEffectiveSets:
          (j['maximumTargetEffectiveSets'] as num).toDouble(),
      deficitToMinimumEffectiveSets:
          (j['deficitToMinimumEffectiveSets'] as num).toDouble(),
    );

Map<String, dynamic> aerobicTrainingStatusToJson(
  AerobicTrainingStatus status,
) =>
    {
      'target': status.target.name,
      'rollingWindowDays': status.rollingWindowDays,
      'completedExposures': status.completedExposures,
      'targetExposures': status.targetExposures,
      'exposureDeficit': status.exposureDeficit,
      'completedDistinctDays': status.completedDistinctDays,
      'targetDistinctDays': status.targetDistinctDays,
      'distinctDayDeficit': status.distinctDayDeficit,
    };

AerobicTrainingStatus aerobicTrainingStatusFromJson(
  Map<String, dynamic> j,
) =>
    AerobicTrainingStatus(
      target: AerobicTargetKind.values.byName(j['target'] as String),
      rollingWindowDays: j['rollingWindowDays'] as int,
      completedExposures: j['completedExposures'] as int,
      targetExposures: j['targetExposures'] as int,
      exposureDeficit: j['exposureDeficit'] as int,
      completedDistinctDays: j['completedDistinctDays'] as int? ?? 0,
      targetDistinctDays: j['targetDistinctDays'] as int? ?? 0,
      distinctDayDeficit: j['distinctDayDeficit'] as int? ?? 0,
    );

Map<String, dynamic> trainingStatusToJson(TrainingStatus status) => {
      'asOf': status.asOf.toIso8601String(),
      'muscleEvaluationWindowDays': status.muscleEvaluationWindowDays,
      'muscle': status.muscle.map(muscleTrainingStatusToJson).toList(),
      'aerobic': status.aerobic.map(aerobicTrainingStatusToJson).toList(),
    };

TrainingStatus trainingStatusFromJson(Map<String, dynamic> j) =>
    TrainingStatus(
      asOf: DateTime.parse(j['asOf'] as String),
      muscleEvaluationWindowDays: j['muscleEvaluationWindowDays'] as int,
      muscle: (j['muscle'] as List)
          .map(
            (item) => muscleTrainingStatusFromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList(),
      aerobic: (j['aerobic'] as List)
          .map(
            (item) => aerobicTrainingStatusFromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList(),
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
