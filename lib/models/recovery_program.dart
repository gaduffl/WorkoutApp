import 'pain.dart';

enum RecoveryPhase { flareUp, rebuild, hingeReturn, returnToTraining }
enum RecoveryFunction { better, unchanged, worse }
enum RecoveryExercise {
  abdominalActivation, floorPress, supportedRow, curl, lateralRaise,
  pullUp, dip, gluteBridge, hamstringCurl, extensionHold, deadlift,
}

extension RecoveryExerciseLabel on RecoveryExercise {
  String get label => switch (this) {
    RecoveryExercise.abdominalActivation => 'Gentle abdominal activation',
    RecoveryExercise.floorPress => 'Supported DB floor press',
    RecoveryExercise.supportedRow => 'Chest-supported DB row',
    RecoveryExercise.curl => 'Supported DB curl',
    RecoveryExercise.lateralRaise => 'Supported lateral raise',
    RecoveryExercise.pullUp => 'Assisted pull-up',
    RecoveryExercise.dip => 'Bodyweight dip',
    RecoveryExercise.gluteBridge => 'Floor glute bridge',
    RecoveryExercise.hamstringCurl => 'Sliding hamstring curl',
    RecoveryExercise.extensionHold => 'Near-neutral back-extension hold',
    RecoveryExercise.deadlift => 'Limited-range elevated-start deadlift',
  };
  bool get timed => this == RecoveryExercise.abdominalActivation ||
      this == RecoveryExercise.extensionHold;
  bool get loaded => const {
    RecoveryExercise.floorPress, RecoveryExercise.supportedRow,
    RecoveryExercise.curl, RecoveryExercise.lateralRaise,
    RecoveryExercise.gluteBridge, RecoveryExercise.deadlift,
  }.contains(this);
  bool get needsAssessment => this == RecoveryExercise.extensionHold ||
      this == RecoveryExercise.deadlift;
  String get trackKey => 'recovery:v2:$name';
}

class RecoveryDose {
  final int reps;
  final double load;
  final int rangePercent;
  const RecoveryDose({this.reps = 5, this.load = 0, this.rangePercent = 50});
  Map<String, dynamic> toJson() => {
    'reps': reps, 'load': load, 'rangePercent': rangePercent,
  };
  factory RecoveryDose.fromJson(Map<String, dynamic> json) => RecoveryDose(
    reps: ((json['reps'] as num?)?.toInt() ?? 5).clamp(3, 12),
    load: ((json['load'] as num?)?.toDouble() ?? 0).clamp(0, 200),
    rangePercent: ((json['rangePercent'] as num?)?.toInt() ?? 50).clamp(10, 100),
  );
}

class RecoveryObservation {
  final DateTime date;
  final int pain;
  final int sittingMinutes;
  final RecoveryFunction function;
  /// Includes symptoms that occurred and resolved since the previous check-in.
  final Set<PainTag> symptoms;
  final bool delayedWorse;
  final bool nextMorningWorse;
  final Set<RecoveryExercise> provoking;
  const RecoveryObservation({
    required this.date, required this.pain, required this.sittingMinutes,
    required this.function, this.symptoms = const {},
    this.delayedWorse = false, this.nextMorningWorse = false,
    this.provoking = const {},
  });
  bool get worse => delayedWorse || nextMorningWorse ||
      function == RecoveryFunction.worse;
  bool get urgent => symptoms.any(const {
    PainTag.weakness, PainTag.saddleNumbness, PainTag.bladderBowelChange,
  }.contains);
  Map<String, dynamic> toJson() => {
    'date': date.toIso8601String(), 'pain': pain,
    'sittingMinutes': sittingMinutes, 'function': function.name,
    'symptoms': symptoms.map((s) => s.name).toList(),
    'delayedWorse': delayedWorse, 'nextMorningWorse': nextMorningWorse,
    'provoking': provoking.map((e) => e.name).toList(),
  };
  factory RecoveryObservation.fromJson(Map<String, dynamic> j) => RecoveryObservation(
    date: DateTime.parse(j['date'] as String),
    pain: ((j['pain'] as num?)?.toInt() ?? 0).clamp(0, 10),
    sittingMinutes: ((j['sittingMinutes'] as num?)?.toInt() ?? 0).clamp(0, 1440),
    function: _enum(RecoveryFunction.values, j['function'], RecoveryFunction.unchanged),
    symptoms: PainTag.values.where((v) => (j['symptoms'] as List? ?? []).contains(v.name)).toSet(),
    delayedWorse: j['delayedWorse'] == true,
    nextMorningWorse: j['nextMorningWorse'] == true,
    provoking: RecoveryExercise.values.where((v) => (j['provoking'] as List? ?? []).contains(v.name)).toSet(),
  );
}

/// Training state, not a diagnosis, clearance, or a tissue-healing estimate.
class RecoveryProgram {
  final RecoveryPhase phase;
  final bool bikePaused;
  final bool reviewRequired;
  final DateTime? assessedAt;
  final DateTime? flareAt;
  final List<RecoveryObservation> observations;
  final Set<RecoveryExercise> selected;
  final Set<RecoveryExercise> pausedExercises;
  final Map<RecoveryExercise, RecoveryDose> doses;
  final DateTime? pendingSession;
  final bool pendingCompleteDose;
  final bool pendingWorse;
  final Set<RecoveryExercise> pendingExercises;
  final int toleratedExposures;
  final List<DateTime> sessions;

