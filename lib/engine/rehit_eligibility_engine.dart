import '../models/daily_nudge.dart';
import '../models/decision_trace.dart';
import '../models/session_log.dart';
import 'intensity_recovery_policy.dart';

/// Why an optional later-day REHIT is not currently safe or applicable.
///
/// The values are deliberately granular so the UI and notification layer can
/// consume the same decision without independently rebuilding safety logic.
enum RehitClosedReason {
  readinessNotGreen,
  illnessGuardActive,
  noFirstSession,
  firstSessionNotCompleted,
  firstSessionNotStrength,
  firstSessionBelowMinimumCompletion,
  firstSessionPainEvent,
  firstSessionEarlyAbort,
  contraindicatingPainActive,
  painEscalationActive,
  globalDeloadActive,
  patternDeloadActive,
  intensityWithinTrailing48Hours,
  rehitAlreadyCompletedToday,
  rehitUnavailableDueToTravel,
  highIntensityTargetMet,
}

/// Facts from the first workout persisted today.
///
/// Warm-up sets must not be included in either set count. An empty strength
/// prescription deliberately fails closed.
class RehitFirstSessionFacts {
  final bool completed;
  final bool qualifiesAsStrength;
  final int plannedWorkSets;
  final int completedWorkSets;
  final bool hadPainEvent;
  final bool earlyAbort;

  const RehitFirstSessionFacts({
    required this.completed,
    required this.qualifiesAsStrength,
    required this.plannedWorkSets,
    required this.completedWorkSets,
    this.hadPainEvent = false,
    this.earlyAbort = false,
  });

  /// Integer arithmetic makes an exact 50% completion qualify without
  /// rounding error.
  bool get meetsMinimumCompletion =>
      plannedWorkSets > 0 &&
      completedWorkSets >= 0 &&
      completedWorkSets * 2 >= plannedWorkSets;
}

/// All current facts needed to decide whether to offer a second-session
/// REHIT. The caller supplies one device-local clock snapshot.
class RehitEligibilityInput {
  final ReadinessBucket readinessBucket;
  final bool illnessGuardActive;
  final RehitFirstSessionFacts? firstSession;
  final bool contraindicatingPainActive;
  final bool painEscalationActive;
  final bool globalDeloadActive;
  final bool patternDeloadActive;

  /// Persisted sessions available to the shared recovery policy. Target and
  /// queue credit are intentionally not pre-filtered by callers.
  final List<SessionLog> sessionLogsForRecovery;

  /// Explicit same-day duplicate guard. This remains authoritative if a
  /// caller's recent-log cache has not yet refreshed.
  final bool rehitAlreadyCompletedToday;

  /// True when the current travel/no-equipment mode makes the CAROL bike
  /// unavailable.
  final bool rehitUnavailableDueToTravel;

  /// Optional REHIT is a target-completion aid, never a fourth natural
  /// high-intensity day in the rolling window.
  final bool highIntensityTargetDue;

  /// Device-local wall-clock observation used by the rolling window and the
  /// once-only later-day nudge.
  final DateTime nowLocal;

  /// A target at or after this local hour is suppressed.
  final int nudgeCutoffHour;

  const RehitEligibilityInput({
    required this.readinessBucket,
    required this.illnessGuardActive,
    required this.firstSession,
    required this.contraindicatingPainActive,
    required this.painEscalationActive,
    required this.globalDeloadActive,
    required this.patternDeloadActive,
    required this.sessionLogsForRecovery,
    required this.rehitAlreadyCompletedToday,
    required this.nowLocal,
    this.rehitUnavailableDueToTravel = false,
    this.highIntensityTargetDue = true,
    this.nudgeCutoffHour = 20,
  }) : assert(nudgeCutoffHour >= 0 && nudgeCutoffHour <= 23);
}

class RehitEligibilityResult implements DailyNudgeEligibility {
  final List<RehitClosedReason> closedReasons;

