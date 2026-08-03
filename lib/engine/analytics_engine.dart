import '../models/analytics_event.dart';
import '../models/cardio_protocol.dart';
import '../models/session_log.dart';
import '../models/session_type.dart';
import '../models/set_log.dart';

/// Time cost of one exercise inside one session.
class ExerciseTimeMetrics {
  final String trackKey;
  final String name;
  final bool isWarmup;
  final int setCount;

  /// Sum of the sets' full cycles (rest into the set + setup + execution).
  final int totalSeconds;
  final int restSeconds;
  final int activeSeconds;

  const ExerciseTimeMetrics({
    required this.trackKey,
    required this.name,
    required this.isWarmup,
    required this.setCount,
    required this.totalSeconds,
    required this.restSeconds,
    required this.activeSeconds,
  });

  double? get secondsPerSet => setCount == 0 ? null : totalSeconds / setCount;

  double? get activeSecondsPerSet =>
      setCount == 0 ? null : activeSeconds / setCount;
}

/// Everything measurable about how long one logged session actually took.
///
/// The partition is exact by construction:
/// `totalSeconds = warmupSeconds + workRestSeconds + workActiveSeconds +
/// unattributedSeconds`, where the last term is the time inside the session
/// that no logged step accounts for (arriving, reading the plan, the gap
/// after the final set before finishing).
class SessionTimeMetrics {
  final String sessionLogId;
  final SessionTypeId templateId;
  final DateTime date;
  final DateTime? startedAt;
  final DateTime completedAt;

  /// Elapsed seconds, exact where the session recorded them.
  final int totalSeconds;
  final bool totalSecondsExact;

  /// What the planner predicted, when the session recorded it.
  final int? plannedSeconds;

  final int warmupSeconds;
  final int warmupSetCount;

  /// Prescribed rest consumed inside the logged work-set cycles.
  final int workRestSeconds;

  /// Work-set cycle time beyond prescribed rest — setup plus execution.
  final int workActiveSeconds;
  final int workSetCount;

  /// Work sets that carried usable timing. A session logged by an older
  /// build has zero, and every per-set average below is null.
  final int timedSetCount;
  final List<ExerciseTimeMetrics> exercises;
  final bool endedEarly;

  SessionTimeMetrics({
    required this.sessionLogId,
    required this.templateId,
    required this.date,
    required this.startedAt,
    required this.completedAt,
    required this.totalSeconds,
    required this.totalSecondsExact,
    required this.plannedSeconds,
    required this.warmupSeconds,
    required this.warmupSetCount,
    required this.workRestSeconds,
    required this.workActiveSeconds,
    required this.workSetCount,
    required this.timedSetCount,
    required List<ExerciseTimeMetrics> exercises,
    required this.endedEarly,
  }) : exercises = List.unmodifiable(exercises);

  int get attributedSeconds =>
      warmupSeconds + workRestSeconds + workActiveSeconds;

  /// Session time no logged step accounts for. Clamped at zero: a session
  /// whose steps outrun the elapsed clock (a clock change, a restored route)
  /// must not report negative dead time.
  int get unattributedSeconds {
    final remainder = totalSeconds - attributedSeconds;
    return remainder < 0 ? 0 : remainder;
  }

  /// Actual minus predicted. Positive means the session overran its estimate,
  /// which is exactly the signal the duration model needs.
  int? get estimateErrorSeconds =>
      plannedSeconds == null ? null : totalSeconds - plannedSeconds!;

  double? get estimateRatio => plannedSeconds == null || plannedSeconds == 0
      ? null
      : totalSeconds / plannedSeconds!;

  double? get secondsPerWorkSet =>
      workSetCount == 0 ? null : totalSeconds / workSetCount;

  double? get workSetsPerHour =>
      totalSeconds == 0 ? null : workSetCount * 3600 / totalSeconds;

  /// Fraction of the session spent on something other than prescribed rest.
  /// Only meaningful when the sets were actually timed.
  double? get activeFraction => timedSetCount == 0 || totalSeconds == 0
      ? null
      : (totalSeconds - workRestSeconds) / totalSeconds;
}

/// Per-session-type roll-up: the unit the planner's duration model works in.
class SessionTypeTimeSummary {
  final SessionTypeId templateId;
  final int sessionCount;
  final double medianTotalSeconds;
  final double? medianPlannedSeconds;

