import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../engine/rehit_eligibility_engine.dart';

const secondRehitNudgeTitle = 'Still up for CAROL REHIT Intense?';
const secondRehitNudgeBody =
    'The bike-guided CAROL REHIT Intense preset can add one short high-intensity exposure today.';

String _secondRehitNudgeDay(DateTime now) =>
    '${now.year.toString().padLeft(4, '0')}-'
    '${now.month.toString().padLeft(2, '0')}-'
    '${now.day.toString().padLeft(2, '0')}';

enum SecondRehitNudgeSyncDecision { cancel, keep, schedule }

/// Explicit marker mutation returned by the best-effort platform sync. A
/// nullable day alone cannot distinguish "keep the current marker" from
/// "clear it after cancellation".
class SecondRehitNudgeSyncOutcome {
  final bool stateChanged;
  final String? scheduledDay;
  final DateTime? scheduledFor;

  const SecondRehitNudgeSyncOutcome({
    required this.stateChanged,
    required this.scheduledDay,
    required this.scheduledFor,
  });
}

/// Pure once-per-local-day gate used before touching the notification
/// plugin. Cancellation always wins when the feature is disabled or no
/// longer eligible.
SecondRehitNudgeSyncDecision secondRehitNudgeSyncDecision({
  required bool enabled,
  required RehitEligibilityResult eligibility,
  required String? scheduledDay,
}) {
  if (!enabled || !eligibility.eligible) {
    return SecondRehitNudgeSyncDecision.cancel;
  }
  if (scheduledDay == _secondRehitNudgeDay(eligibility.observedAt)) {
    return SecondRehitNudgeSyncDecision.keep;
  }
  return eligibility.suggestedNudgeTime == null
      ? SecondRehitNudgeSyncDecision.cancel
      : SecondRehitNudgeSyncDecision.schedule;
}

/// Pure marker transition paired with [secondRehitNudgeSyncDecision]. A
/// successful cancellation clears the marker, allowing a genuinely eligible
/// result later the same day to schedule once again. A failed platform
/// operation keeps the old marker so an existing notification cannot become
/// untracked or be duplicated.
SecondRehitNudgeSyncOutcome secondRehitNudgeMarkerTransition({
  required SecondRehitNudgeSyncDecision decision,
  required RehitEligibilityResult eligibility,
  required String? scheduledDay,
  required DateTime? scheduledFor,
  bool operationSucceeded = true,
}) {
  switch (decision) {
    case SecondRehitNudgeSyncDecision.cancel:
      if (!operationSucceeded) {
        return SecondRehitNudgeSyncOutcome(
          stateChanged: false,
          scheduledDay: scheduledDay,
          scheduledFor: scheduledFor,
        );
      }
      final observedDay = _secondRehitNudgeDay(eligibility.observedAt);
      final targetMayHaveFired = scheduledDay == observedDay &&
          (scheduledFor == null ||
              !eligibility.observedAt.isBefore(scheduledFor));
      if (targetMayHaveFired) {
        return SecondRehitNudgeSyncOutcome(
          stateChanged: false,
          scheduledDay: scheduledDay,
          scheduledFor: scheduledFor,
        );
      }
      return SecondRehitNudgeSyncOutcome(
        stateChanged: scheduledDay != null || scheduledFor != null,
        scheduledDay: null,
        scheduledFor: null,
      );
    case SecondRehitNudgeSyncDecision.keep:
      return SecondRehitNudgeSyncOutcome(
        stateChanged: false,
        scheduledDay: scheduledDay,
        scheduledFor: scheduledFor,
      );
    case SecondRehitNudgeSyncDecision.schedule:
      if (!operationSucceeded) {
        return SecondRehitNudgeSyncOutcome(
          stateChanged: false,
          scheduledDay: scheduledDay,
          scheduledFor: scheduledFor,
        );
      }
      final nextDay = _secondRehitNudgeDay(eligibility.observedAt);
      final nextTarget = eligibility.suggestedNudgeTime;
      return SecondRehitNudgeSyncOutcome(
        stateChanged:
            scheduledDay != nextDay || scheduledFor != nextTarget,
        scheduledDay: nextDay,
        scheduledFor: nextTarget,
      );
  }
}

