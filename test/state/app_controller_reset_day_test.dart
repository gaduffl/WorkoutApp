import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String dateKey(DateTime d) => DateTime(d.year, d.month, d.day).toIso8601String();

  SessionLog logFor(DateTime d, String id) => SessionLog(
        id: id,
        templateId: SessionTypeId.s1,
        tier: SessionTier.full,
        date: d,
        setLogs: const [],
        plannedWorkSets: 1,
        completedWorkSets: 1,
        durationMinutes: 10,
        countsAs: const <FloorCategory>{},
      );

  group('deleteDayData scoping', () {
    test('deletes only today\'s dated rows and spares every other day', () async {
      final db = _ScopedMemoryDatabase();
      final repo = Repository(db);

      final today = DateTime(2026, 7, 28);
      final yesterday = DateTime(2026, 7, 27);
      // Same day-of-month, different month: a naive substring/LIKE bug on the
      // day number alone would wrongly delete this — it must survive.
      final lastMonth = DateTime(2026, 6, 28);

      for (final day in [today, yesterday, lastMonth]) {
        await db.putJson('check_ins', 'date', dateKey(day), {'date': dateKey(day)});
        await db.putJson(
            'recovery_snapshots', 'date', dateKey(day), {'date': dateKey(day)});
        await db.putJson(
            'decision_traces', 'date', dateKey(day), {'date': dateKey(day)});
        await db.putJsonWithDate(
            'session_logs', 'log-${day.month}-${day.day}', day, {'id': 'x'});
      }

      await repo.deleteDayData(today);

      for (final table in [
        'check_ins',
        'recovery_snapshots',
        'decision_traces',
        'session_logs',
      ]) {
        final remaining = await db.getAllJson(table);
        expect(remaining.length, 2,
            reason: '$table must keep yesterday + last month, drop only today');
      }

      // Today's specific rows are gone; the neighbours remain addressable.
      expect(await db.getJson('check_ins', 'date', dateKey(today)), isNull);
      expect(await db.getJson('check_ins', 'date', dateKey(yesterday)), isNotNull);
      expect(await db.getJson('check_ins', 'date', dateKey(lastMonth)), isNotNull);
    });
  });

  group('resetDay rollback', () {
    test('rolls progression + queue back to the day-start snapshot and clears '
        'today\'s data, without touching earlier days', () async {
      final db = _ScopedMemoryDatabase();
      final controller = _SilentController(Repository(db));
      final now = controller.today();

      // Start-of-day state: push-ups at ladder step 2.
      final startPush = ExerciseState(
        trackKey: MovementPattern.pushHorizontal.name,
        pattern: MovementPattern.pushHorizontal,
        ladderStepIndex: 2,
        currentLoad: 20,
      );
      const startQueue = QueueState(pointer: SessionTypeId.s2);
      controller.exerciseStates = {startPush.trackKey: startPush};
      controller.queueState = startQueue;
      await controller.repo.saveExerciseStates(controller.exerciseStates);
      await controller.repo.saveQueueState(startQueue);
      await controller.repo.saveDayStartSnapshot(
          now, controller.exerciseStates, startQueue);

      // A prior day's session log must survive the reset.
      final yesterday = now.subtract(const Duration(days: 1));
      await controller.repo.saveSessionLog(logFor(yesterday, 'log-yesterday'));

      // Simulate a day's worth of mutation: progression advanced, queue moved,
      // a brand-new track materialised (e.g. a pain substitute), plus today's
      // dated rows written.
      final advancedPush = startPush.clone()
        ..ladderStepIndex = 4
        ..currentLoad = 35;
      final newTrack = ExerciseState(
        trackKey: 'sub:pushHorizontal:incline',
        pattern: MovementPattern.pushHorizontal,
      );
      controller.exerciseStates = {
        advancedPush.trackKey: advancedPush,
        newTrack.trackKey: newTrack,
      };
      controller.queueState = const QueueState(pointer: SessionTypeId.s4);
      await controller.repo.saveExerciseStates(controller.exerciseStates);
      await controller.repo.saveQueueState(controller.queueState);
      await db.putJson(
          'check_ins', 'date', dateKey(now), {'date': dateKey(now)});
      await controller.repo.saveSessionLog(logFor(now, 'log-today'));

      await controller.resetDay();

      // Progression + queue rolled back to the snapshot.
      final rolledBack =
          controller.exerciseStates[MovementPattern.pushHorizontal.name]!;
      expect(rolledBack.ladderStepIndex, 2);
      expect(rolledBack.currentLoad, 20);
      expect(controller.queueState.pointer, SessionTypeId.s2);

      // The track that only existed today is gone from memory and disk.
      expect(controller.exerciseStates.containsKey('sub:pushHorizontal:incline'),
          isFalse);
      final persistedStates = await db.getAllJson('exercise_states');
      expect(
        persistedStates.any((r) => r['trackKey'] == 'sub:pushHorizontal:incline'),
        isFalse,
        reason: 'today-only track must be deleted from disk too',
      );

      // Today's dated rows are gone; yesterday's survive.
      expect(await db.getJson('check_ins', 'date', dateKey(now)), isNull);
      final logs = await db.getAllJson('session_logs');
      expect(logs.length, 1);
      expect(logs.single['id'], 'log-yesterday');

      // The snapshot itself is consumed.
      expect(await controller.repo.loadDayStartSnapshot(), isNull);
    });
  });

  group('setPatternProgression override', () {
    test('jumps a compound pattern to a chosen ladder step with clean state',
        () async {
      final controller = _SilentController(Repository(_ScopedMemoryDatabase()));
      const pattern = MovementPattern.pushHorizontal;
      final ladder = ladders[pattern]!;
      final targetIndex = ladder.steps.length - 1;

      await controller.setPatternProgression(pattern, targetIndex);

      final st = controller.exerciseStates[pattern.name]!;
      expect(st.ladderStepIndex, targetIndex);
      expect(st.status, ExerciseStatus.progress);
      expect(st.deloadSessionsRemaining, 0);
      expect(st.microStepStage, 0);
      expect(st.lastPrescriptionChange, contains('Set manually'));
      expect(controller.currentLadderIndex(pattern), targetIndex);

      // Persisted, so it survives a reload.
      final persisted = await controller.repo.loadExerciseStates();
      expect(persisted[pattern.name]!.ladderStepIndex, targetIndex);
    });

    test('clamps an out-of-range index to the ladder bounds', () async {
      final controller = _SilentController(Repository(_ScopedMemoryDatabase()));
      const pattern = MovementPattern.pushHorizontal;
      final ladder = ladders[pattern]!;

      await controller.setPatternProgression(pattern, 9999);
      expect(controller.currentLadderIndex(pattern), ladder.steps.length - 1);

      await controller.setPatternProgression(pattern, -5);
      expect(controller.currentLadderIndex(pattern), 0);
    });
  });
}

