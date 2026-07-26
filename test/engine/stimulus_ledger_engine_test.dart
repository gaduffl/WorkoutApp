import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/stimulus_ledger_engine.dart';
import 'package:morningcoach/engine/training_status_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/stimulus_ledger.dart';
import 'package:morningcoach/models/training_status.dart';
import 'package:morningcoach/models/training_targets.dart';

void main() {
  const engine = StimulusLedgerEngine();
  final asOf = DateTime(2026, 7, 15, 12);

  SetLog set({
    required String trackKey,
    required MovementPattern pattern,
    required String name,
    DateTime? timestamp,
    Rir rir = Rir.rir2,
    bool isWarmup = false,
    int value = 8,
  }) =>
      SetLog(
        trackKey: trackKey,
        pattern: pattern,
        exerciseName: name,
        weight: 20,
        value: value,
        rir: rir,
        isWarmup: isWarmup,
        timestamp: timestamp ?? asOf,
      );

  SessionLog strengthLog({
    required String id,
    required SessionTypeId templateId,
    required List<SetLog> sets,
    DateTime? completedAt,
    int? plannedWorkSets,
    int? completedWorkSets,
    Set<FloorCategory> countsAs = const {FloorCategory.strength},
  }) =>
      SessionLog(
        id: id,
        templateId: templateId,
        tier: SessionTier.full,
        date: DateTime(2026, 7, 15),
        completedAt: completedAt ?? asOf,
        setLogs: sets,
        plannedWorkSets: plannedWorkSets ?? sets.length,
        completedWorkSets: completedWorkSets ?? sets.length,
        durationMinutes: 35,
        countsAs: countsAs,
      );

  CardioProtocol cardioProtocol(CardioProtocolType type) => switch (type) {
        CardioProtocolType.norwegian4x4 => CardioProtocol.norwegian4x4,
        CardioProtocolType.zone2Base => CardioProtocol.zone2Base,
        CardioProtocolType.rehit => CardioProtocol.rehit,
      };

  CardioCompletion completion(
    CardioProtocolType type,
    int durationMinutes, {
    int? workIntervals,
    int? workSeconds,
  }) {
    final qualifyingIntervals = switch (type) {
      CardioProtocolType.norwegian4x4 => 4,
      CardioProtocolType.rehit => 2,
      CardioProtocolType.zone2Base => 0,
    };
    final qualifyingWorkSeconds = switch (type) {
      CardioProtocolType.norwegian4x4 => 960,
      CardioProtocolType.rehit => 40,
      CardioProtocolType.zone2Base => 0,
    };
    return CardioCompletion(
      protocol: cardioProtocol(type),
      completedWorkIntervals: workIntervals ?? qualifyingIntervals,
      completedWorkSeconds: workSeconds ?? qualifyingWorkSeconds,
      completedRecoveryIntervals: 0,
      completedRecoverySeconds: 0,
      completedDurationSeconds: durationMinutes * 60,
    );
  }

  SessionLog cardioLog({
    required String id,
    required SessionTypeId templateId,
    required DateTime completedAt,
    required int durationMinutes,
    required Set<FloorCategory> countsAs,
    SessionTier tier = SessionTier.full,
    CardioCompletion? cardioCompletion,
    bool rehitFinisherCompleted = false,
  }) =>
      SessionLog(
        id: id,
        templateId: templateId,
        tier: tier,
        date: DateTime(
          completedAt.year,
          completedAt.month,
          completedAt.day,
        ),
        completedAt: completedAt,
        setLogs: const [],
        plannedWorkSets: 0,
        completedWorkSets: 0,
        durationMinutes: durationMinutes,
        countsAs: countsAs,
        cardioCompletion: cardioCompletion,
        rehitFinisherCompleted: rehitFinisherCompleted,
      );

  group('completed strength stimulus', () {
    test('counts only logged non-warmup RIR 0 through RIR 3+ work', () {
      final log = strengthLog(
        id: 'partial-effort',
        templateId: SessionTypeId.s1,
        plannedWorkSets: 8,
        completedWorkSets: 4,
        sets: [
          for (final rir in const [
            Rir.rir0,
            Rir.rir1,
            Rir.rir2,
            Rir.rir3plus,
          ])
            set(
              trackKey: 'squat',
              pattern: MovementPattern.squat,
              name: 'Goblet squat',
              rir: rir,
            ),
          set(
            trackKey: 'squat',
            pattern: MovementPattern.squat,
            name: 'Goblet squat',
            rir: Rir.rir4plus,
          ),
          set(
            trackKey: 'squat',
            pattern: MovementPattern.squat,
            name: 'Goblet squat',
            rir: Rir.rir1,
            isWarmup: true,
          ),
          set(
            trackKey: 'squat',
            pattern: MovementPattern.squat,
            name: 'Goblet squat',
            rir: Rir.rir0,
            value: 0,
          ),
        ],
      );

      expect(log.countsTowardQueueAndFloor, isTrue);
      final result = engine.buildFromSessionLogs(logs: [log], asOf: asOf);
      expect(result.muscle(MajorMuscleGroup.quads).effectiveSets7d, 4);
      expect(result.muscle(MajorMuscleGroup.glutes).effectiveSets7d, 2);
    });

    test('a below-half partial still credits only its actually logged sets', () {
      final log = strengthLog(
        id: 'below-half',
        templateId: SessionTypeId.s2,
        plannedWorkSets: 6,
        completedWorkSets: 2,
        sets: [
          for (var i = 0; i < 2; i++)
            set(
              trackKey: 'pushHorizontal',
              pattern: MovementPattern.pushHorizontal,
              name: 'Push-up',
            ),
        ],
      );

      expect(log.countsTowardQueueAndFloor, isFalse);
      final result = engine.buildFromSessionLogs(logs: [log], asOf: asOf);
      expect(result.muscle(MajorMuscleGroup.chest).effectiveSets7d, 2);
      expect(result.muscle(MajorMuscleGroup.delts).effectiveSets7d, 1);
      expect(result.muscle(MajorMuscleGroup.triceps).effectiveSets7d, 1);
    });

    test('uses SessionLog.completedAt rather than individual set timestamps', () {
      final log = strengthLog(
        id: 'completion-time',
        templateId: SessionTypeId.s1,
        completedAt: asOf.subtract(const Duration(days: 8)),
        sets: [
          set(
            trackKey: 'hinge',
            pattern: MovementPattern.hinge,
            name: 'DB RDL',
            timestamp: asOf,
          ),
        ],
      );

      final result = engine.buildFromSessionLogs(logs: [log], asOf: asOf);
      expect(result.muscle(MajorMuscleGroup.hamstrings).effectiveSets7d, 0);
      expect(result.muscle(MajorMuscleGroup.hamstrings).effectiveSets28d, 1);
      expect(
        result.muscle(MajorMuscleGroup.hamstrings).daysSinceLastStimulus,
        8,
      );
    });

    test('S5 named accessories never inherit unrelated pattern credit', () {
      final log = strengthLog(
        id: 's5',
        templateId: SessionTypeId.s5,
        sets: [
          set(
            trackKey: 'sub:coreGrip:db_curl',
            pattern: MovementPattern.coreGrip,
            name: 'Alternating DB curl',
          ),
          set(
            trackKey: 'sub:pushVertical:lateral_raise',
            pattern: MovementPattern.pushVertical,
            name: 'Alternating lateral raise',
          ),
          set(
            trackKey: 'sub:pushVertical:overhead_triceps',
            pattern: MovementPattern.pushVertical,
            name: 'Alternating overhead triceps extension',
          ),
          set(
            trackKey: 'coreGrip',
            pattern: MovementPattern.coreGrip,
            name: 'Plank',
          ),
        ],
      );

      final result = engine.buildFromSessionLogs(logs: [log], asOf: asOf);
      expect(result.muscle(MajorMuscleGroup.biceps).effectiveSets7d, 1);
      expect(result.muscle(MajorMuscleGroup.delts).effectiveSets7d, 1);
      expect(result.muscle(MajorMuscleGroup.triceps).effectiveSets7d, 1);
      expect(result.muscle(MajorMuscleGroup.coreGrip).effectiveSets7d, 1);
      for (final unrelated in const [
        MajorMuscleGroup.quads,
        MajorMuscleGroup.glutes,
        MajorMuscleGroup.hamstrings,
        MajorMuscleGroup.chest,
        MajorMuscleGroup.back,
      ]) {
        expect(result.muscle(unrelated).effectiveSets7d, 0);
      }
    });

    test('unknown substitute tracks do not inherit their broad pattern', () {
      final log = strengthLog(
        id: 'unknown-named',
        templateId: SessionTypeId.s5,
        sets: [
          set(
            trackKey: 'sub:pushVertical:unknown_accessory',
            pattern: MovementPattern.pushVertical,
            name: 'Unmapped named accessory',
          ),
        ],
      );

      final result = engine.buildFromSessionLogs(logs: [log], asOf: asOf);
      expect(
        MajorMuscleGroup.values.every(
          (muscle) => result.muscle(muscle).effectiveSets7d == 0,
        ),
        isTrue,
      );
    });

    test('cardio-only templates cannot emit imported muscle stimulus', () {
      final malformed = strengthLog(
        id: 'malformed-cardio-sets',
        templateId: SessionTypeId.s3,
        countsAs: const {FloorCategory.intensity},
        sets: [
          set(
            trackKey: 'squat',
            pattern: MovementPattern.squat,
            name: 'Malformed imported squat',
          ),
        ],
      );

      final result = engine.buildFromSessionLogs(
        logs: [malformed],
        asOf: asOf,
      );
      expect(
        MajorMuscleGroup.values.every(
          (muscle) => result.muscle(muscle).effectiveSets28d == 0,
        ),
        isTrue,
      );
    });
  });

  group('protocol-specific cardio stimulus', () {
    test('Norwegian 4x4, base, and REHIT remain distinct', () {
      final logs = [
        cardioLog(
          id: '4x4',
          templateId: SessionTypeId.s3,
          completedAt: asOf,
          durationMinutes: 35,
          countsAs: const {FloorCategory.intensity},
          cardioCompletion:
              completion(CardioProtocolType.norwegian4x4, 35),
        ),
        cardioLog(
          id: 'base',
          templateId: SessionTypeId.s6,
          completedAt: asOf,
          durationMinutes: 60,
          countsAs: const {FloorCategory.aerobic},
          cardioCompletion: completion(CardioProtocolType.zone2Base, 60),
        ),
        cardioLog(
          id: 'rehit',
          templateId: SessionTypeId.s7,
          completedAt: asOf,
          durationMinutes: 10,
          countsAs: const {FloorCategory.intensity},
          cardioCompletion: completion(CardioProtocolType.rehit, 10),
        ),
      ];

      final result = engine.buildFromSessionLogs(logs: logs, asOf: asOf);
      expect(
        result.protocol(CardioProtocolType.norwegian4x4).sessions7d,
        1,
      );
      expect(result.protocol(CardioProtocolType.zone2Base).sessions7d, 1);
      expect(result.protocol(CardioProtocolType.rehit).sessions7d, 1);
    });

    test('structured protocol/template mismatches fail closed', () {
      final mismatches = [
        cardioLog(
          id: 's3-rehit-mismatch',
          templateId: SessionTypeId.s3,
          completedAt: asOf,
          durationMinutes: 60,
          countsAs: const {
            FloorCategory.intensity,
            FloorCategory.aerobic,
          },
          cardioCompletion: completion(CardioProtocolType.rehit, 10),
        ),
        cardioLog(
          id: 's6-4x4-mismatch',
          templateId: SessionTypeId.s6,
          completedAt: asOf,
          durationMinutes: 35,
          countsAs: const {FloorCategory.aerobic},
          cardioCompletion:
              completion(CardioProtocolType.norwegian4x4, 35),
        ),
        cardioLog(
          id: 's7-base-mismatch',
          templateId: SessionTypeId.s7,
          completedAt: asOf,
          durationMinutes: 30,
          countsAs: const {FloorCategory.intensity},
          cardioCompletion: completion(CardioProtocolType.zone2Base, 30),
        ),
        cardioLog(
          id: 's1-rehit-mismatch',
          templateId: SessionTypeId.s1,
          completedAt: asOf,
          durationMinutes: 10,
          countsAs: const {FloorCategory.strength},
          cardioCompletion: completion(CardioProtocolType.rehit, 10),
        ),
        cardioLog(
          id: 's2-nonextended-rehit-mismatch',
          templateId: SessionTypeId.s2,
          completedAt: asOf,
          durationMinutes: 60,
          countsAs: const {
            FloorCategory.strength,
            FloorCategory.intensity,
          },
          cardioCompletion: completion(CardioProtocolType.rehit, 10),
        ),
      ];
      final result = engine.buildFromSessionLogs(
        logs: mismatches,
        asOf: asOf,
      );
      expect(
        result.protocol(CardioProtocolType.norwegian4x4).sessions7d,
        0,
      );
      expect(result.protocol(CardioProtocolType.zone2Base).sessions7d, 0);
      expect(result.protocol(CardioProtocolType.rehit).sessions7d, 0);
    });

    test('structured extended S2 REHIT finisher remains creditable', () {
      final result = engine.buildFromSessionLogs(
        logs: [
          cardioLog(
            id: 's2-extended-rehit',
            templateId: SessionTypeId.s2,
            tier: SessionTier.extended,
            completedAt: asOf,
            durationMinutes: 60,
            countsAs: const {
              FloorCategory.strength,
              FloorCategory.intensity,
            },
            cardioCompletion: completion(CardioProtocolType.rehit, 10),
          ),
        ],
        asOf: asOf,
      );

      expect(result.protocol(CardioProtocolType.rehit).sessions7d, 1);
      expect(result.protocol(CardioProtocolType.rehit).durationMinutes7d, 10);
    });

    test('partial structured attempts cannot satisfy target deficits', () {
      final partialLedger = engine.buildFromSessionLogs(
        logs: [
          cardioLog(
            id: 'partial-4x4-intervals',
            templateId: SessionTypeId.s3,
            completedAt: asOf,
            durationMinutes: 35,
            countsAs: const {FloorCategory.intensity},
            cardioCompletion: completion(
              CardioProtocolType.norwegian4x4,
              35,
              workIntervals: 3,
              workSeconds: 960,
            ),
          ),
          cardioLog(
            id: 'partial-4x4-work',
            templateId: SessionTypeId.s3,
            completedAt: asOf,
            durationMinutes: 35,
            countsAs: const {FloorCategory.intensity},
            cardioCompletion: completion(
              CardioProtocolType.norwegian4x4,
              35,
              workIntervals: 4,
              workSeconds: 959,
            ),
          ),
          cardioLog(
            id: 'partial-rehit-intervals',
            templateId: SessionTypeId.s7,
            completedAt: asOf,
            durationMinutes: 10,
            countsAs: const {FloorCategory.intensity},
            cardioCompletion: completion(
              CardioProtocolType.rehit,
              10,
              workIntervals: 1,
              workSeconds: 40,
            ),
          ),
          cardioLog(
            id: 'partial-rehit-work',
            templateId: SessionTypeId.s7,
            completedAt: asOf,
            durationMinutes: 10,
            countsAs: const {FloorCategory.intensity},
            cardioCompletion: completion(
              CardioProtocolType.rehit,
              10,
              workIntervals: 2,
              workSeconds: 39,
            ),
          ),
          cardioLog(
            id: 'partial-base',
            templateId: SessionTypeId.s6,
            completedAt: asOf,
            durationMinutes: 29,
            countsAs: const {FloorCategory.aerobic},
            cardioCompletion: completion(CardioProtocolType.zone2Base, 29),
          ),
        ],
        asOf: asOf,
      );
      final partialStatus = const TrainingStatusEngine().build(
        targets: TrainingTargets(),
        ledger: partialLedger,
      );
      AerobicTrainingStatus target(AerobicTargetKind kind) =>
          partialStatus.aerobic.firstWhere((entry) => entry.target == kind);

      expect(
        target(AerobicTargetKind.highIntensityDistinctDays).distinctDayDeficit,
        3,
      );
      expect(
        target(AerobicTargetKind.norwegian4x4Preference).exposureDeficit,
        1,
      );
      expect(target(AerobicTargetKind.longBaseExposure).exposureDeficit, 1);

      final qualifyingLedger = engine.buildFromSessionLogs(
        logs: [
          cardioLog(
            id: 'complete-4x4',
            templateId: SessionTypeId.s3,
            completedAt: asOf,
            durationMinutes: 35,
            countsAs: const {FloorCategory.intensity},
            cardioCompletion:
                completion(CardioProtocolType.norwegian4x4, 35),
          ),
        ],
        asOf: asOf,
      );
      final qualifyingStatus = const TrainingStatusEngine().build(
        targets: TrainingTargets(),
        ledger: qualifyingLedger,
      );
      expect(
        qualifyingStatus.aerobic
            .firstWhere(
              (entry) =>
                  entry.target == AerobicTargetKind.norwegian4x4Preference,
            )
            .exposureDeficit,
        0,
      );
    });

    test('legacy logs retain template/duration inference when completion is null', () {
      final logs = [
        cardioLog(
          id: 'legacy-4x4',
          templateId: SessionTypeId.s3,
          completedAt: asOf,
          durationMinutes: 30,
          countsAs: const {FloorCategory.intensity},
        ),
        cardioLog(
          id: 'legacy-4x4-too-short',
          templateId: SessionTypeId.s3,
          completedAt: asOf,
          durationMinutes: 29,
          countsAs: const {FloorCategory.intensity},
        ),
        cardioLog(
          id: 'legacy-base',
          templateId: SessionTypeId.s6,
          completedAt: asOf,
          durationMinutes: 30,
          countsAs: const {FloorCategory.aerobic},
        ),
        cardioLog(
          id: 'legacy-rehit',
          templateId: SessionTypeId.s7,
          completedAt: asOf,
          durationMinutes: 5,
          countsAs: const {FloorCategory.intensity},
        ),
        cardioLog(
          id: 'legacy-rehit-too-short',
          templateId: SessionTypeId.s7,
          completedAt: asOf,
          durationMinutes: 4,
          countsAs: const {FloorCategory.intensity},
        ),
        cardioLog(
          id: 'legacy-s2-finisher',
          templateId: SessionTypeId.s2,
          completedAt: asOf,
          durationMinutes: 60,
          countsAs: const {
            FloorCategory.strength,
            FloorCategory.intensity,
          },
          rehitFinisherCompleted: true,
        ),
      ];

      final result = engine.buildFromSessionLogs(logs: logs, asOf: asOf);
      expect(
        result.protocol(CardioProtocolType.norwegian4x4).sessions7d,
        1,
      );
      expect(result.protocol(CardioProtocolType.zone2Base).sessions7d, 1);
      expect(result.protocol(CardioProtocolType.rehit).sessions7d, 2);
      expect(result.protocol(CardioProtocolType.rehit).durationMinutes7d, 14);
    });

    test('two same-day REHIT sessions count as one distinct day', () {
      final logs = [
        for (final hour in const [8, 17])
          cardioLog(
            id: 'rehit-$hour',
            templateId: SessionTypeId.s7,
            completedAt: DateTime(2026, 7, 14, hour),
            durationMinutes: 10,
            countsAs: const {FloorCategory.intensity},
            cardioCompletion: completion(CardioProtocolType.rehit, 10),
          ),
      ];

      final result = engine.buildFromSessionLogs(logs: logs, asOf: asOf);
      expect(result.protocol(CardioProtocolType.rehit).sessions7d, 2);
      expect(result.protocol(CardioProtocolType.rehit).separateDays7d, 1);
      expect(result.separateDayRehitCount7d, 1);
    });

    test('duration lists are immutable and thresholds are generic', () {
      final result = engine.build(
        muscleEvents: const [],
        aerobicEvents: [
          for (final duration in const [30, 35, 59, 60])
            AerobicStimulusEvent(
              sourceId: 'base-$duration',
              protocol: CardioProtocolType.zone2Base,
              performedAt: asOf,
              durationMinutes: duration,
            ),
        ],
        asOf: asOf,
      );
      final base = result.protocol(CardioProtocolType.zone2Base);

      expect(base.sessionsAtLeastMinutes(7, 30), 4);
      expect(base.sessionsAtLeastMinutes7d(35), 3);
      expect(base.sessionsAtLeastMinutes28d(60), 1);
      expect(() => base.sessionsAtLeastMinutes(7, 0), throwsArgumentError);
      expect(
        () => base.sessionDurations7d.add(90),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  test('rolling intervals include exact boundaries and exclude one second older', () {
    final result = engine.build(
      muscleEvents: [
        for (final offset in [
          Duration.zero,
          const Duration(days: 7),
          const Duration(days: 7, seconds: 1),
          const Duration(days: 28),
          const Duration(days: 28, seconds: 1),
        ])
          MuscleStimulusEvent(
            sourceId: 'event-${offset.inSeconds}',
            performedAt: asOf.subtract(offset),
            effectiveSets: const {MajorMuscleGroup.quads: 1},
          ),
      ],
      aerobicEvents: const [],
      asOf: asOf,
    );

    expect(result.muscle(MajorMuscleGroup.quads).effectiveSets7d, 2);
    expect(result.muscle(MajorMuscleGroup.quads).effectiveSets28d, 4);
  });
}