/// §3.1 wake-window nudge ("Ready to plan today?") and §12 no-check-in
/// cutoff ("No plan yet - tap for a 20-min default").
///
/// Every method swallows platform errors: notifications are best-effort
/// polish and must never break check-in flow or unit tests (which have no
/// platform channels).
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _wakeId = 1;
  static const _cutoffId = 2;
  static const _secondRehitId = 3;

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'morningcoach_daily',
      'Daily check-in',
      channelDescription: 'Morning check-in reminders',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
  );

  static const _trainingNudgeDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'morningcoach_training_nudges',
      'Training nudges',
      channelDescription: 'Optional later-day training reminders',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
  );

  static Future<bool> _init() async {
    if (_ready) return true;
    try {
      tzdata.initializeTimeZones();
      _setLocalLocationFromOffset();
      await _plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      );
      _ready = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The timezone package defaults tz.local to UTC. Without pulling in a
  /// platform plugin, pick a database location matching the device's
  /// current UTC offset (preferring a matching abbreviation). Re-run on
  /// every schedule call, so DST shifts self-correct on the next app open.
  static void _setLocalLocationFromOffset() {
    final now = DateTime.now();
    tz.Location? byOffset;
    for (final loc in tz.timeZoneDatabase.locations.values) {
      final tzNow = tz.TZDateTime.now(loc);
      if (tzNow.timeZoneOffset == now.timeZoneOffset) {
        byOffset ??= loc;
        if (tzNow.timeZoneName == now.timeZoneName) {
          tz.setLocalLocation(loc);
          return;
        }
      }
    }
    if (byOffset != null) tz.setLocalLocation(byOffset);
  }

  /// Android 13+ runtime permission. Returns false when denied/unavailable.
  static Future<bool> requestPermission() async {
    if (!await _init()) return false;
    try {
      final android =
          _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  static tz.TZDateTime _nextAt(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var t = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
    return t;
  }

  /// (Re)schedules both daily notifications. Call on app start, after a
  /// settings change, and after a check-in (which pushes today's cutoff
  /// nudge to tomorrow). Inexact scheduling - no special alarm permission.
  static Future<void> sync({
    required bool enabled,
    required String wakeWindow,
    required int cutoffHour,
    required bool checkedInToday,
  }) async {
    if (!await _init()) return;
    try {
      await _plugin.cancel(_wakeId);
      await _plugin.cancel(_cutoffId);
      if (!enabled) return;

      final parts = wakeWindow.split(':');
      final h = (int.tryParse(parts.first) ?? 7).clamp(0, 23);
      final m = (parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0).clamp(0, 59);
      await _plugin.zonedSchedule(
        _wakeId,
        'Ready to plan today?',
        'A 10-second check-in gets you exactly one session.',
        _nextAt(h, m),
        _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );

      var cutoff = _nextAt(cutoffHour.clamp(0, 23), 0);
      final now = tz.TZDateTime.now(tz.local);
      if (checkedInToday && cutoff.day == now.day && cutoff.month == now.month) {
        cutoff = cutoff.add(const Duration(days: 1));
      }
      await _plugin.zonedSchedule(
        _cutoffId,
        'No plan yet today',
        'Open MorningCoach for a 20-min default session.',
        cutoff,
        _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {
      // best-effort only
    }
  }

  /// Keeps one optional second-session REHIT nudge in sync with the current
  /// log state. This is a single inexact notification, never a daily alarm.
  static Future<SecondRehitNudgeSyncOutcome> syncSecondRehitNudge({
    required bool enabled,
    required RehitEligibilityResult eligibility,
    required String? scheduledDay,
    required DateTime? scheduledFor,
  }) async {
    final decision = secondRehitNudgeSyncDecision(
      enabled: enabled,
      eligibility: eligibility,
      scheduledDay: scheduledDay,
    );
    if (decision == SecondRehitNudgeSyncDecision.keep) {
      return secondRehitNudgeMarkerTransition(
        decision: decision,
        eligibility: eligibility,
        scheduledDay: scheduledDay,
        scheduledFor: scheduledFor,
      );
    }
    if (!await _init()) {
      return secondRehitNudgeMarkerTransition(
        decision: decision,
        eligibility: eligibility,
        scheduledDay: scheduledDay,
        scheduledFor: scheduledFor,
        operationSucceeded: false,
      );
    }
    try {
      await _plugin.cancel(_secondRehitId);
      if (decision != SecondRehitNudgeSyncDecision.schedule) {
        return secondRehitNudgeMarkerTransition(
          decision: decision,
          eligibility: eligibility,
          scheduledDay: scheduledDay,
          scheduledFor: scheduledFor,
        );
      }

      final target = eligibility.suggestedNudgeTime!;
      _setLocalLocationFromOffset();
      final localTarget = tz.TZDateTime(
        tz.local,
        target.year,
        target.month,
        target.day,
        target.hour,
        target.minute,
        target.second,
      );
      await _plugin.zonedSchedule(
        _secondRehitId,
        secondRehitNudgeTitle,
        secondRehitNudgeBody,
        localTarget,
        _trainingNudgeDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
      return secondRehitNudgeMarkerTransition(
        decision: decision,
        eligibility: eligibility,
        scheduledDay: scheduledDay,
        scheduledFor: scheduledFor,
      );
    } catch (_) {
      // best-effort only
      return secondRehitNudgeMarkerTransition(
        decision: decision,
        eligibility: eligibility,
        scheduledDay: scheduledDay,
        scheduledFor: scheduledFor,
        operationSucceeded: false,
      );
    }
  }
}
