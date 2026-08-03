import '../models/session_log.dart';
import 'analytics_engine.dart';

/// What one weekday looks like in the user's real history.
class WeekdayTrainingHabit {
  /// `DateTime.monday` … `DateTime.sunday`.
  final int weekday;

  /// Calendar days of this weekday inside the window.
  final int observedDays;

  /// Of those, how many carried at least one logged session.
  final int trainedDays;

  /// Median start time on this weekday, in minutes past local midnight. Null
  /// when no session on this weekday has a usable start instant.
  final double? medianStartMinuteOfDay;

  /// Sessions that contributed a start time.
  final int startSampleCount;

  const WeekdayTrainingHabit({
    required this.weekday,
    required this.observedDays,
    required this.trainedDays,
    required this.medianStartMinuteOfDay,
    required this.startSampleCount,
  });

  double? get trainedRatio =>
      observedDays == 0 ? null : trainedDays / observedDays;
}

/// The user's observed training rhythm — when they train, not when they said
/// they would.
class ScheduleHabits {
  final DateTime asOf;
  final int windowDays;
  final List<WeekdayTrainingHabit> weekdays;

  /// Median start time across every session with a usable start instant.
  final double? medianStartMinuteOfDay;
  final int startSampleCount;

  ScheduleHabits({
    required this.asOf,
    required this.windowDays,
    required List<WeekdayTrainingHabit> weekdays,
    required this.medianStartMinuteOfDay,
    required this.startSampleCount,
  }) : weekdays = List.unmodifiable(weekdays);

  WeekdayTrainingHabit? habitFor(int weekday) {
    for (final habit in weekdays) {
      if (habit.weekday == weekday) return habit;
    }
    return null;
  }
}

/// Where a suggested slot's time came from. Surfacing this keeps the nudge
/// honest: "your usual Thursday slot" and "a default afternoon time" are very
/// different claims.
enum ScheduleSlotSource { weekdayHabit, overallHabit, fallback }

class ScheduleSlot {
  final DateTime at;
  final ScheduleSlotSource source;

  /// Sessions the chosen time was derived from (0 for [fallback]).
  final int sampleCount;

  const ScheduleSlot({
    required this.at,
    required this.source,
    required this.sampleCount,
  });

  int get minuteOfDay => at.hour * 60 + at.minute;
}

/// Derives training-time habits from history and proposes a slot for an
/// optional session on a day that is otherwise going unused.
///
/// Pure: the caller supplies the clock and the logs.
class ScheduleFitEngine {
  const ScheduleFitEngine();

  /// Minimum same-weekday samples before a weekday's own median is trusted
  /// over the overall one. Two is deliberately low — a weekly routine only
  /// produces four samples a month — but not one, which is noise.
  static const minWeekdaySamples = 2;

  /// Minimum overall samples before any learned time is used at all.
  static const minOverallSamples = 3;

