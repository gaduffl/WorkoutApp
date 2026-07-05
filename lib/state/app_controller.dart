import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../engine/decision_engine.dart';
import '../engine/pain_engine.dart';
import '../engine/progression_engine.dart';
import '../engine/queue_engine.dart';
import '../models/check_in.dart';
import '../models/decision_trace.dart';
import '../models/exercise_state.dart';
import '../models/floor_category.dart';
import '../models/pain.dart';
import '../models/plan.dart';
import '../models/recovery_snapshot.dart';
import '../models/session_log.dart';
import '../models/session_type.dart';
import '../models/set_log.dart';
import '../models/user_settings.dart';

/// Ties the pure engine + persistence layer to the UI. All decision logic
/// stays in `engine/`; this only orchestrates load/save around it.
class AppController extends ChangeNotifier {
  final Repository repo;

  UserSettings settings = const UserSettings();
  QueueState queueState = const QueueState();
  Map<String, ExerciseState> exerciseStates = {};
  DecisionTrace? todayTrace;
  bool loading = true;

  AppController(this.repo);

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Future<void> init() async {
    settings = await repo.loadSettings();
    queueState = await repo.loadQueueState();
    exerciseStates = await repo.loadExerciseStates();
    todayTrace = await repo.loadDecisionTraceForDate(today());
    loading = false;
    notifyListeners();
  }

  Future<void> saveSettings(UserSettings newSettings) async {
    settings = newSettings;
    await repo.saveSettings(settings);
    notifyListeners();
  }

  Future<DecisionTrace> submitCheckIn({
    required int timeMinutes,
    required int subjective,
    List<PainFlag> pain = const [],
    RecoverySnapshot? recovery,
  }) async {
    final now = today();
    final checkin = CheckIn(
      date: now,
      timeMinutes: timeMinutes,
      subjective: subjective,
      pain: pain,
      timestamp: DateTime.now(),
    );
    await repo.saveCheckIn(checkin);
    if (recovery != null) await repo.saveRecoverySnapshot(recovery);

    final historyStart = now.subtract(const Duration(days: 60));
    final recoveryHistory = await repo.loadRecoverySnapshotsSince(historyStart);
    final checkinHistory = await repo.loadCheckInsSince(historyStart);
    final sessionLogs = await repo.loadSessionLogsSince(now.subtract(const Duration(days: 10)));

    final input = DecisionEngineInput(
      checkin: checkin,
      todaySnapshot: recovery,
      recoveryHistory: recoveryHistory,
      checkinHistory: checkinHistory,
      sessionLogs: sessionLogs,
      exerciseStates: exerciseStates,
      queueState: queueState,
      settings: settings,
      today: now,
    );
    final output = const DecisionEngine().decide(input);

    exerciseStates = output.patchedExerciseStates;
    await repo.saveExerciseStates(exerciseStates);
    await repo.saveDecisionTrace(output.trace);
    todayTrace = output.trace;
    notifyListeners();
    return output.trace;
  }

  Future<void> completeSession(
    SessionPlan plan,
    List<SetLog> loggedSets, {
    required int durationMinutes,
    bool rehitFinisherCompleted = false,
  }) async {
    const progression = ProgressionEngine();
    final now = today();

    final byTrack = <String, List<SetLog>>{};
    for (final s in loggedSets) {
      if (s.isWarmup) continue;
      byTrack.putIfAbsent(s.trackKey, () => []).add(s);
    }

    for (final entry in byTrack.entries) {
      final state = exerciseStates[entry.key];
      if (state == null) continue;
      exerciseStates[entry.key] = progression.evaluateSession(
        state,
        entry.value,
        equipmentConfig: settings.equipment,
        sessionDate: now,
      );
    }
    await repo.saveExerciseStates(exerciseStates);

    final def = sessionTypes[plan.sessionId]!;
    final countsAs = <FloorCategory>{};
    if (def.countsAs.contains(FloorCategory.strength)) countsAs.add(FloorCategory.strength);
    if (plan.sessionId == SessionTypeId.s2) {
      if (rehitFinisherCompleted) countsAs.add(FloorCategory.intensity);
    } else if (def.countsAs.contains(FloorCategory.intensity)) {
      countsAs.add(FloorCategory.intensity);
    }
    if (def.countsAs.contains(FloorCategory.aerobic)) countsAs.add(FloorCategory.aerobic);

    final log = SessionLog(
      id: '${now.toIso8601String()}-${plan.sessionId.name}-${DateTime.now().microsecondsSinceEpoch}',
      templateId: plan.sessionId,
      tier: plan.tier,
      date: now,
      setLogs: loggedSets,
      plannedWorkSets: plan.plannedWorkSets,
      completedWorkSets: loggedSets.where((s) => !s.isWarmup).length,
      durationMinutes: durationMinutes,
      countsAs: countsAs,
      rehitFinisherCompleted: rehitFinisherCompleted,
    );
    await repo.saveSessionLog(log);

    if (log.countsTowardQueueAndFloor) {
      queueState = const QueueEngine().advance(queueState, plan.sessionId);
      await repo.saveQueueState(queueState);
    }
    notifyListeners();
  }

  /// Marks a pain re-entry test (§7.2, 50% x 8) as passed pain-free, then
  /// resumes the pattern per §6.6's precedence rule.
  Future<void> markPainReentryTestPassed(String trackKey) async {
    final state = exerciseStates[trackKey];
    if (state == null) return;
    final next = const ProgressionEngine().resolvePostReentryResume(state, today(), settings.equipment);
    exerciseStates[trackKey] = next;
    await repo.saveExerciseState(next);
    notifyListeners();
  }

  Future<void> triggerManualDeload() async {
    exerciseStates = {
      for (final e in const ProgressionEngine().forceGlobalDeload(exerciseStates.values.toList())) e.trackKey: e,
    };
    await repo.saveExerciseStates(exerciseStates);
    notifyListeners();
  }

  static const painEngine = PainEngine();
}