  /// Median signed error (actual − predicted). Bias, not spread: a
  /// consistently +6-minute type needs its estimate raised, while a type that
  /// scatters symmetrically around zero does not.
  final double? medianEstimateErrorSeconds;
  final double? medianAbsoluteEstimateErrorSeconds;
  final double? medianSecondsPerWorkSet;

  const SessionTypeTimeSummary({
    required this.templateId,
    required this.sessionCount,
    required this.medianTotalSeconds,
    required this.medianPlannedSeconds,
    required this.medianEstimateErrorSeconds,
    required this.medianAbsoluteEstimateErrorSeconds,
    required this.medianSecondsPerWorkSet,
  });

  /// True when the estimate is off by more than a minute in the median case
  /// and there is enough evidence to say so.
  bool get estimateNeedsAttention =>
      sessionCount >= 3 &&
      medianEstimateErrorSeconds != null &&
      medianEstimateErrorSeconds!.abs() > 60;
}

/// Time cost of one exercise across the window — what to trim first when a
/// slot is too short.
class ExerciseTimeSummary {
  final String trackKey;
  final String name;
  final int setCount;
  final int totalSeconds;
  final double medianSecondsPerSet;
  final double medianActiveSecondsPerSet;

  const ExerciseTimeSummary({
    required this.trackKey,
    required this.name,
    required this.setCount,
    required this.totalSeconds,
    required this.medianSecondsPerSet,
    required this.medianActiveSecondsPerSet,
  });
}

/// The REHIT funnel: offered → nudged → done, and how long each hop took.
class RehitFunnelMetrics {
  /// Days the app judged an optional REHIT safe and worthwhile.
  final int suggestedDays;

  /// Days a push nudge was actually scheduled (a suggestion after the daily
  /// cutoff never becomes a nudge).
  final int nudgedDays;

  /// Days a qualifying REHIT dose was logged.
  final int completedDays;

  /// Days the completion followed a same-day suggestion.
  final int convertedDays;

  /// Suggestion → completion, for converted days.
  final double? medianSuggestionToCompletionSeconds;

  /// First session start → REHIT completion on the same day. Answers "how
  /// long after starting training does the second exposure actually land".
  final double? medianSessionStartToCompletionSeconds;

  /// Median local time of day (minutes past midnight) of completed REHITs.
  final double? medianCompletionMinuteOfDay;

  const RehitFunnelMetrics({
    required this.suggestedDays,
    required this.nudgedDays,
    required this.completedDays,
    required this.convertedDays,
    required this.medianSuggestionToCompletionSeconds,
    required this.medianSessionStartToCompletionSeconds,
    required this.medianCompletionMinuteOfDay,
  });

  double? get conversionRate =>
      suggestedDays == 0 ? null : convertedDays / suggestedDays;
}

/// How reliably training happens at all, independent of what was trained.
class ConsistencyMetrics {
  final int windowDays;
  final int trainedDays;
  final int currentStreakDays;
  final int longestStreakDays;
  final int? daysSinceLastSession;

  /// Untrained-day count per `DateTime.weekday`, so a habitually missed day
  /// is visible rather than inferred.
  final Map<int, int> untrainedDaysByWeekday;

  ConsistencyMetrics({
    required this.windowDays,
    required this.trainedDays,
    required this.currentStreakDays,
    required this.longestStreakDays,
    required this.daysSinceLastSession,
    required Map<int, int> untrainedDaysByWeekday,
  }) : untrainedDaysByWeekday = Map.unmodifiable(untrainedDaysByWeekday);

  int get untrainedDays => windowDays - trainedDays;

  double? get trainedDaysPerWeek =>
      windowDays == 0 ? null : trainedDays * 7 / windowDays;
}

/// Delays between the day's app milestones. These are the numbers that say
/// whether the *schedule*, not the program, is what needs changing.
class LatencyMetrics {
  /// Check-in submitted → session started.
  final double? medianCheckInToStartSeconds;

  /// Plan produced → session started. Differs from the above on days with a
  /// swap or a settings-driven refresh.
  final double? medianPlanToStartSeconds;

  /// Median local time of day (minutes past midnight) of the check-in.
  final double? medianCheckInMinuteOfDay;

  /// Days with a check-in but no session logged at all.
  final int checkedInWithoutTrainingDays;

  const LatencyMetrics({
    required this.medianCheckInToStartSeconds,
    required this.medianPlanToStartSeconds,
    required this.medianCheckInMinuteOfDay,
    required this.checkedInWithoutTrainingDays,
  });
}