class _SilentController extends AppController {
  _SilentController(super.repository);

  @override
  Future<void> syncNotifications() async {}
}

/// In-memory [AppDatabase] that faithfully mirrors the real `LIKE 'prefix%'`
/// date-prefix delete against each row's stored date-column value, so the
/// scoping of "Reset day" is exercised for real.
class _ScopedMemoryDatabase extends AppDatabase {
  final Map<String, Map<String, Map<String, dynamic>>> _rows = {};
  final Map<String, Map<String, DateTime>> _dates = {};

  @override
  Future<void> putJson(
    String table,
    String keyColumn,
    String key,
    Map<String, dynamic> json,
  ) async {
    _rows.putIfAbsent(table, () => {})[key] = Map<String, dynamic>.from(json);
  }

  @override
  Future<void> putJsonWithDate(
    String table,
    String key,
    DateTime date,
    Map<String, dynamic> json,
  ) async {
    _rows.putIfAbsent(table, () => {})[key] = Map<String, dynamic>.from(json);
    _dates.putIfAbsent(table, () => {})[key] = date;
  }

  @override
  Future<Map<String, dynamic>?> getJson(
    String table,
    String keyColumn,
    String key,
  ) async {
    final row = _rows[table]?[key];
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  @override
  Future<List<Map<String, dynamic>>> getAllJson(String table) async =>
      _rows[table]
          ?.values
          .map((row) => Map<String, dynamic>.from(row))
          .toList() ??
      const [];

  @override
  Future<void> delete(String table, String keyColumn, String key) async {
    _rows[table]?.remove(key);
    _dates[table]?.remove(key);
  }

  @override
  Future<int> deleteByDatePrefix(
    String table,
    String dateColumn,
    String datePrefix,
  ) async {
    final rows = _rows[table];
    if (rows == null) return 0;
    final toRemove = <String>[];
    for (final entry in rows.entries) {
      // The date-column value is the DateTime passed to putJsonWithDate, or —
      // for putJson where the key IS the date column — the key itself.
      final columnValue =
          _dates[table]?[entry.key]?.toIso8601String() ?? entry.key;
      if (columnValue.startsWith(datePrefix)) toRemove.add(entry.key);
    }
    for (final key in toRemove) {
      rows.remove(key);
      _dates[table]?.remove(key);
    }
    return toRemove.length;
  }

  @override
  Future<List<Map<String, dynamic>>> getJsonSince(
    String table,
    String dateColumn,
    DateTime since,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (final entry
        in (_rows[table] ?? const <String, Map<String, dynamic>>{}).entries) {
      final date = _dates[table]?[entry.key] ??
          DateTime.tryParse(entry.value[dateColumn]?.toString() ?? '');
      if (date != null && !date.isBefore(since)) {
        rows.add(Map<String, dynamic>.from(entry.value));
      }
    }
    return rows;
  }
}
