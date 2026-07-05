import '../engine/queue_engine.dart';
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
}
