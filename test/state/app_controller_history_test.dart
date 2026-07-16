import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/state/app_controller.dart';

class _HistoryRepository extends Repository {
  final List<SessionLog> sessions;
  final List<RecoverySnapshot> recovery = const [];
  DateTime? sessionSince;
  DateTime? recoverySince;

  _HistoryRepository({
    this.sessions = const [],
  }) : super(AppDatabase());

  @override
  Future<List<SessionLog>> loadSessionLogsSince(DateTime since) async {
    sessionSince = since;
    return sessions;
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
    final repo = _HistoryRepository(sessions: [legacy4x4]);
    final controller = AppController(repo);

    final data = await controller.loadHistoryData(asOf: asOf);

    expect(repo.sessionSince, DateTime(2026, 4, 22));
    expect(repo.recoverySince, DateTime(2026, 6, 17));
    expect(
      asOf.difference(repo.sessionSince!).inDays,
      greaterThanOrEqualTo(29),
    );
    expect(data.logs, hasLength(1));
    expect(data.ledger.asOf, asOf);
    expect(data.trainingStatus.asOf, asOf);
    expect(
      () => data.logs.add(legacy4x4),
      throwsUnsupportedError,
    );
    expect(
      () => data.targets.hardTimeWindowsMinutes.add(90),
      throwsUnsupportedError,
    );
  });
}