/// Where session time actually goes, summed over the sessions that carried
/// per-set timing. Sessions without it are excluded entirely rather than
/// contributing all of their minutes to "unaccounted".
class TimeAllocation {
  final int sessionCount;
  final int totalSeconds;
  final int warmupSeconds;
  final int restSeconds;
  final int activeSeconds;
  final int unattributedSeconds;

  const TimeAllocation({
    required this.sessionCount,
    required this.totalSeconds,
    required this.warmupSeconds,
    required this.restSeconds,
    required this.activeSeconds,
    required this.unattributedSeconds,
  });

  static const empty = TimeAllocation(
    sessionCount: 0,
    totalSeconds: 0,
    warmupSeconds: 0,
    restSeconds: 0,
    activeSeconds: 0,
    unattributedSeconds: 0,
  );

  double fractionOf(int seconds) =>
      totalSeconds == 0 ? 0 : seconds / totalSeconds;
}

/// The complete analytics surface for one window.
class TrainingTimeInsights {
  final DateTime asOf;
  final int windowDays;
  final List<SessionTimeMetrics> sessions;
  final List<SessionTypeTimeSummary> bySessionType;
  final List<ExerciseTimeSummary> exerciseCosts;
  final TimeAllocation allocation;
  final RehitFunnelMetrics rehit;
  final ConsistencyMetrics consistency;
  final LatencyMetrics latency;

  TrainingTimeInsights({
    required this.asOf,
    required this.windowDays,
    required List<SessionTimeMetrics> sessions,
    required List<SessionTypeTimeSummary> bySessionType,
    required List<ExerciseTimeSummary> exerciseCosts,
    required this.allocation,
    required this.rehit,
    required this.consistency,
    required this.latency,
  })  : sessions = List.unmodifiable(sessions),
        bySessionType = List.unmodifiable(bySessionType),
        exerciseCosts = List.unmodifiable(exerciseCosts);

  bool get hasTimedSessions =>
      sessions.any((session) => session.timedSetCount > 0);

  /// Sessions whose duration is exact rather than reconstructed from whole
  /// minutes — the share of history the duration model can fully trust.
  int get exactlyTimedSessionCount =>
      sessions.where((session) => session.totalSecondsExact).length;
}

/// Pure derivation of every time metric from persisted records.
///
/// Nothing here reads the clock or touches storage: the caller supplies
/// `asOf`, the logs, and the event timeline.
class AnalyticsEngine {
  const AnalyticsEngine();

  /// Per-session breakdown. Supplemental and unplanned work is included —
  /// it costs real time — and is distinguishable via the source logs.
  SessionTimeMetrics sessionMetrics(SessionLog log) {
    final byTrack = <String, _ExerciseAccumulator>{};
    var warmupSeconds = 0;
    var warmupSetCount = 0;
    var workRestSeconds = 0;
    var workActiveSeconds = 0;
    var workSetCount = 0;
    var timedSetCount = 0;

    for (final set in log.setLogs) {
      final cycle = set.cycleSeconds;
      if (set.isWarmup) {
        warmupSetCount += 1;
      } else {
        workSetCount += 1;
      }
      if (cycle == null) continue;
      timedSetCount += 1;
      final rest = set.restSeconds ?? 0;
      final active = set.activeSecondsEstimate ?? cycle;
      if (set.isWarmup) {
        warmupSeconds += cycle;
      } else {
        workRestSeconds += rest;
        workActiveSeconds += active;
      }
      byTrack
          .putIfAbsent(
            set.trackKey,
            () => _ExerciseAccumulator(set.trackKey, set.exerciseName,
                isWarmup: set.isWarmup),
          )
          .add(cycle: cycle, rest: rest, active: active);
    }

    return SessionTimeMetrics(
      sessionLogId: log.id,
      templateId: log.templateId,
      date: log.date,
      startedAt: log.startedAtOrNull,
      completedAt: log.completedAt,
      totalSeconds: log.elapsedSecondsOrEstimate,
      totalSecondsExact: log.hasExactElapsedSeconds,
      plannedSeconds: log.timings?.plannedSeconds,
      warmupSeconds: warmupSeconds,
      warmupSetCount: warmupSetCount,
      workRestSeconds: workRestSeconds,
      workActiveSeconds: workActiveSeconds,
      workSetCount: workSetCount,
      timedSetCount: timedSetCount,
      exercises: byTrack.values.map((a) => a.build()).toList()
        ..sort((a, b) => b.totalSeconds.compareTo(a.totalSeconds)),
      endedEarly: log.endedEarly,
    );
  }

