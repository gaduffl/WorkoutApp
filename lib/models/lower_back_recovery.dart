/// Dose stages of the optional back-extension exercise. They never reach a
/// deadlift on their own; the hinge slot is owned by [BackRebuildStage].
enum LowerBackRecoveryStage {
  isometricHold,
  dynamicUnloaded,

  /// Legacy value from the retired extension-led re-entry. Read as the top
  /// unloaded dose; it never prescribes a loaded hinge.
  deadliftReentry,
}

enum LowerBackSymptomResponse {
  better,
  unchanged,
  worse,
}

/// The stages of Back rebuild's hinge and squat slots. Bent-over rows,
/// standing presses and L-sits swap to stand-ins that spare the lower back;
/// everything else follows the normal plan.
enum BackRebuildStage {
  /// Floor glute bridges, sliding hamstring curls and split squats.
  bridges,

  /// Deadlift from blocks (50–70%) and goblet squat to a box (60–80%).
  blockDeadlift,

  /// Romanian deadlift (70–100%) and goblet squat (80–100%).
  romanianDeadlift,
}

/// Stepped return to stationary cycling. Each step opens after a
/// same-or-better next morning following the previous step's exposure.
enum BikeReturnStep {
  /// Zone 2 is an uphill walk; the next step needs an easy test ride.
  walkOnly,

  /// Zone 2 rides are planned; 4×4 needs a 30-minute ride first.
  zone2Ride,

  /// 4×4 intervals are planned; REHIT, finishers and nudges stay closed.
  fourByFour,

  /// All cycling is available again.
  complete,
}

/// Hinge-slot work completed in a rebuild session that awaits its
/// next-morning check.
enum BackRebuildExposure { none, accessory, loaded }

/// Bike work awaiting its next-morning check, ordered by dose.
enum BikeExposure { none, easyRide, zone2Ride, fourByFour, rehit }

const lowerBackRecoveryTrackKey =
    'recovery:lower_back:back_extension';

/// Persisted state for Back rebuild (formerly "lower-back recovery mode").
///
/// This describes training modifications and observed symptom response. It is
/// deliberately not a diagnosis or a claim that a particular tissue healed.
class LowerBackRecoveryState {
  final bool active;
  final DateTime? activatedAt;
  final DateTime? completedAt;
  final DateTime? symptomOnsetDate;
  final DateTime? neurologicalSymptomsAbsentConfirmedAt;

  /// Optional back-extension dose stage.
  final LowerBackRecoveryStage stage;
  final int targetHoldSeconds;
  final int targetDynamicReps;

  /// Consecutive tolerated back-extension exposures (extension dose only).
  final int consecutiveToleratedSessions;

  /// Calendar dates of spaced rebuild exposures: loaded hinge steps and
  /// optional back extensions. Used for the 48-hour and
  /// twice-per-rolling-week caps.
  final List<DateTime> recoverySessionDates;

  /// A rebuild exposure cannot affect any stage until its next-morning
  /// response has been recorded.
  final DateTime? pendingNextMorningSessionDate;

  /// Set to [LowerBackSymptomResponse.worse] when rebuild work was
  /// pain-flagged in the logger. There is no separate same-day question.
  final LowerBackSymptomResponse? pendingSameDayResponse;
  final LowerBackSymptomResponse? lastNextMorningResponse;

  /// Snapshot of the normal hinge prescription at activation. The normal
  /// hinge ladder stays frozen while [active]; stage loads derive from this.
  final double? preRecoveryHingeLoad;
  final int? preRecoveryHingeLadderStepIndex;
  final double? lastReentryLoad;

  final BackRebuildStage rebuildStage;

  /// Consecutive same-or-better next mornings counted for the current
  /// stage (after stage work; loaded work in stages 2–3).
  final int rebuildGoodMornings;

  /// Independent of [active]: the bike return can still be in progress after
  /// the hinge stages finish. Profiles that never used Back rebuild default
  /// to [BikeReturnStep.complete].
  final BikeReturnStep bikeReturnStep;

