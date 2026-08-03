/// Timeline of app-level training events, recorded so that *latencies* can be
/// measured — facts a session log alone cannot answer, such as how long it
/// took from the morning check-in to actually starting, or from the app
/// deciding a REHIT was worthwhile to the REHIT being done.
///
/// Events are append-only observations. Nothing in the training engines reads
/// them; they exist purely to refine future trainings and future versions of
/// the app.
enum AnalyticsEventType {
  /// The morning check-in form was submitted.
  checkInSubmitted,

  /// A recommendation was produced (initial, swap, or internal refresh).
  planGenerated,

  /// The user opened the logger / began a bike-guided attempt.
  sessionStarted,

  /// A session log was persisted.
  sessionCompleted,

  /// The app first decided today that an optional second REHIT was safe and
  /// worthwhile — the moment the suggestion becomes available.
  rehitSuggested,

  /// A later-day REHIT push nudge was scheduled for a concrete local time.
  rehitNudgeScheduled,

  /// A qualifying REHIT dose was logged (finisher, second session, or
  /// retrospective entry).
  rehitCompleted,

  /// The app first decided today that a rest-day REHIT would fit the user's
  /// schedule.
  restDayRehitSuggested,

  /// The rest-day REHIT nudge was scheduled for a concrete local time.
  restDayRehitNudgeScheduled,
}

/// One timestamped observation.
///
/// [properties] is an untyped string map on purpose: analytics dimensions
/// change far more often than schemas should, and no engine branches on them.
class AnalyticsEvent {
  final String id;
  final AnalyticsEventType type;

  /// Exact local wall-clock instant the event happened.
  final DateTime timestamp;

  /// Local calendar day the event belongs to (midnight-normalized), so a day
  /// can be queried without timestamp arithmetic.
  final DateTime date;
  final Map<String, String> properties;

  AnalyticsEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    DateTime? date,
    Map<String, String> properties = const {},
  })  : date = date ??
            DateTime(timestamp.year, timestamp.month, timestamp.day),
        properties = Map.unmodifiable(properties);

  int? intProperty(String key) => int.tryParse(properties[key] ?? '');

  double? doubleProperty(String key) =>
      double.tryParse(properties[key] ?? '');

  DateTime? dateTimeProperty(String key) {
    final raw = properties[key];
    return raw == null ? null : DateTime.tryParse(raw);
  }
}