  /// Builds the whole insight surface for the trailing [windowDays] calendar
  /// days ending on `asOf`'s local date (inclusive).
  TrainingTimeInsights build({
    required Iterable<SessionLog> logs,
    required Iterable<AnalyticsEvent> events,
    required DateTime asOf,
    int windowDays = 56,
  }) {
    final today = _day(asOf);
    final firstDay = today.subtract(Duration(days: windowDays - 1));
    final windowLogs = logs
        .where((log) => !_day(log.date).isBefore(firstDay))
        .where((log) => !_day(log.date).isAfter(today))
        .toList()
      ..sort((a, b) => a.completedAt.compareTo(b.completedAt));
    final windowEvents = events
        .where((event) => !_day(event.date).isBefore(firstDay))
        .where((event) => !_day(event.date).isAfter(today))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final sessions = windowLogs.map(sessionMetrics).toList();

    return TrainingTimeInsights(
      asOf: asOf,
      windowDays: windowDays,
      sessions: sessions,
      bySessionType: _summarizeByType(sessions),
      exerciseCosts: _summarizeExercises(sessions),
      allocation: _allocate(sessions),
      rehit: _rehitFunnel(windowLogs, windowEvents),
      consistency: _consistency(windowLogs, today: today, windowDays: windowDays),
      latency: _latency(windowLogs, windowEvents),
    );
  }

  TimeAllocation _allocate(List<SessionTimeMetrics> sessions) {
    final timed =
        sessions.where((session) => session.timedSetCount > 0).toList();
    if (timed.isEmpty) return TimeAllocation.empty;
    var total = 0;
    var warmup = 0;
    var rest = 0;
    var active = 0;
    var unattributed = 0;
    for (final session in timed) {
      total += session.totalSeconds;
      warmup += session.warmupSeconds;
      rest += session.workRestSeconds;
      active += session.workActiveSeconds;
      unattributed += session.unattributedSeconds;
    }
    return TimeAllocation(
      sessionCount: timed.length,
      totalSeconds: total,
      warmupSeconds: warmup,
      restSeconds: rest,
      activeSeconds: active,
      unattributedSeconds: unattributed,
    );
  }

  List<SessionTypeTimeSummary> _summarizeByType(
    List<SessionTimeMetrics> sessions,
  ) {
    final grouped = <SessionTypeId, List<SessionTimeMetrics>>{};
    for (final session in sessions) {
      grouped.putIfAbsent(session.templateId, () => []).add(session);
    }
    final summaries = grouped.entries.map((entry) {
      final group = entry.value;
      return SessionTypeTimeSummary(
        templateId: entry.key,
        sessionCount: group.length,
        medianTotalSeconds:
            median(group.map((s) => s.totalSeconds.toDouble()))!,
        medianPlannedSeconds: median(
          group.map((s) => s.plannedSeconds?.toDouble()).nonNulls,
        ),
        medianEstimateErrorSeconds: median(
          group.map((s) => s.estimateErrorSeconds?.toDouble()).nonNulls,
        ),
        medianAbsoluteEstimateErrorSeconds: median(
          group
              .map((s) => s.estimateErrorSeconds?.toDouble().abs())
              .nonNulls,
        ),
        medianSecondsPerWorkSet:
            median(group.map((s) => s.secondsPerWorkSet).nonNulls),
      );
    }).toList()
      ..sort((a, b) => b.sessionCount.compareTo(a.sessionCount));
    return summaries;
  }

