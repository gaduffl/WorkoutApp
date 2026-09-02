import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/analytics_event.dart';
import 'package:morningcoach/models/bouldering_log.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/user_settings.dart';
import 'package:morningcoach/state/app_controller.dart';

class _BoulderingRepository extends Repository {
  final List<BoulderingLog> bouldering = [];
  final List<SessionLog> sessions;
  final List<DecisionTrace> savedTraces = [];

  _BoulderingRepository({List<SessionLog> sessions = const []})
      : sessions = List.of(sessions),
        super(AppDatabase());

  @override
  Future<void> saveBoulderingLog(BoulderingLog log) async {
    bouldering.removeWhere((existing) => existing.id == log.id);
    bouldering.add(log);
  }

  @override
  Future<List<BoulderingLog>> loadBoulderingLogsSince(DateTime since) async =>
      bouldering.where((log) => !log.date.isBefore(since)).toList();

  @override
  Future<List<SessionLog>> loadSessionLogsSince(DateTime since) async =>
      sessions.where((log) => !log.date.isBefore(since)).toList();

  @override
  Future<List<RecoverySnapshot>> loadRecoverySnapshotsSince(
    DateTime since,
  ) async =>
      const [];

  @override
  Future<List<CheckIn>> loadCheckInsSince(DateTime since) async => const [];

  @override
  Future<void> saveExerciseStates(Map<String, ExerciseState> states) async {}

  @override
  Future<void> saveDecisionTrace(DecisionTrace trace) async {
    savedTraces.add(trace);
  }

  @override
  Future<void> saveAnalyticsEvent(AnalyticsEvent event) async {}
}

class _FixedDayController extends AppController {
  final DateTime fixedToday;

  _FixedDayController(super.repo, this.fixedToday) {
    loading = false;
  }

  @override
  DateTime today() => fixedToday;

  @override
  Future<void> syncNotifications() async {}
}

void main() {
  final today = DateTime(2026, 9, 2);

  DecisionTrace openTrace(List<SessionLog> sessions) =>
      const DecisionEngine()
          .decide(
            DecisionEngineInput(
              checkin: CheckIn(
                date: today,
                timeMinutes: 60,
                subjective: 4,
                timestamp: today.add(const Duration(hours: 8)),
              ),
              todaySnapshot: null,
              recoveryHistory: const [],
              checkinHistory: const [],
              sessionLogs: sessions,
              exerciseStates: const {},
              queueState: const QueueState(),
              settings: const UserSettings(),
              today: today,
            ),
          )
          .trace;

  test('yesterday entry immediately recalculates an open plan', () async {
    final sessions = <SessionLog>[
      for (final offset in [2, 3, 4])
        SessionLog(
          id: 'intensity-$offset',
          templateId: SessionTypeId.s7,
          tier: SessionTier.full,
          date: today.subtract(Duration(days: offset)),
          setLogs: const [],
          plannedWorkSets: 0,
          completedWorkSets: 0,
          durationMinutes: 9,
          countsAs: const {FloorCategory.intensity},
        ),
      SessionLog(
        id: 'base',
        templateId: SessionTypeId.s6,
        tier: SessionTier.full,
        date: today.subtract(const Duration(days: 5)),
        setLogs: const [],
        plannedWorkSets: 0,
        completedWorkSets: 0,
        durationMinutes: 60,
        countsAs: const {FloorCategory.aerobic},
      ),
    ];
    final repo = _BoulderingRepository(sessions: sessions);
    final controller = _FixedDayController(repo, today)
      ..todayTrace = openTrace(sessions);
    final before = controller.todayTrace!;

    final updatedToday = await controller.logBouldering(
      date: today.subtract(const Duration(days: 1)),
      durationMinutes: 90,
      effort: BoulderingEffort.hard,
    );

    expect(updatedToday, isTrue);
    expect(repo.bouldering, hasLength(1));
    expect(repo.savedTraces, hasLength(1));
    expect(controller.todayTrace, isNot(same(before)));
    final upper = controller.todayTrace!.candidates.firstWhere(
      (candidate) => candidate.sessionId == SessionTypeId.s2,
    );
    expect(upper.scoreTerms['muscleRecoveryDemotion'], lessThan(0));
    expect(controller.queueState.pointer, SessionTypeId.s1);
    expect(controller.queueState.served, isEmpty);
  });

  test('today entry after morning workout changes only the next plan', () async {
    final completed = SessionLog(
      id: 'primary-today',
      templateId: SessionTypeId.s5,
      tier: SessionTier.full,
      date: today,
      setLogs: const [],
      plannedWorkSets: 3,
      completedWorkSets: 3,
      durationMinutes: 35,
      countsAs: const {FloorCategory.strength},
    );
    final repo = _BoulderingRepository(sessions: [completed]);
    final controller = _FixedDayController(repo, today)
      ..todayTrace = openTrace(const [])
      ..replaceRecentLogsForTesting([completed]);
    final completedMorningTrace = controller.todayTrace;
    final statesBefore = Map<String, ExerciseState>.of(
      controller.exerciseStates,
    );

    final updatedToday = await controller.logBouldering(
      date: today,
      durationMinutes: 75,
      effort: BoulderingEffort.moderate,
    );

    expect(updatedToday, isFalse);
    expect(repo.bouldering.single.durationMinutes, 75);
    expect(repo.savedTraces, isEmpty);
    expect(controller.todayTrace, same(completedMorningTrace));
    expect(controller.exerciseStates, statesBefore);
    expect(controller.queueState.pointer, SessionTypeId.s1);
    expect(controller.queueState.served, isEmpty);
    expect(controller.sessionLoggedToday, isTrue);
  });

  test('saving the same day replaces that day without duplicating it', () async {
    final repo = _BoulderingRepository();
    final controller = _FixedDayController(repo, today);

    await controller.logBouldering(
      date: today,
      durationMinutes: 45,
      effort: BoulderingEffort.easy,
    );
    await controller.logBouldering(
      date: today,
      durationMinutes: 110,
      effort: BoulderingEffort.hard,
    );

    expect(repo.bouldering, hasLength(1));
    expect(repo.bouldering.single.durationMinutes, 110);
    expect(repo.bouldering.single.effort, BoulderingEffort.hard);
  });

  test('rejects dates outside today/yesterday and invalid durations', () async {
    final controller = _FixedDayController(_BoulderingRepository(), today);

    await expectLater(
      controller.logBouldering(
        date: today.subtract(const Duration(days: 2)),
        durationMinutes: 60,
        effort: BoulderingEffort.moderate,
      ),
      throwsArgumentError,
    );
    await expectLater(
      controller.logBouldering(
        date: today,
        durationMinutes: 0,
        effort: BoulderingEffort.moderate,
      ),
      throwsArgumentError,
    );
  });
}
