import '../engine/queue_engine.dart';
import '../models/analytics_event.dart';
import '../models/bouldering_log.dart';
import '../models/check_in.dart';
import '../models/decision_trace.dart';
import '../models/exercise_state.dart';
import '../models/recovery_snapshot.dart';
import '../models/session_log.dart';
import '../models/user_settings.dart';
import 'app_database.dart';
import 'serializers.dart';

/// Thin persistence facade over [AppDatabase]. All decision-making stays in
/// `engine/` - this only stores/retrieves the models those functions need.
class Repository {
  final AppDatabase db;

  Repository(this.db);

  String _dateKey(DateTime d) => DateTime(d.year, d.month, d.day).toIso8601String();

  Future<UserSettings> loadSettings() async {
    final j = await db.getJson('meta', 'key', 'settings');
    if (j == null) return const UserSettings();
    return userSettingsFromJson(j);
  }

  Future<void> saveSettings(UserSettings settings) async {
    await db.putJson('meta', 'key', 'settings', userSettingsToJson(settings));
  }

  Future<QueueState> loadQueueState() async {
    final j = await db.getJson('meta', 'key', 'queue');
    if (j == null) return const QueueState();
    return queueStateFromJson(j);
  }

  Future<void> saveQueueState(QueueState state) async {
    await db.putJson('meta', 'key', 'queue', queueStateToJson(state));
  }

  Future<Map<String, ExerciseState>> loadExerciseStates() async {
    final rows = await db.getAllJson('exercise_states');
    final map = <String, ExerciseState>{};
    for (final r in rows) {
      final s = exerciseStateFromJson(r);
      map[s.trackKey] = s;
    }
    return map;
  }

  Future<void> saveExerciseState(ExerciseState state) async {
    await db.putJson('exercise_states', 'trackKey', state.trackKey, exerciseStateToJson(state));
  }

  Future<void> saveExerciseStates(Map<String, ExerciseState> states) async {
    for (final s in states.values) {
      await saveExerciseState(s);
    }
  }

  Future<void> deleteExerciseState(String trackKey) async {
    await db.delete('exercise_states', 'trackKey', trackKey);
  }

  Future<List<CheckIn>> loadCheckInsSince(DateTime since) async {
    final rows = await db.getJsonSince('check_ins', 'date', since);
    return rows.map(checkInFromJson).toList();
  }

  Future<void> saveCheckIn(CheckIn checkin) async {
    await db.putJson('check_ins', 'date', _dateKey(checkin.date), checkInToJson(checkin));
  }

  Future<void> deleteCheckIn(DateTime date) async {
    await db.delete('check_ins', 'date', _dateKey(date));
  }

  Future<List<RecoverySnapshot>> loadRecoverySnapshotsSince(DateTime since) async {
    final rows = await db.getJsonSince('recovery_snapshots', 'date', since);
    return rows.map(recoverySnapshotFromJson).toList();
  }

  Future<void> saveRecoverySnapshot(RecoverySnapshot snapshot) async {
    await db.putJson('recovery_snapshots', 'date', _dateKey(snapshot.date), recoverySnapshotToJson(snapshot));
  }

  Future<void> deleteRecoverySnapshot(DateTime date) async {
    await db.delete('recovery_snapshots', 'date', _dateKey(date));
  }

  Future<List<SessionLog>> loadSessionLogsSince(DateTime since) async {
    final rows = await db.getJsonSince('session_logs', 'date', since);
    return rows.map(sessionLogFromJson).toList();
  }

  Future<void> saveSessionLog(SessionLog log) async {
    await db.putJsonWithDate('session_logs', log.id, log.date, sessionLogToJson(log));
  }

  Future<List<BoulderingLog>> loadBoulderingLogsSince(DateTime since) async {
    final rows = await db.getJsonSince('bouldering_logs', 'date', since);
    return rows.map(boulderingLogFromJson).toList();
  }

  Future<void> saveBoulderingLog(BoulderingLog log) async {
    await db.putJsonWithDate(
      'bouldering_logs',
      log.id,
      log.date,
      boulderingLogToJson(log),
    );
  }

  Future<void> deleteBoulderingLog(String id) async {
    await db.delete('bouldering_logs', 'id', id);
  }