  List<ExerciseTimeSummary> _summarizeExercises(
    List<SessionTimeMetrics> sessions,
  ) {
    final perSet = <String, List<double>>{};
    final perSetActive = <String, List<double>>{};
    final totals = <String, int>{};
    final counts = <String, int>{};
    final names = <String, String>{};

    for (final session in sessions) {
      for (final exercise in session.exercises) {
        if (exercise.isWarmup) continue;
        names[exercise.trackKey] = exercise.name;
        totals.update(exercise.trackKey, (v) => v + exercise.totalSeconds,
            ifAbsent: () => exercise.totalSeconds);
        counts.update(exercise.trackKey, (v) => v + exercise.setCount,
            ifAbsent: () => exercise.setCount);
        final secondsPerSet = exercise.secondsPerSet;
        if (secondsPerSet != null) {
          perSet.putIfAbsent(exercise.trackKey, () => []).add(secondsPerSet);
          perSetActive
              .putIfAbsent(exercise.trackKey, () => [])
              .add(exercise.activeSecondsPerSet!);
        }
      }
    }

    final summaries = <ExerciseTimeSummary>[];
    for (final key in totals.keys) {
      final medianPerSet = median(perSet[key] ?? const []);
      if (medianPerSet == null) continue;
      summaries.add(
        ExerciseTimeSummary(
          trackKey: key,
          name: names[key] ?? key,
          setCount: counts[key] ?? 0,
          totalSeconds: totals[key] ?? 0,
          medianSecondsPerSet: medianPerSet,
          medianActiveSecondsPerSet: median(perSetActive[key] ?? const [])!,
        ),
      );
    }
    summaries.sort((a, b) => b.totalSeconds.compareTo(a.totalSeconds));
    return summaries;
  }

  RehitFunnelMetrics _rehitFunnel(
    List<SessionLog> logs,
    List<AnalyticsEvent> events,
  ) {
    final suggestions = <String, DateTime>{};
    final nudged = <String>{};
    for (final event in events) {
      final key = _dayKey(event.date);
      switch (event.type) {
        case AnalyticsEventType.rehitSuggested:
        case AnalyticsEventType.restDayRehitSuggested:
          suggestions.putIfAbsent(key, () => event.timestamp);
        case AnalyticsEventType.rehitNudgeScheduled:
        case AnalyticsEventType.restDayRehitNudgeScheduled:
          nudged.add(key);
        default:
          break;
      }
    }

    // Completions come from the event timeline where it exists and from the
    // logs otherwise, so history predating event capture still counts.
    final completions = <String, DateTime>{};
    for (final event in events
        .where((event) => event.type == AnalyticsEventType.rehitCompleted)) {
      completions.putIfAbsent(_dayKey(event.date), () => event.timestamp);
    }
    for (final log in logs.where(isQualifyingRehitLog)) {
      if (log.completedAtPrecision != CompletionTimePrecision.exact) continue;
      completions.putIfAbsent(_dayKey(log.date), () => log.completedAt);
    }

    // First session start per day, for the "start → REHIT" latency.
    final firstStart = <String, DateTime>{};
    for (final log in logs) {
      final start = log.startedAtOrNull;
      if (start == null) continue;
      final key = _dayKey(log.date);
      final existing = firstStart[key];
      if (existing == null || start.isBefore(existing)) {
        firstStart[key] = start;
      }
    }

    final suggestionToCompletion = <double>[];
    final startToCompletion = <double>[];
    final completionMinutes = <double>[];
    var converted = 0;
    for (final entry in completions.entries) {
      completionMinutes
          .add((entry.value.hour * 60 + entry.value.minute).toDouble());
      final suggestedAt = suggestions[entry.key];
      if (suggestedAt != null && !entry.value.isBefore(suggestedAt)) {
        converted += 1;
        suggestionToCompletion
            .add(entry.value.difference(suggestedAt).inSeconds.toDouble());
      }
      final startedAt = firstStart[entry.key];
      if (startedAt != null && entry.value.isAfter(startedAt)) {
        startToCompletion
            .add(entry.value.difference(startedAt).inSeconds.toDouble());
      }
    }

    return RehitFunnelMetrics(
      suggestedDays: suggestions.length,
      nudgedDays: nudged.length,
      completedDays: completions.length,
      convertedDays: converted,
      medianSuggestionToCompletionSeconds: median(suggestionToCompletion),
      medianSessionStartToCompletionSeconds: median(startToCompletion),
      medianCompletionMinuteOfDay: median(completionMinutes),
    );
  }