  final BackRebuildExposure pendingRebuildExposure;
  final bool pendingExtensionExposure;
  final BikeExposure pendingBikeExposure;

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
    this.rebuildStage = BackRebuildStage.bridges,
    this.rebuildGoodMornings = 0,
    this.bikeReturnStep = BikeReturnStep.complete,
    this.pendingRebuildExposure = BackRebuildExposure.none,
    this.pendingExtensionExposure = false,
    this.pendingBikeExposure = BikeExposure.none,
  });

  bool get awaitingNextMorningResponse =>
      pendingNextMorningSessionDate != null;

  bool get bikeReturnInProgress => bikeReturnStep != BikeReturnStep.complete;

  /// 1-based stage number shown to the user.
  int get rebuildStageNumber => rebuildStage.index + 1;

  static const rebuildStageCount = 3;

  String get rebuildStageTitle => switch (rebuildStage) {
        BackRebuildStage.bridges =>
          'Bridges, hamstring curls & split squats',
        BackRebuildStage.blockDeadlift =>
          'Deadlift from blocks & squat to a box',
        BackRebuildStage.romanianDeadlift =>
          'Romanian deadlift & goblet squat',
      };

  String get bikeReturnLabel => switch (bikeReturnStep) {
        BikeReturnStep.walkOnly =>
          'Bike: test with a 15-min easy ride, sitting upright (log it as a Zone 2 ride)',
        BikeReturnStep.zone2Ride =>
          'Bike: Zone 2 rides are back; 4×4 opens after a 30-min ride',
        BikeReturnStep.fourByFour =>
          'Bike: 4×4 is back; REHIT opens after a 4×4',
        BikeReturnStep.complete => 'Bike: all cycling is back',
      };

  String get stageLabel => switch (stage) {
        LowerBackRecoveryStage.isometricHold =>
          'Back extensions · static holds',
        LowerBackRecoveryStage.dynamicUnloaded ||
        LowerBackRecoveryStage.deadliftReentry =>
          'Back extensions · controlled unweighted reps',
      };

  String get targetLabel => switch (stage) {
        LowerBackRecoveryStage.isometricHold =>
          '3 × $targetHoldSeconds-second holds',
        LowerBackRecoveryStage.dynamicUnloaded ||
        LowerBackRecoveryStage.deadliftReentry =>
          '2 × $targetDynamicReps controlled repetitions',
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
    BackRebuildStage? rebuildStage,
    int? rebuildGoodMornings,
    BikeReturnStep? bikeReturnStep,
    BackRebuildExposure? pendingRebuildExposure,
    bool? pendingExtensionExposure,
    BikeExposure? pendingBikeExposure,
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
        rebuildStage: rebuildStage ?? this.rebuildStage,
        rebuildGoodMornings: rebuildGoodMornings ?? this.rebuildGoodMornings,
        bikeReturnStep: bikeReturnStep ?? this.bikeReturnStep,
        pendingRebuildExposure: clearPendingResponse
            ? BackRebuildExposure.none
            : pendingRebuildExposure ?? this.pendingRebuildExposure,
        pendingExtensionExposure: clearPendingResponse
            ? false
            : pendingExtensionExposure ?? this.pendingExtensionExposure,
        pendingBikeExposure: clearPendingResponse
            ? BikeExposure.none
            : pendingBikeExposure ?? this.pendingBikeExposure,
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
          other.lastReentryLoad == lastReentryLoad &&
          other.rebuildStage == rebuildStage &&
          other.rebuildGoodMornings == rebuildGoodMornings &&
          other.bikeReturnStep == bikeReturnStep &&
          other.pendingRebuildExposure == pendingRebuildExposure &&
          other.pendingExtensionExposure == pendingExtensionExposure &&
          other.pendingBikeExposure == pendingBikeExposure;

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
        rebuildStage,
        rebuildGoodMornings,
        bikeReturnStep,
        pendingRebuildExposure,
        pendingExtensionExposure,
        pendingBikeExposure,
      ]);

  static bool _sameDates(List<DateTime> a, List<DateTime> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
