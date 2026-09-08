/// Persisted state for the dedicated lower-back recovery mode.
///
/// This describes training modifications and observed symptom response. It is
/// deliberately not a diagnosis or a claim that a particular tissue healed.
enum LowerBackRecoveryStage {
  isometricHold,
  dynamicUnloaded,
  deadliftReentry,
}
enum LowerBackSymptomResponse {
  better,
  unchanged,
  worse,
}

const lowerBackRecoveryTrackKey =
    'recovery:lower_back:back_extension';

class LowerBackRecoveryState {
  final bool active;
  final DateTime? activatedAt;
  final DateTime? completedAt;
  final DateTime? symptomOnsetDate;
  final DateTime? neurologicalSymptomsAbsentConfirmedAt;
  final LowerBackRecoveryStage stage;
  final int targetHoldSeconds;
  final int targetDynamicReps;
  final int consecutiveToleratedSessions;

  /// Calendar dates on which recovery work was actually completed. The
  /// engine uses these for the 48-hour and twice-per-rolling-week caps.
  final List<DateTime> recoverySessionDates;

  /// A recovery session cannot affect the dose until its next-morning
  /// response has been recorded.
  final DateTime? pendingNextMorningSessionDate;
  final LowerBackSymptomResponse? pendingSameDayResponse;
  final LowerBackSymptomResponse? lastNextMorningResponse;

  /// Snapshot of the normal hinge prescription at activation. Loaded hinge
  /// work stays frozen while [active]; this snapshot makes the later 50%
  /// re-entry explicit rather than deriving it from unrelated substitutes.
  final double? preRecoveryHingeLoad;
  final int? preRecoveryHingeLadderStepIndex;
  final double? lastReentryLoad;

  const LowerBackRecoveryState({
    this.active = false,
    this.activatedAt,
    this.completedAt,
    this.symptomOnsetDate,
    this.neurologicalSymptomsAbsentConfirmedAt,
    this.stage = LowerBackRecoveryStage.isometricHold,
    this.targetHoldSeconds = 30,
    this.targetDynamicReps = 6,
    this.consecutiveToleratedSessions = 0,
    this.recoverySessionDates = const [],
    this.pendingNextMorningSessionDate,
    this.pendingSameDayResponse,
    this.lastNextMorningResponse,
    this.preRecoveryHingeLoad,
    this.preRecoveryHingeLadderStepIndex,
    this.lastReentryLoad,
  });

  bool get awaitingNextMorningResponse =>
      pendingNextMorningSessionDate != null;

  String get stageLabel => switch (stage) {
        LowerBackRecoveryStage.isometricHold =>
          'Stage 1 · static back-extension holds',
        LowerBackRecoveryStage.dynamicUnloaded =>
          'Stage 2 · controlled unweighted back extensions',
        LowerBackRecoveryStage.deadliftReentry =>
          'Stage 3 · graded deadlift re-entry',
      };

  String get targetLabel => switch (stage) {
        LowerBackRecoveryStage.isometricHold =>
          '3 × $targetHoldSeconds-second holds',
        LowerBackRecoveryStage.dynamicUnloaded =>
          '2 × $targetDynamicReps controlled repetitions',
        LowerBackRecoveryStage.deadliftReentry =>
          '1 × 8 elevated-start deadlift at 50%',
      };

