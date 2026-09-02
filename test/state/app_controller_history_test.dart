import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/cardio_engine.dart';
import 'package:morningcoach/models/bouldering_log.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/training_status.dart';
import 'package:morningcoach/models/training_targets.dart';
import 'package:morningcoach/state/app_controller.dart';

class _HistoryRepository extends Repository {
  final List<SessionLog> sessions;
  final List<BoulderingLog> bouldering;
  final List<RecoverySnapshot> recovery = const [];
  DateTime? sessionSince;
  DateTime? boulderingSince;
  DateTime? recoverySince;

  _HistoryRepository({
    List<SessionLog> sessions = const [],
    List<BoulderingLog> bouldering = const [],
  })  : sessions = List.of(sessions),
        bouldering = List.of(bouldering),
        super(AppDatabase());

  @override
  Future<List<SessionLog>> loadSessionLogsSince(DateTime since) async {
    sessionSince = since;
    return sessions.where((log) => !log.date.isBefore(since)).toList();
  }

  @override
  Future<void> saveSessionLog(SessionLog log) async {
    sessions.add(log);
  }

  @override
  Future<List<BoulderingLog>> loadBoulderingLogsSince(DateTime since) async {
    boulderingSince = since;
    return bouldering.where((log) => !log.date.isBefore(since)).toList();
  }

  @override
  Future<List<RecoverySnapshot>> loadRecoverySnapshotsSince(
    DateTime since,
  ) async {
    recoverySince = since;
    return recovery;
  }
}

void main() {
  test('history load covers the target window and builds immutable feedback',
      () async {
    final asOf = DateTime(2026, 7, 15, 18);
    final legacy4x4 = SessionLog(
      id: 'legacy-4x4',
      templateId: SessionTypeId.s3,
      tier: SessionTier.full,
      date: DateTime(2026, 7, 15),
      completedAt: asOf,
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: 35,
      countsAs: const {FloorCategory.intensity},
    );
    final bouldering = BoulderingLog(
      id: 'bouldering-2026-07-14',
      date: DateTime(2026, 7, 14),
      durationMinutes: 75,
      effort: BoulderingEffort.moderate,
    );
    final repo = _HistoryRepository(
      sessions: [legacy4x4],
      bouldering: [bouldering],
    );
    final controller = AppController(repo);

    final data = await controller.loadHistoryData(asOf: asOf);

    expect(repo.sessionSince, DateTime(2025, 7, 9));
    expect(repo.boulderingSince, DateTime(2025, 7, 9));
    expect(repo.recoverySince, DateTime(2026, 6, 17));
    expect(
      asOf.difference(repo.sessionSince!).inDays,
      greaterThanOrEqualTo(29),
    );
    expect(data.logs, hasLength(1));
    expect(data.boulderingLogs, hasLength(1));
    expect(
      data.ledger.muscle(MajorMuscleGroup.coreGrip).effectiveSets28d,
      1.875,
    );
    expect(data.ledger.asOf, asOf);
    expect(data.trainingStatus.asOf, asOf);
    expect(
      () => data.logs.add(legacy4x4),
      throwsUnsupportedError,
    );
    expect(
      () => data.boulderingLogs.add(bouldering),
      throwsUnsupportedError,
    );
    expect(
      () => data.targets.hardTimeWindowsMinutes.add(90),
      throwsUnsupportedError,
    );
  });

  test(
      'qualifying unplanned REHIT is returned by history and counts as one high-intensity day',
      () async {
    final repo = _HistoryRepository();
    final controller = AppController(repo);
    const cardio = CardioEngine();
    final prescription = cardio.prescriptionFor(
      sessionId: SessionTypeId.s7,
      durationMinutes: 9,
      heartRateMaxBpm: controller.settings.hrMax,
    );
    final completion = cardio.completionFromElapsedSeconds(
      prescription: prescription,
      completedWorkIntervals: 2,
      completedDurationSeconds: 520,
    );

    await controller.logUnplannedRehit(completion: completion);
    final data = await controller.loadHistoryData();

    expect(data.logs, hasLength(1));
    expect(data.logs.single.isUnplanned, isTrue);
    expect(
      data.ledger.protocol(CardioProtocolType.rehit).sessions7d,
      1,
    );
    final highIntensity = data.trainingStatus.aerobic.singleWhere(
      (status) => status.target == AerobicTargetKind.highIntensityDistinctDays,
    );
    expect(highIntensity.completedDistinctDays, 1);
    expect(highIntensity.distinctDayDeficit, 2);
    final fourByFour = data.trainingStatus.aerobic.singleWhere(
      (status) => status.target == AerobicTargetKind.norwegian4x4Preference,
    );
    expect(fourByFour.completedExposures, 0);
  });
}