  const RecoveryProgram({
    this.phase = RecoveryPhase.flareUp, this.bikePaused = true,
    this.reviewRequired = false, this.assessedAt, this.flareAt,
    this.observations = const [],
    this.selected = const {RecoveryExercise.abdominalActivation},
    this.pausedExercises = const {}, this.doses = const {},
    this.pendingSession, this.pendingCompleteDose = false,
    this.pendingWorse = false, this.pendingExercises = const {},
    this.toleratedExposures = 0, this.sessions = const [],
  });
  RecoveryObservation? get latest => observations.isEmpty ? null : observations.last;
  String get phaseLabel => switch (phase) {
    RecoveryPhase.flareUp => 'Phase 1 · settle the flare-up',
    RecoveryPhase.rebuild => 'Phase 2 · rebuild exercise tolerance',
    RecoveryPhase.hingeReturn => 'Phase 3 · return to hinging or alternatives',
    RecoveryPhase.returnToTraining => 'Phase 4 · gradual return to training',
  };
  RecoveryDose dose(RecoveryExercise exercise) => doses[exercise] ?? const RecoveryDose();
  bool checkedToday(DateTime date) => latest != null && sameRecoveryDay(latest!.date, date);
  bool get trainingBlocked => reviewRequired || latest?.symptoms.isNotEmpty == true;

  RecoveryProgram copyWith({
    RecoveryPhase? phase, bool? bikePaused, bool? reviewRequired,
    DateTime? assessedAt, bool clearAssessment = false, DateTime? flareAt,
    List<RecoveryObservation>? observations, Set<RecoveryExercise>? selected,
    Set<RecoveryExercise>? pausedExercises, Map<RecoveryExercise, RecoveryDose>? doses,
    DateTime? pendingSession, bool clearPending = false,
    bool? pendingCompleteDose, bool? pendingWorse,
    Set<RecoveryExercise>? pendingExercises, int? toleratedExposures,
    List<DateTime>? sessions,
  }) => RecoveryProgram(
    phase: phase ?? this.phase, bikePaused: bikePaused ?? this.bikePaused,
    reviewRequired: reviewRequired ?? this.reviewRequired,
    assessedAt: clearAssessment ? null : assessedAt ?? this.assessedAt,
    flareAt: flareAt ?? this.flareAt, observations: observations ?? this.observations,
    selected: selected ?? this.selected, pausedExercises: pausedExercises ?? this.pausedExercises,
    doses: doses ?? this.doses,
    pendingSession: clearPending ? null : pendingSession ?? this.pendingSession,
    pendingCompleteDose: clearPending ? false : pendingCompleteDose ?? this.pendingCompleteDose,
    pendingWorse: clearPending ? false : pendingWorse ?? this.pendingWorse,
    pendingExercises: clearPending ? const {} : pendingExercises ?? this.pendingExercises,
    toleratedExposures: toleratedExposures ?? this.toleratedExposures,
    sessions: sessions ?? this.sessions,
  );
  Map<String, dynamic> toJson() => {
    'version': 2, 'phase': phase.name, 'bikePaused': bikePaused,
    'reviewRequired': reviewRequired, 'assessedAt': assessedAt?.toIso8601String(),
    'flareAt': flareAt?.toIso8601String(),
    'observations': observations.map((o) => o.toJson()).toList(),
    'selected': selected.map((e) => e.name).toList(),
    'pausedExercises': pausedExercises.map((e) => e.name).toList(),
    'doses': {for (final entry in doses.entries) entry.key.name: entry.value.toJson()},
    'pendingSession': pendingSession?.toIso8601String(),
    'pendingCompleteDose': pendingCompleteDose, 'pendingWorse': pendingWorse,
    'pendingExercises': pendingExercises.map((e) => e.name).toList(),
    'toleratedExposures': toleratedExposures,
    'sessions': sessions.map((d) => d.toIso8601String()).toList(),
  };
  factory RecoveryProgram.fromJson(Map<String, dynamic> j) {
    Set<RecoveryExercise> choices(String key) => RecoveryExercise.values
        .where((v) => (j[key] as List? ?? []).contains(v.name)).toSet();
    return RecoveryProgram(
      phase: _enum(RecoveryPhase.values, j['phase'], RecoveryPhase.flareUp),
      bikePaused: j['bikePaused'] as bool? ?? true,
      reviewRequired: j['reviewRequired'] == true,
      assessedAt: DateTime.tryParse(j['assessedAt']?.toString() ?? ''),
      flareAt: DateTime.tryParse(j['flareAt']?.toString() ?? ''),
      observations: (j['observations'] as List? ?? []).whereType<Map>()
          .map((o) => RecoveryObservation.fromJson(o.cast<String, dynamic>())).toList(),
      selected: j.containsKey('selected') ? choices('selected') : const {RecoveryExercise.abdominalActivation},
      pausedExercises: choices('pausedExercises'),
      doses: {for (final e in RecoveryExercise.values)
        if ((j['doses'] as Map?)?[e.name] is Map)
          e: RecoveryDose.fromJson(((j['doses'] as Map)[e.name] as Map).cast<String, dynamic>())},
      pendingSession: DateTime.tryParse(j['pendingSession']?.toString() ?? ''),
      pendingCompleteDose: j['pendingCompleteDose'] == true,
      pendingWorse: j['pendingWorse'] == true, pendingExercises: choices('pendingExercises'),
      toleratedExposures: (j['toleratedExposures'] as num?)?.toInt() ?? 0,
      sessions: (j['sessions'] as List? ?? []).map((d) => DateTime.parse(d as String)).toList(),
    );
  }
}

T _enum<T extends Enum>(List<T> values, Object? raw, T fallback) =>
    values.where((v) => v.name == raw).firstOrNull ?? fallback;
bool sameRecoveryDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