  ConsistencyMetrics _consistency(
    List<SessionLog> logs, {
    required DateTime today,
    required int windowDays,
  }) {
    final trained = logs.map((log) => _dayKey(log.date)).toSet();
    final untrainedByWeekday = <int, int>{};
    var currentStreak = 0;
    var longestStreak = 0;
    var runningStreak = 0;
    int? daysSinceLast;

    for (var offset = windowDays - 1; offset >= 0; offset--) {
      final day = today.subtract(Duration(days: offset));
      if (trained.contains(_dayKey(day))) {
        runningStreak += 1;
        if (runningStreak > longestStreak) longestStreak = runningStreak;
        daysSinceLast = today.difference(day).inDays;
      } else {
        runningStreak = 0;
        untrainedByWeekday.update(day.weekday, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    // The trailing run is the current streak only if it reaches today.
    currentStreak = trained.contains(_dayKey(today)) ? runningStreak : 0;

    return ConsistencyMetrics(
      windowDays: windowDays,
      trainedDays: trained.length,
      currentStreakDays: currentStreak,
      longestStreakDays: longestStreak,
      daysSinceLastSession: daysSinceLast,
      untrainedDaysByWeekday: untrainedByWeekday,
    );
  }

  LatencyMetrics _latency(
    List<SessionLog> logs,
    List<AnalyticsEvent> events,
  ) {
    final checkIns = <String, DateTime>{};
    final plans = <String, DateTime>{};
    for (final event in events) {
      final key = _dayKey(event.date);
      switch (event.type) {
        case AnalyticsEventType.checkInSubmitted:
          checkIns.putIfAbsent(key, () => event.timestamp);
        case AnalyticsEventType.planGenerated:
          plans.putIfAbsent(key, () => event.timestamp);
        default:
          break;
      }
    }

    final firstStart = <String, DateTime>{};
    for (final log in logs) {
      final start = log.startedAtOrNull;
      if (start == null) continue;
      final key = _dayKey(log.date);
      final existing = firstStart[key];
      if (existing == null || start.isBefore(existing)) {
        firstStart[key] = start;
      }
    }

    final checkInToStart = <double>[];
    final planToStart = <double>[];
    for (final entry in firstStart.entries) {
      final checkedInAt = checkIns[entry.key];
      if (checkedInAt != null && entry.value.isAfter(checkedInAt)) {
        checkInToStart
            .add(entry.value.difference(checkedInAt).inSeconds.toDouble());
      }
      final plannedAt = plans[entry.key];
      if (plannedAt != null && entry.value.isAfter(plannedAt)) {
        planToStart
            .add(entry.value.difference(plannedAt).inSeconds.toDouble());
      }
    }

    final trainedDays = logs.map((log) => _dayKey(log.date)).toSet();
    return LatencyMetrics(
      medianCheckInToStartSeconds: median(checkInToStart),
      medianPlanToStartSeconds: median(planToStart),
      medianCheckInMinuteOfDay: median(
        checkIns.values.map((at) => (at.hour * 60 + at.minute).toDouble()),
      ),
      checkedInWithoutTrainingDays:
          checkIns.keys.where((day) => !trainedDays.contains(day)).length,
    );
  }

  /// A REHIT dose that actually happened, in any of its three shapes: a
  /// dedicated S7 session, the optional S2 finisher, or a retrospective
  /// entry. Deliberately independent of queue/category credit.
  static bool isQualifyingRehitLog(SessionLog log) {
    if (log.rehitFinisherCompleted) return true;
    final completion = log.cardioCompletion;
    if (completion == null) return false;
    return completion.protocol.type == CardioProtocolType.rehit &&
        completion.meetsCreditableDose;
  }

  /// Linear-interpolation-free median: the middle value, or the mean of the
  /// two middle values. Null for an empty sample so callers must handle
  /// "not enough data" explicitly instead of reading a zero as a measurement.
  static double? median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    if (sorted.isEmpty) return null;
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  static DateTime _day(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static String _dayKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class _ExerciseAccumulator {
  final String trackKey;
  final String name;
  final bool isWarmup;
  int setCount = 0;
  int totalSeconds = 0;
  int restSeconds = 0;
  int activeSeconds = 0;

  _ExerciseAccumulator(this.trackKey, this.name, {required this.isWarmup});

  void add({required int cycle, required int rest, required int active}) {
    setCount += 1;
    totalSeconds += cycle;
    restSeconds += rest;
    activeSeconds += active;
  }

  ExerciseTimeMetrics build() => ExerciseTimeMetrics(
        trackKey: trackKey,
        name: name,
        isWarmup: isWarmup,
        setCount: setCount,
        totalSeconds: totalSeconds,
        restSeconds: restSeconds,
        activeSeconds: activeSeconds,
      );
}

/// Convenience for callers that already hold a set list.
extension SetLogTimingSummary on Iterable<SetLog> {
  int get timedCount => where((set) => set.cycleSeconds != null).length;
}
