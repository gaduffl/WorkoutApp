import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/training_status.dart';
import 'package:morningcoach/models/training_targets.dart';

Map<String, dynamic> _throughJson(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

void main() {
  test('structured cardio plan and completion round-trip exactly', () {
    const prescription = CardioPrescription(
      protocol: CardioProtocol.norwegian4x4,
      plannedWorkIntervals: 4,
      plannedWorkSeconds: 960,
      plannedRecoveryIntervals: 3,
      plannedRecoverySeconds: 540,
      plannedDurationSeconds: 1800,
      targetHeartRateMinBpm: 150,
      targetHeartRateMaxBpm: 180,
      targetRpeMin: 8,
      targetRpeMax: 10,
    );
    const plan = SessionPlan(
      sessionId: SessionTypeId.s3,
      sessionName: 'CAROL 4×4 Norwegian Zone 5 Intervals',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 30,
      cardioPrescription: prescription,
    );

    final restoredPlan = sessionPlanFromJson(
      _throughJson(sessionPlanToJson(plan)),
    );
    final restoredPrescription = restoredPlan.cardioPrescription!;
    expect(
      restoredPrescription.protocol.type,
      CardioProtocolType.norwegian4x4,
    );
    expect(
      restoredPrescription.protocol.name,
      'CAROL 4×4 Norwegian Zone 5 Intervals',
    );
    expect(restoredPrescription.plannedWorkIntervals, 4);
    expect(restoredPrescription.plannedWorkSeconds, 960);
    expect(restoredPrescription.plannedRecoveryIntervals, 3);
    expect(restoredPrescription.plannedRecoverySeconds, 540);
    expect(restoredPrescription.plannedDurationSeconds, 1800);
    expect(restoredPrescription.targetHeartRateMinBpm, 150);
    expect(restoredPrescription.targetHeartRateMaxBpm, 180);
    expect(restoredPrescription.targetRpeMin, 8);
    expect(restoredPrescription.targetRpeMax, 10);

    final completedAt = DateTime(2026, 7, 15, 7, 42, 13);
    final log = SessionLog(
      id: 'cardio-completion',
      templateId: SessionTypeId.s3,
      tier: SessionTier.full,
      date: DateTime(2026, 7, 15),
      completedAt: completedAt,
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: 31,
      countsAs: const {FloorCategory.intensity},
      cardioCompletedAsPrescribed: false,
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.norwegian4x4,
        completedWorkIntervals: 3,
        completedWorkSeconds: 720,
        completedRecoveryIntervals: 3,
        completedRecoverySeconds: 540,
        completedDurationSeconds: 1860,
        averageHeartRateBpm: 157,
        peakHeartRateBpm: 178,
        rpe: 9.5,
        fitnessScore: 41.5,
        peakPowerWatts: 712.5,
      ),
    );

    final restoredLog = sessionLogFromJson(
      _throughJson(sessionLogToJson(log)),
    );
    expect(restoredLog.completedAt, completedAt);
    expect(
      restoredLog.completedAtPrecision,
      CompletionTimePrecision.exact,
    );
    expect(
      restoredLog.cardioCompletion!.protocol.type,
      CardioProtocolType.norwegian4x4,
    );
    expect(restoredLog.cardioCompletion!.completedWorkIntervals, 3);
    expect(restoredLog.cardioCompletion!.completedWorkSeconds, 720);
    expect(restoredLog.cardioCompletion!.completedRecoveryIntervals, 3);
    expect(restoredLog.cardioCompletion!.completedRecoverySeconds, 540);
    expect(restoredLog.cardioCompletion!.completedDurationSeconds, 1860);
    expect(restoredLog.cardioCompletion!.averageHeartRateBpm, 157);
    expect(restoredLog.cardioCompletion!.peakHeartRateBpm, 178);
    expect(restoredLog.cardioCompletion!.rpe, 9.5);
    expect(restoredLog.cardioCompletion!.fitnessScore, 41.5);
    expect(restoredLog.cardioCompletion!.peakPowerWatts, 712.5);
    expect(restoredLog.cardioCompletedAsPrescribed, isFalse);

    final legacyJson = _throughJson(sessionLogToJson(log));
    final legacyCompletion =
        legacyJson['cardioCompletion'] as Map<String, dynamic>;
    legacyCompletion
      ..remove('fitnessScore')
      ..remove('peakPowerWatts');
    final restoredLegacyMetrics = sessionLogFromJson(legacyJson);
    expect(restoredLegacyMetrics.cardioCompletion!.fitnessScore, isNull);
    expect(restoredLegacyMetrics.cardioCompletion!.peakPowerWatts, isNull);
    expect(restoredLegacyMetrics.cardioCompletion!.averageHeartRateBpm, 157);
  });

  test('legacy plan and log JSON default all new fields safely', () {
    final legacyPlan = sessionPlanToJson(const SessionPlan(
      sessionId: SessionTypeId.s6,
      sessionName: 'Zone 2',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 60,
    ))..remove('cardioPrescription');
    expect(sessionPlanFromJson(legacyPlan).cardioPrescription, isNull);

    final legacyLog = sessionLogToJson(SessionLog(
      id: 'legacy',
      templateId: SessionTypeId.s6,
      tier: SessionTier.full,
      date: DateTime(2026, 7, 14),
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: 60,
      countsAs: const {FloorCategory.aerobic},
    ))
      ..remove('cardioCompletion')
      ..remove('cardioCompletedAsPrescribed')
      ..remove('completedAt')
      ..remove('completedAtPrecision')
      ..remove('isSupplemental')
      ..remove('isUnplanned');

    final restored = sessionLogFromJson(legacyLog);
    expect(restored.cardioCompletion, isNull);
    expect(restored.cardioCompletedAsPrescribed, isNull);
    expect(restored.isSupplemental, isFalse);
    expect(restored.isUnplanned, isFalse);
    expect(restored.completedAt, DateTime(2026, 7, 14));
    expect(
      restored.completedAtPrecision,
      CompletionTimePrecision.dateOnlyInferred,
    );
    final roundTrippedLegacy = sessionLogFromJson(
      _throughJson(sessionLogToJson(restored)),
    );
    expect(
      roundTrippedLegacy.completedAtPrecision,
      CompletionTimePrecision.dateOnlyInferred,
    );
    expect(restored.countsTowardQueueAndFloor, isTrue);
  });

  test('supplemental provenance round-trips and unplanned implies supplemental',
      () {
    SessionLog rehitLog({
      required String id,
      required bool isSupplemental,
      bool isUnplanned = false,
    }) =>
        SessionLog(
          id: id,
          templateId: SessionTypeId.s7,
          tier: SessionTier.full,
          date: DateTime(2026, 7, 15),
          completedAt: DateTime(2026, 7, 15, 18),
          setLogs: const [],
          plannedWorkSets: 0,
          completedWorkSets: 0,
          durationMinutes: 9,
          countsAs: const {FloorCategory.intensity},
          cardioCompletion: const CardioCompletion(
            protocol: CardioProtocol.rehit,
            completedWorkIntervals: 2,
            completedWorkSeconds: 40,
            completedRecoveryIntervals: 0,
            completedRecoverySeconds: 0,
            completedDurationSeconds: 520,
          ),
          cardioCompletedAsPrescribed: true,
          isSupplemental: isSupplemental,
          isUnplanned: isUnplanned,
        );

    final recommendedExtra = sessionLogFromJson(
      _throughJson(
        sessionLogToJson(
          rehitLog(id: 'recommended-extra', isSupplemental: true),
        ),
      ),
    );
    expect(recommendedExtra.isSupplemental, isTrue);
    expect(recommendedExtra.isUnplanned, isFalse);
    expect(recommendedExtra.completesTodaysPlan, isFalse);

    final unplanned = sessionLogFromJson(
      _throughJson(
        sessionLogToJson(
          rehitLog(
            id: 'unplanned',
            isSupplemental: true,
            isUnplanned: true,
          ),
        ),
      ),
    );
    expect(unplanned.isSupplemental, isTrue);
    expect(unplanned.isUnplanned, isTrue);

    final malformedUnplannedJson = sessionLogToJson(
      rehitLog(
        id: 'malformed-unplanned',
        isSupplemental: true,
        isUnplanned: true,
      ),
    )..remove('isSupplemental');
    final normalized = sessionLogFromJson(malformedUnplannedJson);
    expect(normalized.isUnplanned, isTrue);
    expect(normalized.isSupplemental, isTrue);
  });

  test('timestamp rows predating precision metadata remain exact', () {
    final completedAt = DateTime(2026, 7, 14, 18, 30);
    final json = sessionLogToJson(SessionLog(
      id: 'exact-before-precision-field',
      templateId: SessionTypeId.s7,
      tier: SessionTier.full,
      date: DateTime(2026, 7, 14),
      completedAt: completedAt,
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: 10,
      countsAs: const {FloorCategory.intensity},
    ))..remove('completedAtPrecision');

    final restored = sessionLogFromJson(json);
    expect(restored.completedAt, completedAt);
    expect(restored.completedAtPrecision, CompletionTimePrecision.exact);
  });

  test('serialized protocol mismatch fails closed without harming legacy logs', () {
    final malformed = SessionLog(
      id: 'mismatched-import',
      templateId: SessionTypeId.s3,
      tier: SessionTier.full,
      date: DateTime(2026, 7, 15),
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: 10,
      countsAs: const {FloorCategory.intensity},
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.rehit,
        completedWorkIntervals: 2,
        completedWorkSeconds: 40,
        completedRecoveryIntervals: 1,
        completedRecoverySeconds: 180,
        completedDurationSeconds: 600,
      ),
    );

    final restored = sessionLogFromJson(
      _throughJson(sessionLogToJson(malformed)),
    );
    expect(restored.cardioCompletion!.meetsCreditableDose, isTrue);
    expect(restored.cardioDoseQualifies, isFalse);
    expect(restored.countsTowardQueueAndFloor, isFalse);
  });

  test('personal targets round-trip without losing target bands', () {
    final restored = trainingTargetsFromJson(
      _throughJson(trainingTargetsToJson(TrainingTargets())),
    );

    expect(restored.hardTimeWindowsMinutes, [0, 20, 35, 60]);
    expect(restored.hypertrophyEvaluationWindowDays, 28);
    expect(restored.hypertrophyTargetBands.length, 9);
    expect(
      restored.hypertrophyTargetBands[MajorMuscleGroup.delts]!.center,
      10,
    );
    expect(restored.preferredNorwegian4x4Exposures, 1);
    expect(restored.fallbackRehitExposures, 2);
    expect(restored.baseShortExposureMinutes, [30, 35]);
  });

  test('partial persisted target bands are merged over personal defaults', () {
    final restored = trainingTargetsFromJson({
      'hypertrophyTargetBands': {
        'chest': {'minimum': 9, 'center': 11, 'maximum': 13},
      },
    });

    expect(restored.hypertrophyTargetBands.length, 9);
    expect(restored.hypertrophyTargetBands[MajorMuscleGroup.chest]!.center, 11);
    expect(restored.hypertrophyTargetBands[MajorMuscleGroup.back]!.center, 10);
  });

  test('training deficit snapshot round-trips as data', () {
    final status = TrainingStatus(
      asOf: DateTime(2026, 7, 15, 8),
      muscleEvaluationWindowDays: 28,
      muscle: const [
        MuscleTrainingStatus(
          muscleGroup: MajorMuscleGroup.back,
          completedEffectiveSets: 29.5,
          minimumTargetEffectiveSets: 32,
          centerTargetEffectiveSets: 40,
          maximumTargetEffectiveSets: 48,
          deficitToMinimumEffectiveSets: 2.5,
        ),
      ],
      aerobic: const [
        AerobicTrainingStatus(
          target: AerobicTargetKind.rehitSeparateDayFallback,
          rollingWindowDays: 7,
          completedExposures: 2,
          targetExposures: 2,
          exposureDeficit: 0,
          completedDistinctDays: 1,
          targetDistinctDays: 2,
          distinctDayDeficit: 1,
        ),
      ],
    );

    final restored = trainingStatusFromJson(
      _throughJson(trainingStatusToJson(status)),
    );
    expect(restored.asOf, DateTime(2026, 7, 15, 8));
    expect(restored.muscle.single.muscleGroup, MajorMuscleGroup.back);
    expect(restored.muscle.single.completedEffectiveSets, 29.5);
    expect(
      restored.aerobic.single.target,
      AerobicTargetKind.rehitSeparateDayFallback,
    );
    expect(restored.aerobic.single.distinctDayDeficit, 1);
  });
}