  /// Append-only analytics timeline. Writes are best-effort at the call site:
  /// losing an observation must never cost the user a workout.
  Future<void> saveAnalyticsEvent(AnalyticsEvent event) async {
    await db.putJsonWithDate(
      'analytics_events',
      event.id,
      event.timestamp,
      analyticsEventToJson(event),
    );
  }

  Future<List<AnalyticsEvent>> loadAnalyticsEventsSince(DateTime since) async {
    final rows = await db.getJsonSince('analytics_events', 'date', since);
    return rows.map(analyticsEventFromJson).nonNulls.toList();
  }

  Future<void> saveDecisionTrace(DecisionTrace trace) async {
    await db.putJson('decision_traces', 'date', _dateKey(trace.date), decisionTraceToJson(trace));
  }

  Future<void> deleteDecisionTrace(DateTime date) async {
    await db.delete('decision_traces', 'date', _dateKey(date));
  }

  Future<DecisionTrace?> loadDecisionTraceForDate(DateTime date) async {
    final j = await db.getJson('decision_traces', 'date', _dateKey(date));
    if (j == null) return null;
    return decisionTraceFromJson(j);
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Deletes every dated row belonging to [day] — and nothing from any other
  /// day. Used by "Reset day". Progression/queue rollback is handled by the
  /// day-start snapshot, not here.
  Future<void> deleteDayData(DateTime day) async {
    final prefix = _ymd(day);
    await db.deleteByDatePrefix('check_ins', 'date', prefix);
    await db.deleteByDatePrefix('recovery_snapshots', 'date', prefix);
    await db.deleteByDatePrefix('decision_traces', 'date', prefix);
    await db.deleteByDatePrefix('session_logs', 'date', prefix);
    await db.deleteByDatePrefix('bouldering_logs', 'date', prefix);
    // The analytics timeline describes the day that is being erased, so it
    // goes with it — otherwise "Reset day" would leave latencies pointing at
    // a check-in and a session that no longer exist.
    await db.deleteByDatePrefix('analytics_events', 'date', prefix);
  }

  /// A snapshot of exercise-state + queue taken at the start of a calendar
  /// day, so "Reset day" can roll progression/queue back to that point. Only
  /// one is kept at a time (keyed by its own date).
  Future<void> saveDayStartSnapshot(DateTime day, Map<String, ExerciseState> states, QueueState queue) async {
    await db.putJson('meta', 'key', 'day_start_snapshot', {
      'date': _ymd(day),
      'states': states.map((k, v) => MapEntry(k, exerciseStateToJson(v))),
      'queue': queueStateToJson(queue),
    });
  }

  Future<Map<String, dynamic>?> loadDayStartSnapshot() async {
    return db.getJson('meta', 'key', 'day_start_snapshot');
  }

  /// Parsed day-start snapshot, but only if it belongs to [day] (a stale
  /// snapshot from a previous day is treated as absent).
  Future<({Map<String, ExerciseState> states, QueueState queue})?> loadDayStartSnapshotFor(DateTime day) async {
    final j = await loadDayStartSnapshot();
    if (j == null || j['date'] != _ymd(day)) return null;
    final states = <String, ExerciseState>{};
    (j['states'] as Map).forEach((k, v) {
      states[k as String] = exerciseStateFromJson((v as Map).cast<String, dynamic>());
    });
    final queue = queueStateFromJson((j['queue'] as Map).cast<String, dynamic>());
    return (states: states, queue: queue);
  }

  Future<void> deleteDayStartSnapshot() async {
    await db.delete('meta', 'key', 'day_start_snapshot');
  }

  /// The load the user last typed into the manual progression-override dialog,
  /// keyed by `<pattern>:<ladderIndex>`. Purely informational — it is shown
  /// back next time as a reference and never auto-applied.
  Future<Map<String, double>> loadManualLoadEntries() async {
    final j = await db.getJson('meta', 'key', 'manual_load_entries');
    if (j == null) return {};
    final out = <String, double>{};
    j.forEach((k, v) {
      final d = (v as num?)?.toDouble();
      if (d != null) out[k] = d;
    });
    return out;
  }

  Future<void> saveManualLoadEntries(Map<String, double> entries) async {
    await db.putJson('meta', 'key', 'manual_load_entries', Map<String, dynamic>.from(entries));
  }

  String ymd(DateTime d) => _ymd(d);
}