  /// Exact local time at which this shared result was evaluated.
  @override
  final DateTime observedAt;

  /// Null when unsafe/inapplicable or when the otherwise-eligible target
  /// would land at/after the local nudge cutoff.
  @override
  final DateTime? suggestedNudgeTime;

  const RehitEligibilityResult({
    required this.closedReasons,
    required this.observedAt,
    required this.suggestedNudgeTime,
  });

  @override
  bool get eligible => closedReasons.isEmpty;
}

/// Pure safety and recovery gate for the optional later-day REHIT.
class RehitEligibilityEngine {
  const RehitEligibilityEngine();

  static const intensityRecoveryPolicy = IntensityRecoveryPolicy();

  RehitEligibilityResult evaluate(RehitEligibilityInput input) {
    final reasons = <RehitClosedReason>[];

    if (input.readinessBucket != ReadinessBucket.green) {
      reasons.add(RehitClosedReason.readinessNotGreen);
    }
    if (input.illnessGuardActive) {
      reasons.add(RehitClosedReason.illnessGuardActive);
    }

    final firstSession = input.firstSession;
    if (firstSession == null) {
      reasons.add(RehitClosedReason.noFirstSession);
    } else {
      if (!firstSession.completed) {
        reasons.add(RehitClosedReason.firstSessionNotCompleted);
      }
      if (!firstSession.qualifiesAsStrength) {
        reasons.add(RehitClosedReason.firstSessionNotStrength);
      }
      if (!firstSession.meetsMinimumCompletion) {
        reasons.add(RehitClosedReason.firstSessionBelowMinimumCompletion);
      }
      if (firstSession.hadPainEvent) {
        reasons.add(RehitClosedReason.firstSessionPainEvent);
      }
      if (firstSession.earlyAbort) {
        reasons.add(RehitClosedReason.firstSessionEarlyAbort);
      }
    }

    if (input.contraindicatingPainActive) {
      reasons.add(RehitClosedReason.contraindicatingPainActive);
    }
    if (input.painEscalationActive) {
      reasons.add(RehitClosedReason.painEscalationActive);
    }
    if (input.globalDeloadActive) {
      reasons.add(RehitClosedReason.globalDeloadActive);
    }
    if (input.patternDeloadActive) {
      reasons.add(RehitClosedReason.patternDeloadActive);
    }
    if (intensityRecoveryPolicy.hasRelevantIntensityInInclusiveWindow(
      input.sessionLogsForRecovery,
      asOf: input.nowLocal,
    )) {
      reasons.add(RehitClosedReason.intensityWithinTrailing48Hours);
    }
    if (input.rehitAlreadyCompletedToday) {
      reasons.add(RehitClosedReason.rehitAlreadyCompletedToday);
    }
    if (input.rehitUnavailableDueToTravel) {
      reasons.add(RehitClosedReason.rehitUnavailableDueToTravel);
    }
    if (!input.highIntensityTargetDue) {
      reasons.add(RehitClosedReason.highIntensityTargetMet);
    }

    return RehitEligibilityResult(
      closedReasons: List.unmodifiable(reasons),
      observedAt: input.nowLocal,
      suggestedNudgeTime: reasons.isEmpty
          ? _suggestedNudgeTime(
              input.nowLocal,
              cutoffHour: input.nudgeCutoffHour,
            )
          : null,
    );
  }

  /// Use 15:00 or three hours after eligibility is observed, whichever is
  /// later. A target exactly at the daily cutoff is suppressed.
  DateTime? _suggestedNudgeTime(DateTime now, {required int cutoffHour}) {
    final atThree = DateTime(now.year, now.month, now.day, 15);
    final threeHoursLater = now.add(const Duration(hours: 3));
    final target = threeHoursLater.isAfter(atThree) ? threeHoursLater : atThree;
    final cutoff = DateTime(now.year, now.month, now.day, cutoffHour);
    return target.isBefore(cutoff) ? target : null;
  }
}
