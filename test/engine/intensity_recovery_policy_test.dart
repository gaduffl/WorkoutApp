import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/intensity_recovery_policy.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  const policy = IntensityRecoveryPolicy();
  final asOf = DateTime(2026, 5, 29, 9);

  SessionLog log({
    required SessionTypeId id,
    required DateTime completedAt,
    int durationMinutes = 0,
    Set<FloorCategory> countsAs = const {},
    CardioCompletion? cardioCompletion,
    bool rehitFinisherCompleted = false,
    int plannedWorkSets = 0,
    int completedWorkSets = 0,
  }) =>
      SessionLog(
        id: '${id.name}-${completedAt.toIso8601String()}',
        templateId: id,
        tier: SessionTier.full,
        date: DateTime(
          completedAt.year,
          completedAt.month,
          completedAt.day,
        ),
        completedAt: completedAt,
        setLogs: const [],
        plannedWorkSets: plannedWorkSets,
        completedWorkSets: completedWorkSets,
        durationMinutes: durationMinutes,
        countsAs: countsAs,
        cardioCompletion: cardioCompletion,
        rehitFinisherCompleted: rehitFinisherCompleted,
      );

  test('partial structured high-intensity work blocks recovery', () {
    final partialRehit = log(
      id: SessionTypeId.s7,
      completedAt: asOf.subtract(const Duration(hours: 1)),
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.rehit,
        completedWorkIntervals: 1,
        completedWorkSeconds: 10,
        completedRecoveryIntervals: 0,
        completedRecoverySeconds: 0,
        completedDurationSeconds: 60,
      ),
    );
    final partialFourByFour = log(
      id: SessionTypeId.s3,
      completedAt: asOf.subtract(const Duration(hours: 2)),
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.norwegian4x4,
        completedWorkIntervals: 1,
        completedWorkSeconds: 120,
        completedRecoveryIntervals: 0,
        completedRecoverySeconds: 0,
        completedDurationSeconds: 180,
      ),
    );

    expect(policy.isRecoveryRelevant(partialRehit), isTrue);
    expect(policy.isRecoveryRelevant(partialFourByFour), isTrue);
  });

  test('S2 finisher blocks even when the strength session is partial', () {
    final partialStrength = log(
      id: SessionTypeId.s2,
      completedAt: asOf.subtract(const Duration(hours: 1)),
      plannedWorkSets: 10,
      completedWorkSets: 1,
      rehitFinisherCompleted: true,
    );

    expect(partialStrength.completionRatio, lessThan(0.5));
    expect(policy.isRecoveryRelevant(partialStrength), isTrue);
  });

  test('malformed or zero-duration legacy intensity does not block', () {
    final zeroRehit = log(
      id: SessionTypeId.s7,
      completedAt: asOf.subtract(const Duration(hours: 1)),
      countsAs: const {FloorCategory.intensity},
    );
    final tooShortFourByFour = log(
      id: SessionTypeId.s3,
      completedAt: asOf.subtract(const Duration(hours: 1)),
      durationMinutes: 3,
      countsAs: const {FloorCategory.intensity},
    );
    final tooShortS2 = log(
      id: SessionTypeId.s2,
      completedAt: asOf.subtract(const Duration(hours: 1)),
      durationMinutes: 1,
      countsAs: const {FloorCategory.intensity},
    );

    expect(policy.isRecoveryRelevant(zeroRehit), isFalse);
    expect(policy.isRecoveryRelevant(tooShortFourByFour), isFalse);
    expect(policy.isRecoveryRelevant(tooShortS2), isFalse);
  });

  test('plausible legacy S3, S7, and S2 records block recovery', () {
    final fourByFour = log(
      id: SessionTypeId.s3,
      completedAt: asOf.subtract(const Duration(hours: 1)),
      durationMinutes: 4,
      countsAs: const {FloorCategory.intensity},
    );
    final rehit = log(
      id: SessionTypeId.s7,
      completedAt: asOf.subtract(const Duration(hours: 1)),
      durationMinutes: 1,
      countsAs: const {FloorCategory.intensity},
    );
    final s2Finisher = log(
      id: SessionTypeId.s2,
      completedAt: asOf.subtract(const Duration(hours: 1)),
      durationMinutes: 20,
      countsAs: const {FloorCategory.intensity},
    );
    final uncategorized = log(
      id: SessionTypeId.s7,
      completedAt: asOf.subtract(const Duration(hours: 1)),
      durationMinutes: 10,
    );

    expect(policy.isRecoveryRelevant(fourByFour), isTrue);
    expect(policy.isRecoveryRelevant(rehit), isTrue);
    expect(policy.isRecoveryRelevant(s2Finisher), isTrue);
    expect(policy.isRecoveryRelevant(uncategorized), isFalse);
  });

  test('window is exact, inclusive at 48h, and ignores future logs', () {
    SessionLog at(Duration age) => log(
          id: SessionTypeId.s7,
          completedAt: asOf.subtract(age),
          durationMinutes: 10,
          countsAs: const {FloorCategory.intensity},
        );

    expect(
      policy.hasRelevantIntensityInInclusiveWindow(
        [at(const Duration(hours: 47, minutes: 59, seconds: 59))],
        asOf: asOf,
      ),
      isTrue,
    );
    expect(
      policy.hasRelevantIntensityInInclusiveWindow(
        [at(const Duration(hours: 48))],
        asOf: asOf,
      ),
      isTrue,
    );
    expect(
      policy.hasRelevantIntensityInInclusiveWindow(
        [at(const Duration(hours: 48, microseconds: 1))],
        asOf: asOf,
      ),
      isFalse,
    );
    expect(
      policy.hasRelevantIntensityInInclusiveWindow(
        [
          log(
            id: SessionTypeId.s7,
            completedAt: asOf.add(const Duration(seconds: 1)),
            durationMinutes: 10,
            countsAs: const {FloorCategory.intensity},
          ),
        ],
        asOf: asOf,
      ),
      isFalse,
    );
  });

  test('date-only legacy recovery guard ages from local day end', () {
    final legacyDay = DateTime(2026, 5, 29);
    final legacy = SessionLog(
      id: 'legacy-date-only',
      templateId: SessionTypeId.s7,
      tier: SessionTier.full,
      date: legacyDay,
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: 10,
      countsAs: const {FloorCategory.intensity},
    );
    final dayEnd = DateTime(2026, 5, 29, 23, 59, 59, 999, 999);

    expect(
      legacy.completedAtPrecision,
      CompletionTimePrecision.dateOnlyInferred,
    );
    expect(policy.recoveryWindowCompletedAt(legacy), dayEnd);
    expect(
      policy.hasRelevantIntensityInInclusiveWindow(
        [legacy],
        asOf: dayEnd.add(const Duration(hours: 48)),
      ),
      isTrue,
    );
    expect(
      policy.hasRelevantIntensityInInclusiveWindow(
        [legacy],
        asOf: dayEnd.add(
          const Duration(hours: 48, microseconds: 1),
        ),
      ),
      isFalse,
    );
  });

  test('same-day inferred logs block while future inferred rows are ignored',
      () {
    SessionLog legacyOn(DateTime date) => SessionLog(
          id: 'legacy-${date.toIso8601String()}',
          templateId: SessionTypeId.s7,
          tier: SessionTier.full,
          date: date,
          setLogs: const [],
          plannedWorkSets: 0,
          completedWorkSets: 0,
          durationMinutes: 10,
          countsAs: const {FloorCategory.intensity},
        );

    expect(
      policy.hasRelevantIntensityInInclusiveWindow(
        [legacyOn(DateTime(2026, 5, 29))],
        asOf: DateTime(2026, 5, 29, 9),
      ),
      isTrue,
    );
    expect(
      policy.hasRelevantIntensityInInclusiveWindow(
        [legacyOn(DateTime(2026, 5, 30))],
        asOf: DateTime(2026, 5, 29, 23, 59),
      ),
      isFalse,
    );
  });
}
