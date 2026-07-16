import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/engine/cardio_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  const engine = CardioEngine();

  group('prescriptions', () {
    test('Norwegian 4x4 carries the exact work, recovery, HR, and RPE dose', () {
      final prescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s3,
        durationMinutes: 30,
        heartRateMaxBpm: 200,
      );

      expect(prescription.protocol.type, CardioProtocolType.norwegian4x4);
      expect(prescription.plannedDurationSeconds, 1800);
      expect(prescription.plannedWorkIntervals, 4);
      expect(prescription.plannedWorkSeconds, 960);
      expect(prescription.plannedRecoveryIntervals, 3);
      expect(prescription.plannedRecoverySeconds, 540);
      expect(prescription.targetHeartRateMinBpm, 170);
      expect(prescription.targetHeartRateMaxBpm, 190);
      expect(prescription.targetRpeMin, 8);
      expect(prescription.targetRpeMax, 9);
    });

    test('base work is continuous and exactly matches its hard slot', () {
      for (final minutes in [35, 60]) {
        final prescription = engine.prescriptionFor(
          sessionId: SessionTypeId.s6,
          durationMinutes: minutes,
          heartRateMaxBpm: 200,
        );
        expect(prescription.protocol.type, CardioProtocolType.zone2Base);
        expect(prescription.plannedWorkIntervals, 1);
        expect(prescription.plannedWorkSeconds, minutes * 60);
        expect(prescription.plannedRecoveryIntervals, 0);
        expect(prescription.plannedRecoverySeconds, 0);
        expect(prescription.plannedDurationSeconds, minutes * 60);
        expect(prescription.targetHeartRateMinBpm, 130);
        expect(prescription.targetHeartRateMaxBpm, 150);
        expect(prescription.targetRpeMin, 3);
        expect(prescription.targetRpeMax, 4);
      }
    });

    test('CAROL REHIT records only its two sprints and fixed preset minimum',
        () {
      final prescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s7,
        durationMinutes: 5,
        heartRateMaxBpm: 200,
      );

      expect(prescription.protocol.type, CardioProtocolType.rehit);
      expect(prescription.plannedDurationSeconds, 300);
      expect(prescription.plannedWorkIntervals, 2);
      expect(prescription.plannedWorkSeconds, 40);
      expect(prescription.plannedRecoveryIntervals, 0);
      expect(prescription.plannedRecoverySeconds, 0);
      expect(prescription.targetHeartRateMinBpm, isNull);
      expect(prescription.targetHeartRateMaxBpm, isNull);
      expect(prescription.targetRpeMin, 9);
      expect(prescription.targetRpeMax, 10);
    });

    test('runtime resolution preserves only valid duration-scaled Zone 2', () {
      final storedZone2 = engine.prescriptionFor(
        sessionId: SessionTypeId.s6,
        durationMinutes: 20,
        heartRateMaxBpm: 180,
      );
      expect(
        engine.resolvePrescription(
          sessionId: SessionTypeId.s6,
          persistedPrescription: storedZone2,
          durationMinutes: 35,
          heartRateMaxBpm: 180,
        ),
        same(storedZone2),
      );

      final rebuilt = engine.resolvePrescription(
        sessionId: SessionTypeId.s6,
        persistedPrescription: engine.prescriptionFor(
          sessionId: SessionTypeId.s7,
          durationMinutes: 9,
          heartRateMaxBpm: 180,
        ),
        durationMinutes: 35,
        heartRateMaxBpm: 180,
      );
      expect(rebuilt.protocol.type, CardioProtocolType.zone2Base);
      expect(rebuilt.plannedDurationSeconds, 35 * 60);
    });
  });

  group('CAROL-owned preset validation', () {
    test('4x4 validates recorded work/recovery without invented segments', () {
      final prescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s3,
        durationMinutes: 30,
        heartRateMaxBpm: 180,
      );

      expect(
        () => engine.completionFromEntry(
          prescription: prescription,
          completedWorkIntervals: 4,
          completedDurationMinutes: 24,
        ),
        throwsArgumentError,
      );

      final structuralMinimum = engine.completionFromEntry(
        prescription: prescription,
        completedWorkIntervals: 4,
        completedDurationMinutes: 25,
      );
      expect(structuralMinimum.meetsCreditableDose, isTrue);
      expect(
        structuralMinimum.completesPrescription(prescription),
        isFalse,
      );

      final fullPlan = engine.completionFromEntry(
        prescription: prescription,
        completedWorkIntervals: 4,
        completedDurationMinutes: 30,
      );
      expect(fullPlan.meetsCreditableDose, isTrue);
      expect(fullPlan.completesPrescription(prescription), isTrue);
    });

    test('REHIT leaves bike-owned timing opaque and defaults to five minutes',
        () {
      final prescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s7,
        durationMinutes: 20,
        heartRateMaxBpm: 180,
      );

      expect(
        () => engine.completionFromElapsedSeconds(
          prescription: prescription,
          completedWorkIntervals: 2,
          completedDurationSeconds: 39,
        ),
        throwsArgumentError,
      );
      final observedPartialPreset = engine.completionFromElapsedSeconds(
        prescription: prescription,
        completedWorkIntervals: 2,
        completedDurationSeconds: 40,
      );
      expect(observedPartialPreset.completedRecoveryIntervals, 0);
      expect(observedPartialPreset.completedRecoverySeconds, 0);
      expect(observedPartialPreset.meetsCreditableDose, isTrue);
      expect(
        observedPartialPreset.completesPrescription(prescription),
        isFalse,
      );

      final fullPlan = engine.completionFromEntry(
        prescription: prescription,
        completedWorkIntervals: 2,
        completedDurationMinutes: 5,
      );
      expect(fullPlan.meetsCreditableDose, isTrue);
      expect(fullPlan.completesPrescription(prescription), isTrue);

      final bikeUpperRange = engine.completionFromElapsedSeconds(
        prescription: prescription,
        completedWorkIntervals: 2,
        completedDurationSeconds: 8 * 60 + 40,
      );
      expect(bikeUpperRange.completedDurationSeconds, 520);
      expect(bikeUpperRange.completesPrescription(prescription), isTrue);
    });

    test('continuous Zone 2 validation remains unchanged', () {
      final prescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s6,
        durationMinutes: 20,
        heartRateMaxBpm: 180,
      );
      expect(
        engine
            .completionFromEntry(
              prescription: prescription,
              completedWorkIntervals: 1,
              completedDurationMinutes: 20,
            )
            .completesPrescription(prescription),
        isTrue,
      );
    });
  });

  group('structured completion credit', () {
    SessionLog log(
      SessionTypeId id,
      CardioCompletion? completion, {
      Set<FloorCategory> countsAs = const {FloorCategory.intensity},
      bool? completedAsPrescribed,
      bool isSupplemental = false,
      bool isUnplanned = false,
    }) =>
        SessionLog(
          id: 'test-${id.name}-${completion?.completedWorkSeconds}',
          templateId: id,
          tier: SessionTier.full,
          date: DateTime(2026, 7, 15),
          setLogs: const [],
          plannedWorkSets: 0,
          completedWorkSets: 0,
          durationMinutes: completion == null
              ? 35
              : (completion.completedDurationSeconds + 59) ~/ 60,
          countsAs: countsAs,
          cardioCompletion: completion,
          cardioCompletedAsPrescribed: completedAsPrescribed,
          isSupplemental: isSupplemental,
          isUnplanned: isUnplanned,
        );

    test('partial 4x4 persists but does not count or advance', () {
      final prescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s3,
        durationMinutes: 30,
        heartRateMaxBpm: 180,
      );
      final partial = engine.completionFromEntry(
        prescription: prescription,
        completedWorkIntervals: 3,
        completedDurationMinutes: 30,
      );
      final attempt = log(SessionTypeId.s3, partial);

      expect(partial.meetsCreditableDose, isFalse);
      expect(attempt.countsTowardQueueAndFloor, isFalse);
      expect(attempt.completionRatio, 0);
    });

    test('all prescribed 4x4 and REHIT intervals earn credit', () {
      for (final id in [SessionTypeId.s3, SessionTypeId.s7]) {
        final prescription = engine.prescriptionFor(
          sessionId: id,
          durationMinutes: id == SessionTypeId.s3 ? 30 : 5,
          heartRateMaxBpm: 180,
        );
        final completion = engine.completionFromEntry(
          prescription: prescription,
          completedWorkIntervals: prescription.plannedWorkIntervals,
          completedDurationMinutes: prescription.plannedDurationSeconds ~/ 60,
        );

        expect(completion.meetsCreditableDose, isTrue, reason: id.name);
        expect(
          log(id, completion).countsTowardQueueAndFloor,
          isTrue,
          reason: id.name,
        );
      }
    });

    test('base exposure needs 30 continuous minutes', () {
      final shortPrescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s6,
        durationMinutes: 20,
        heartRateMaxBpm: 180,
      );
      final short = engine.completionFromEntry(
        prescription: shortPrescription,
        completedWorkIntervals: 1,
        completedDurationMinutes: 20,
      );
      final fullPrescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s6,
        durationMinutes: 35,
        heartRateMaxBpm: 180,
      );
      final full = engine.completionFromEntry(
        prescription: fullPrescription,
        completedWorkIntervals: 1,
        completedDurationMinutes: 30,
      );
      final completedFullPlan = engine.completionFromEntry(
        prescription: fullPrescription,
        completedWorkIntervals: 1,
        completedDurationMinutes: 35,
      );

      expect(short.meetsCreditableDose, isFalse);
      expect(log(SessionTypeId.s6, short).countsTowardQueueAndFloor, isFalse);
      expect(short.completesPrescription(shortPrescription), isTrue);
      expect(short.completesPrescription(fullPrescription), isFalse);
      expect(full.meetsCreditableDose, isTrue);
      expect(full.completesPrescription(fullPrescription), isFalse);
      expect(log(SessionTypeId.s6, full).countsTowardQueueAndFloor, isTrue);
      expect(
        completedFullPlan.completesPrescription(fullPrescription),
        isTrue,
      );

      final prescribedRecovery = log(
        SessionTypeId.s6,
        short,
        countsAs: const {},
        completedAsPrescribed: true,
      );
      final partialLongPlan = log(
        SessionTypeId.s6,
        short,
        countsAs: const {},
        completedAsPrescribed: false,
      );
      expect(prescribedRecovery.completesTodaysPlan, isTrue);
      expect(prescribedRecovery.countsTowardQueueAndFloor, isFalse);
      expect(partialLongPlan.completesTodaysPlan, isFalse);
    });

    test('legacy cardio logs remain historical qualifying records', () {
      final legacy = log(SessionTypeId.s3, null);
      expect(legacy.cardioDoseQualifies, isTrue);
      expect(legacy.countsTowardQueueAndFloor, isTrue);
    });

    test('supplemental dose counts without completing the primary plan', () {
      final prescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s7,
        durationMinutes: 5,
        heartRateMaxBpm: 180,
      );
      final completion = engine.completionFromEntry(
        prescription: prescription,
        completedWorkIntervals: 2,
        completedDurationMinutes: 5,
      );
      final recommendedExtra = log(
        SessionTypeId.s7,
        completion,
        completedAsPrescribed: true,
        isSupplemental: true,
      );
      final unplanned = log(
        SessionTypeId.s7,
        completion,
        completedAsPrescribed: true,
        isSupplemental: true,
        isUnplanned: true,
      );

      expect(recommendedExtra.countsTowardQueueAndFloor, isTrue);
      expect(recommendedExtra.completesTodaysPlan, isFalse);
      expect(recommendedExtra.isUnplanned, isFalse);
      expect(unplanned.countsTowardQueueAndFloor, isTrue);
      expect(unplanned.completesTodaysPlan, isFalse);
      expect(unplanned.isSupplemental, isTrue);
      expect(unplanned.isUnplanned, isTrue);
    });

    test('mismatched session and completion protocol is rejected', () {
      final rehitPrescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s7,
        durationMinutes: 5,
        heartRateMaxBpm: 180,
      );
      final rehit = engine.completionFromEntry(
        prescription: rehitPrescription,
        completedWorkIntervals: 2,
        completedDurationMinutes: 5,
      );
      final fourByFourPrescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s3,
        durationMinutes: 30,
        heartRateMaxBpm: 180,
      );

      expect(
        () => engine.validateSessionMatch(
          sessionId: SessionTypeId.s3,
          prescription: fourByFourPrescription,
          completion: rehit,
        ),
        throwsArgumentError,
      );
      expect(log(SessionTypeId.s3, rehit).countsTowardQueueAndFloor, isFalse);
    });

    test('non-positive and physiologically impossible form values are rejected', () {
      final prescription = engine.prescriptionFor(
        sessionId: SessionTypeId.s7,
        durationMinutes: 5,
        heartRateMaxBpm: 180,
      );
      expect(
        () => engine.completionFromEntry(
          prescription: prescription,
          completedWorkIntervals: 0,
          completedDurationMinutes: 5,
        ),
        throwsArgumentError,
      );
      expect(
        () => engine.completionFromEntry(
          prescription: prescription,
          completedWorkIntervals: 2,
          completedDurationMinutes: 5,
          averageHeartRateBpm: 190,
          peakHeartRateBpm: 170,
        ),
        throwsArgumentError,
      );
    });
  });
}
