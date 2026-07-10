import 'movement_pattern.dart';
import 'pain.dart';

/// §6.2 state machine states.
enum ExerciseStatus { progress, hold, regress, deload }

/// §2.4: "ExerciseState (per pattern per user)". Substitutes get their own
/// state, keyed by [trackKey] (see §7.1) rather than sharing the primary
/// pattern's ladder/load — e.g. `sub:hinge:bridge_hamstring_curl`.
class ExerciseState {
  final String trackKey;
  final MovementPattern pattern;
  int ladderStepIndex;
  double currentLoad;
  ExerciseStatus status;
  DateTime? lastTrainedDate;
  int consecutiveHoldCount;

  /// Timestamps of regressions, kept for the rolling 28-day window (§6.3).
  List<DateTime> regressionDates;

  // --- Pain freeze / re-entry (§6.2.4, §7.2) ---
  bool painFrozen;
  PainSeverity? painSeverity;

  /// Region that caused the freeze — needed so the §7.1 substitution keeps
  /// applying on later days when the user doesn't re-tap the body map.
  BodyRegion? painRegion;
  DateTime? painFlaggedDate;
  Set<PainTag> painTags;
  int sessionsScheduledWhileFlagged;

  /// Calendar day on which [sessionsScheduledWhileFlagged] was last
  /// incremented. A recommendation can be recomputed several times (for
  /// example after a same-day session swap), but that still represents one
  /// scheduled session for pain-lifecycle purposes.
  DateTime? lastPainScheduledDate;
  double? prePainLoad;
  int? prePainLadderStepIndex;
  bool painReentryTestOffered;
  bool painReentryTestPassed;

  // --- Deload (§6.3, §6.5) ---
  int deloadSessionsRemaining;
  double? preDeloadLoad;
  int? preDeloadLadderStepIndex;

  /// §6.4 undershoot correction: after a ladder-cap jump, if the first
  /// session at the new step comes in at RIR>=3 across the board, apply
  /// one immediate increment next time rather than waiting for the normal
  /// progress trigger.
  bool awaitingUndershootCheck;

  /// §2.3 micro-progression order between ladder steps, collapsed to a
  /// stage counter: 0 = plain load progression, 1 = +tempo, 2 = +pause,
  /// 3 = +deficit/ROM (next progress trigger advances the ladder step).
  int microStepStage;

  ExerciseState({
    required this.trackKey,
    required this.pattern,
    this.ladderStepIndex = 0,
    this.currentLoad = 0,
    this.status = ExerciseStatus.progress,
    this.lastTrainedDate,
    this.consecutiveHoldCount = 0,
    List<DateTime>? regressionDates,
    this.painFrozen = false,
    this.painSeverity,
    this.painRegion,
    this.painFlaggedDate,
    Set<PainTag>? painTags,
    this.sessionsScheduledWhileFlagged = 0,
    this.lastPainScheduledDate,
    this.prePainLoad,
    this.prePainLadderStepIndex,
    this.painReentryTestOffered = false,
    this.painReentryTestPassed = false,
    this.deloadSessionsRemaining = 0,
    this.preDeloadLoad,
    this.preDeloadLadderStepIndex,
    this.awaitingUndershootCheck = false,
    this.microStepStage = 0,
  })  : regressionDates = regressionDates ?? [],
        painTags = painTags ?? {};

  int regressionCountWithinDays(DateTime asOf, int windowDays) {
    final cutoff = asOf.subtract(Duration(days: windowDays));
    return regressionDates.where((d) => !d.isBefore(cutoff)).length;
  }

  int daysUntrained(DateTime asOf) {
    if (lastTrainedDate == null) return 1 << 30;
    return asOf.difference(lastTrainedDate!).inDays;
  }

  ExerciseState clone() => ExerciseState(
        trackKey: trackKey,
        pattern: pattern,
        ladderStepIndex: ladderStepIndex,
        currentLoad: currentLoad,
        status: status,
        lastTrainedDate: lastTrainedDate,
        consecutiveHoldCount: consecutiveHoldCount,
        regressionDates: List.of(regressionDates),
        painFrozen: painFrozen,
        painSeverity: painSeverity,
        painRegion: painRegion,
        painFlaggedDate: painFlaggedDate,
        painTags: Set.of(painTags),
        sessionsScheduledWhileFlagged: sessionsScheduledWhileFlagged,
        lastPainScheduledDate: lastPainScheduledDate,
        prePainLoad: prePainLoad,
        prePainLadderStepIndex: prePainLadderStepIndex,
        painReentryTestOffered: painReentryTestOffered,
        painReentryTestPassed: painReentryTestPassed,
        deloadSessionsRemaining: deloadSessionsRemaining,
        preDeloadLoad: preDeloadLoad,
        preDeloadLadderStepIndex: preDeloadLadderStepIndex,
        awaitingUndershootCheck: awaitingUndershootCheck,
        microStepStage: microStepStage,
      );
}
