/// The minimum an eligibility result must expose for the once-per-local-day
/// nudge scheduler to act on it.
///
/// Both REHIT reminders (the second-session offer and the rest-day one) reach
/// the notification layer through this shape, so the tricky "schedule once,
/// cancel cleanly, never duplicate across restarts" bookkeeping exists once.
abstract class DailyNudgeEligibility {
  bool get eligible;

  /// Exact local time the decision was evaluated. The day marker is derived
  /// from this, never from a second clock reading.
  DateTime get observedAt;

  /// Null when ineligible, or when the otherwise-eligible target would land
  /// too late in the day to be worth sending.
  DateTime? get suggestedNudgeTime;
}