  LowerBackRecoveryState copyWith({
    bool? active,
    DateTime? activatedAt,
    DateTime? completedAt,
    DateTime? symptomOnsetDate,
    DateTime? neurologicalSymptomsAbsentConfirmedAt,
    LowerBackRecoveryStage? stage,
    int? targetHoldSeconds,
    int? targetDynamicReps,
    int? consecutiveToleratedSessions,
    List<DateTime>? recoverySessionDates,
    DateTime? pendingNextMorningSessionDate,
    LowerBackSymptomResponse? pendingSameDayResponse,
    LowerBackSymptomResponse? lastNextMorningResponse,
    double? preRecoveryHingeLoad,
    int? preRecoveryHingeLadderStepIndex,
    double? lastReentryLoad,
    bool clearCompletedAt = false,
    bool clearPendingResponse = false,
    bool clearLastNextMorningResponse = false,
    bool clearLastReentryLoad = false,
  }) =>
      LowerBackRecoveryState(
        active: active ?? this.active,
        activatedAt: activatedAt ?? this.activatedAt,
        completedAt: clearCompletedAt
            ? null
            : completedAt ?? this.completedAt,
        symptomOnsetDate: symptomOnsetDate ?? this.symptomOnsetDate,
        neurologicalSymptomsAbsentConfirmedAt:
            neurologicalSymptomsAbsentConfirmedAt ??
                this.neurologicalSymptomsAbsentConfirmedAt,
        stage: stage ?? this.stage,
        targetHoldSeconds: targetHoldSeconds ?? this.targetHoldSeconds,
        targetDynamicReps: targetDynamicReps ?? this.targetDynamicReps,
        consecutiveToleratedSessions: consecutiveToleratedSessions ??
            this.consecutiveToleratedSessions,
        recoverySessionDates:
            recoverySessionDates ?? this.recoverySessionDates,
        pendingNextMorningSessionDate: clearPendingResponse
            ? null
            : pendingNextMorningSessionDate ??
                this.pendingNextMorningSessionDate,
        pendingSameDayResponse: clearPendingResponse
            ? null
            : pendingSameDayResponse ?? this.pendingSameDayResponse,
        lastNextMorningResponse: clearLastNextMorningResponse
            ? null
            : lastNextMorningResponse ?? this.lastNextMorningResponse,
        preRecoveryHingeLoad:
            preRecoveryHingeLoad ?? this.preRecoveryHingeLoad,
        preRecoveryHingeLadderStepIndex:
            preRecoveryHingeLadderStepIndex ??
                this.preRecoveryHingeLadderStepIndex,
        lastReentryLoad: clearLastReentryLoad
            ? null
            : lastReentryLoad ?? this.lastReentryLoad,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LowerBackRecoveryState &&
          other.active == active &&
          other.activatedAt == activatedAt &&
          other.completedAt == completedAt &&
          other.symptomOnsetDate == symptomOnsetDate &&
          other.neurologicalSymptomsAbsentConfirmedAt ==
              neurologicalSymptomsAbsentConfirmedAt &&
          other.stage == stage &&
          other.targetHoldSeconds == targetHoldSeconds &&
          other.targetDynamicReps == targetDynamicReps &&
          other.consecutiveToleratedSessions ==
              consecutiveToleratedSessions &&
          _sameDates(other.recoverySessionDates, recoverySessionDates) &&
          other.pendingNextMorningSessionDate ==
              pendingNextMorningSessionDate &&
          other.pendingSameDayResponse == pendingSameDayResponse &&
          other.lastNextMorningResponse == lastNextMorningResponse &&
          other.preRecoveryHingeLoad == preRecoveryHingeLoad &&
          other.preRecoveryHingeLadderStepIndex ==
              preRecoveryHingeLadderStepIndex &&
          other.lastReentryLoad == lastReentryLoad;

  @override
  int get hashCode => Object.hashAll([
        active,
        activatedAt,
        completedAt,
        symptomOnsetDate,
        neurologicalSymptomsAbsentConfirmedAt,
        stage,
        targetHoldSeconds,
        targetDynamicReps,
        consecutiveToleratedSessions,
        ...recoverySessionDates,
        pendingNextMorningSessionDate,
        pendingSameDayResponse,
        lastNextMorningResponse,
        preRecoveryHingeLoad,
        preRecoveryHingeLadderStepIndex,
        lastReentryLoad,
      ]);

  static bool _sameDates(List<DateTime> a, List<DateTime> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
