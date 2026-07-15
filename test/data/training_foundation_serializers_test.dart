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
      plannedDurationSeconds: 2100,
      targetHeartRateMinBpm: 150,
      targetHeartRateMaxBpm: 180,
      targetRpeMin: 8,
      targetRpeMax: 10,
    );
    const plan = SessionPlan(
      sessionId: SessionTypeId.s3,
      sessionName: 'Norwegian 4x4 (CAROL)',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 35,
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
    expect(restoredPrescription.protocol.name, 'Norwegian 4x4');
    expect(restoredPrescription.plannedWorkIntervals, 4);
    expect(restoredPrescription.plannedWorkSeconds, 960);
    expect(restoredPrescription.plannedRecoveryIntervals, 3);
    expect(restoredPrescription.plannedRecoverySeconds, 540);
    expect(restoredPrescription.plannedDurationSeconds, 2100);
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
      ),
    );

    final restoredLog = sessionLogFromJson(
      _throughJson(sessionLogToJson(log)),
    );
    expect(restoredLog.completedAt, completedAt);
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
      ..remove('completedAt');

    final restored = sessionLogFromJson(legacyLog);
    expect(restored.cardioCompletion, isNull);
    expect(restored.completedAt, DateTime(2026, 7, 14));
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