  ScheduleHabits buildHabits({
    required Iterable<SessionLog> logs,
    required DateTime asOf,
    int windowDays = 56,
  }) {
    final today = _day(asOf);
    final firstDay = today.subtract(Duration(days: windowDays - 1));
    final windowLogs = logs
        .where((log) => !_day(log.date).isBefore(firstDay))
        .where((log) => !_day(log.date).isAfter(today))
        .toList();

    final trainedDayKeys = windowLogs.map((log) => _dayKey(log.date)).toSet();
    final startsByWeekday = <int, List<double>>{};
    final allStarts = <double>[];
    for (final log in windowLogs) {
      final start = log.startedAtOrNull;
      if (start == null) continue;
      final minuteOfDay = (start.hour * 60 + start.minute).toDouble();
      startsByWeekday.putIfAbsent(start.weekday, () => []).add(minuteOfDay);
      allStarts.add(minuteOfDay);
    }

    final observedByWeekday = <int, int>{};
    final trainedByWeekday = <int, int>{};
    for (var offset = 0; offset < windowDays; offset++) {
      final day = today.subtract(Duration(days: offset));
      observedByWeekday.update(day.weekday, (v) => v + 1, ifAbsent: () => 1);
      if (trainedDayKeys.contains(_dayKey(day))) {
        trainedByWeekday.update(day.weekday, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    return ScheduleHabits(
      asOf: asOf,
      windowDays: windowDays,
      weekdays: [
        for (var weekday = DateTime.monday;
            weekday <= DateTime.sunday;
            weekday++)
          WeekdayTrainingHabit(
            weekday: weekday,
            observedDays: observedByWeekday[weekday] ?? 0,
            trainedDays: trainedByWeekday[weekday] ?? 0,
            medianStartMinuteOfDay:
                AnalyticsEngine.median(startsByWeekday[weekday] ?? const []),
            startSampleCount: startsByWeekday[weekday]?.length ?? 0,
          ),
      ],
      medianStartMinuteOfDay: AnalyticsEngine.median(allStarts),
      startSampleCount: allStarts.length,
    );
  }

  /// Proposes today's slot for an optional session.
  ///
  /// Preference order: this weekday's own habit, the overall habit, then the
  /// caller's fallback. The result is always at least [leadMinutes] in the
  /// future (a reminder for a time that has passed is useless) and inside
  /// `[earliestHour, latestHour)`; a slot that cannot fit before
  /// [latestHour] returns null rather than being pushed into the evening.
  ScheduleSlot? suggestSlot({
    required ScheduleHabits habits,
    required DateTime nowLocal,
    int leadMinutes = 45,
    int earliestHour = 8,
    int latestHour = 20,
    int fallbackMinuteOfDay = 17 * 60,
  }) {
    assert(earliestHour >= 0 && earliestHour <= 23);
    assert(latestHour >= 0 && latestHour <= 24);

    final weekdayHabit = habits.habitFor(nowLocal.weekday);
    double? learned;
    var source = ScheduleSlotSource.fallback;
    var samples = 0;
    if (weekdayHabit != null &&
        weekdayHabit.startSampleCount >= minWeekdaySamples &&
        weekdayHabit.medianStartMinuteOfDay != null) {
      learned = weekdayHabit.medianStartMinuteOfDay;
      source = ScheduleSlotSource.weekdayHabit;
      samples = weekdayHabit.startSampleCount;
    } else if (habits.startSampleCount >= minOverallSamples &&
        habits.medianStartMinuteOfDay != null) {
      learned = habits.medianStartMinuteOfDay;
      source = ScheduleSlotSource.overallHabit;
      samples = habits.startSampleCount;
    }

    final targetMinute = (learned ?? fallbackMinuteOfDay).round();
    final day = _day(nowLocal);
    var slot = day.add(Duration(minutes: targetMinute));

    // A habitual slot that has already passed is not a reason to stay silent:
    // the point of the nudge is to salvage the rest of the day. Push it to the
    // next quarter hour at least `leadMinutes` out.
    final earliestAllowed = nowLocal.add(Duration(minutes: leadMinutes));
    if (slot.isBefore(earliestAllowed)) {
      slot = _ceilToQuarterHour(earliestAllowed);
    }
    final earliestSlot = day.add(Duration(hours: earliestHour));
    if (slot.isBefore(earliestSlot)) slot = earliestSlot;
    if (!slot.isBefore(day.add(Duration(hours: latestHour)))) return null;

    return ScheduleSlot(at: slot, source: source, sampleCount: samples);
  }

  static DateTime _ceilToQuarterHour(DateTime value) {
    final base = DateTime(value.year, value.month, value.day, value.hour);
    final minutesIn = value.difference(base).inSeconds / 60;
    final quarters = (minutesIn / 15).ceil();
    return base.add(Duration(minutes: quarters * 15));
  }

  static DateTime _day(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static String _dayKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
