import '../models/daily_nudge.dart';
import '../models/decision_trace.dart';
import '../models/session_log.dart';
import 'intensity_recovery_policy.dart';
import 'schedule_fit_engine.dart';

/// Why a rest-day REHIT reminder is not appropriate right now.
enum RestDayRehitClosedReason {
  /// Something was already trained today — this nudge exists only for days
  /// that would otherwise go entirely unused. The separate second-session
  /// REHIT offer covers days that *did* start with a workout.
  trainingLoggedToday,

  /// A check-in exists today and did not come out GREEN. High intensity on a
  /// YELLOW/RED day is exactly what the readiness gate is for.
  readinessNotGreen,
  illnessGuardActive,
  contraindicatingPainActive,
  painEscalationActive,
  deloadActive,
  intensityWithinTrailing48Hours,
  rehitUnavailableDueToTravel,

  /// The rolling seven-day high-intensity target is already met, so an extra
  /// exposure would be surplus rather than a catch-up.
  highIntensityTargetMet,

  /// No slot fits before the daily cutoff — typically because the reminder
  /// would land too late in the evening.
  noScheduleSlotToday,
}

class RestDayRehitInput {
  /// Any session log persisted today, including supplemental work.
  final bool trainingLoggedToday;

  /// Today's readiness bucket, or null when no check-in has happened yet.
  /// Null is *not* treated as a blocker: a day with no check-in is the
  /// commonest untrained day, and the reminder's job is to invite the
  /// check-in. The app re-runs every gate for real before anything is logged.
  final ReadinessBucket? readinessBucket;
  final bool illnessGuardActive;
  final bool contraindicatingPainActive;
  final bool painEscalationActive;
  final bool deloadActive;
  final bool intensityWithinTrailingWindow;
  final bool rehitUnavailableDueToTravel;
  final bool highIntensityTargetDue;

  /// The slot the schedule engine proposed for today, if any.
  final ScheduleSlot? scheduleSlot;
  final DateTime nowLocal;

  const RestDayRehitInput({
    required this.trainingLoggedToday,
    required this.readinessBucket,
    required this.illnessGuardActive,
    required this.contraindicatingPainActive,
    required this.painEscalationActive,
    required this.deloadActive,
    required this.intensityWithinTrailingWindow,
    required this.rehitUnavailableDueToTravel,
    required this.highIntensityTargetDue,
    required this.scheduleSlot,
    required this.nowLocal,
  });
}

class RestDayRehitResult implements DailyNudgeEligibility {
  final List<RestDayRehitClosedReason> closedReasons;

  @override
  final DateTime observedAt;

  @override
  final DateTime? suggestedNudgeTime;

  /// Where the suggested time came from, so the reminder can say "your usual
  /// Thursday slot" only when that is true.
  final ScheduleSlotSource? slotSource;

  /// True when the day has no check-in yet — the reminder then asks for a
  /// check-in first instead of asserting the session is safe.
  final bool checkInMissing;

  const RestDayRehitResult({
    required this.closedReasons,
    required this.observedAt,
    required this.suggestedNudgeTime,
    required this.slotSource,
    required this.checkInMissing,
  });

  @override
  bool get eligible => closedReasons.isEmpty;
}

/// Decides whether a day with no training so far deserves a short-REHIT
/// reminder, and when it would fit.
///
/// The safety gates mirror the second-session REHIT engine exactly; only the
/// day-shape conditions differ (no first session instead of a completed one,
/// plus a schedule fit).
class RestDayRehitEngine {
  const RestDayRehitEngine();

  static const intensityRecoveryPolicy = IntensityRecoveryPolicy();

  RestDayRehitResult evaluate(RestDayRehitInput input) {
    final reasons = <RestDayRehitClosedReason>[];

    if (input.trainingLoggedToday) {
      reasons.add(RestDayRehitClosedReason.trainingLoggedToday);
    }
    if (input.readinessBucket != null &&
        input.readinessBucket != ReadinessBucket.green) {
      reasons.add(RestDayRehitClosedReason.readinessNotGreen);
    }
    if (input.illnessGuardActive) {
      reasons.add(RestDayRehitClosedReason.illnessGuardActive);
    }
    if (input.contraindicatingPainActive) {
      reasons.add(RestDayRehitClosedReason.contraindicatingPainActive);
    }
    if (input.painEscalationActive) {
      reasons.add(RestDayRehitClosedReason.painEscalationActive);
    }
    if (input.deloadActive) {
      reasons.add(RestDayRehitClosedReason.deloadActive);
    }
    if (input.intensityWithinTrailingWindow) {
      reasons.add(RestDayRehitClosedReason.intensityWithinTrailing48Hours);
    }
    if (input.rehitUnavailableDueToTravel) {
      reasons.add(RestDayRehitClosedReason.rehitUnavailableDueToTravel);
    }
    if (!input.highIntensityTargetDue) {
      reasons.add(RestDayRehitClosedReason.highIntensityTargetMet);
    }
    if (input.scheduleSlot == null) {
      reasons.add(RestDayRehitClosedReason.noScheduleSlotToday);
    }

    final open = reasons.isEmpty;
    return RestDayRehitResult(
      closedReasons: List.unmodifiable(reasons),
      observedAt: input.nowLocal,
      suggestedNudgeTime: open ? input.scheduleSlot!.at : null,
      slotSource: open ? input.scheduleSlot!.source : null,
      checkInMissing: input.readinessBucket == null,
    );
  }

  /// Convenience over the shared safety policy, so callers do not rebuild the
  /// gate list and drift from the second-session REHIT rules.
  RestDayRehitInput inputFromSafety({
    required HighIntensitySafetyStatus safety,
    required bool trainingLoggedToday,
    required ReadinessBucket? readinessBucket,
    required bool illnessGuardActive,
    required bool highIntensityTargetDue,
    required ScheduleSlot? scheduleSlot,
    required DateTime nowLocal,
  }) =>
      RestDayRehitInput(
        trainingLoggedToday: trainingLoggedToday,
        readinessBucket: readinessBucket,
        illnessGuardActive: illnessGuardActive,
        contraindicatingPainActive: safety.contraindicatingPainActive,
        painEscalationActive: safety.painEscalationActive,
        deloadActive: safety.deloadActive,
        intensityWithinTrailingWindow: safety.intensityRecoveryActive,
        rehitUnavailableDueToTravel: safety.travelUnavailable,
        highIntensityTargetDue: highIntensityTargetDue,
        scheduleSlot: scheduleSlot,
        nowLocal: nowLocal,
      );

  /// Whether any session at all is on file for [day].
  static bool hasTrainingOn(Iterable<SessionLog> logs, DateTime day) =>
      logs.any(
        (log) =>
            log.date.year == day.year &&
            log.date.month == day.month &&
            log.date.day == day.day,
      );
}
