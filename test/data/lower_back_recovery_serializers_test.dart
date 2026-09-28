import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/engine/cardio_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  test('lower-back recovery state round-trips through settings', () {
    final sessionDate = DateTime(2026, 8, 8);
    final settings = UserSettings(
      lowerBackRecovery: LowerBackRecoveryState(
        active: true,
        activatedAt: DateTime(2026, 8, 1),
        symptomOnsetDate: DateTime(2026, 7, 18),
        neurologicalSymptomsAbsentConfirmedAt: DateTime(2026, 8, 1),
        stage: LowerBackRecoveryStage.dynamicUnloaded,
        targetHoldSeconds: 60,
        targetDynamicReps: 8,
        consecutiveToleratedSessions: 1,
        recoverySessionDates: [sessionDate],
        pendingNextMorningSessionDate: sessionDate,
        pendingSameDayResponse: LowerBackSymptomResponse.unchanged,
        preRecoveryHingeLoad: 90,
        preRecoveryHingeLadderStepIndex: 2,
      ),
    );

    final restored = userSettingsFromJson(userSettingsToJson(settings));
    expect(restored.lowerBackRecovery.active, isTrue);
    expect(
      restored.lowerBackRecovery.stage,
      LowerBackRecoveryStage.dynamicUnloaded,
    );
    expect(restored.lowerBackRecovery.targetDynamicReps, 8);
    expect(restored.lowerBackRecovery.awaitingNextMorningResponse, isTrue);
    expect(restored.lowerBackRecovery.preRecoveryHingeLoad, 90);
  });

  test('legacy settings default recovery mode to inactive', () {
    final json = userSettingsToJson(const UserSettings())
      ..remove('lowerBackRecovery');
    final restored = userSettingsFromJson(json);
    expect(restored.lowerBackRecovery, const LowerBackRecoveryState());
    expect(restored.lowerBackRecovery.active, isFalse);
  });

  test('plan persists recovery context with a legacy false default', () {
    const plan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Lower',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 35,
      lowerBackRecoveryMode: true,
    );
    expect(
      sessionPlanFromJson(sessionPlanToJson(plan)).lowerBackRecoveryMode,
      isTrue,
    );

    final legacy = sessionPlanToJson(plan)
      ..remove('lowerBackRecoveryMode');
    expect(sessionPlanFromJson(legacy).lowerBackRecoveryMode, isFalse);
  });

  test('Back rebuild progress and back settings round-trip', () {
    final settings = UserSettings(
      bigThreeEnabled: false,
      backRoutineDoneDay: '2026-09-27',
      lowerBackRecovery: LowerBackRecoveryState(
        active: true,
        rebuildStage: BackRebuildStage.romanianDeadlift,
        rebuildGoodMornings: 1,
        bikeReturnStep: BikeReturnStep.fourByFour,
        pendingNextMorningSessionDate: DateTime(2026, 9, 27),
        pendingSameDayResponse: LowerBackSymptomResponse.worse,
        pendingRebuildExposure: BackRebuildExposure.loaded,
        pendingExtensionExposure: true,
        pendingBikeExposure: BikeExposure.fourByFour,
      ),
    );
    final restored = userSettingsFromJson(userSettingsToJson(settings));
    expect(restored.lowerBackRecovery, settings.lowerBackRecovery);
    expect(restored.bigThreeEnabled, isFalse);
    expect(restored.backRoutineDoneDay, '2026-09-27');
    expect(restored.stationaryBikePaused, isFalse);
  });

  test('legacy recovery JSON gets safe Back rebuild defaults', () {
    Map<String, dynamic> legacy(LowerBackRecoveryState state) =>
        lowerBackRecoveryStateToJson(state)
          ..remove('rebuildStage')
          ..remove('rebuildGoodMornings')
          ..remove('bikeReturnStep')
          ..remove('pendingRebuildExposure')
          ..remove('pendingExtensionExposure')
          ..remove('pendingBikeExposure');

    final inactive = lowerBackRecoveryStateFromJson(
      legacy(const LowerBackRecoveryState()),
    );
    expect(inactive, const LowerBackRecoveryState());
    expect(inactive.bikeReturnStep, BikeReturnStep.complete);

    // An old recovery session awaiting its morning answer counts as bridge
    // work plus optional extensions, so the answer still lands somewhere.
    final pending = lowerBackRecoveryStateFromJson(
      legacy(
        LowerBackRecoveryState(
          active: true,
          pendingNextMorningSessionDate: DateTime(2026, 9, 27),
          pendingSameDayResponse: LowerBackSymptomResponse.unchanged,
        ),
      ),
    );
    expect(pending.rebuildStage, BackRebuildStage.bridges);
    expect(pending.rebuildGoodMornings, 0);
    expect(pending.bikeReturnStep, BikeReturnStep.walkOnly);
    expect(pending.pendingRebuildExposure, BackRebuildExposure.accessory);
    expect(pending.pendingExtensionExposure, isTrue);
    expect(pending.pendingBikeExposure, BikeExposure.none);
    expect(pending.awaitingNextMorningResponse, isTrue);

    final unknown = lowerBackRecoveryStateFromJson(
      lowerBackRecoveryStateToJson(const LowerBackRecoveryState(active: true))
        ..['rebuildStage'] = 'futureStage'
        ..['bikeReturnStep'] = 'futureStep',
    );
    expect(unknown.rebuildStage, BackRebuildStage.bridges);
    expect(unknown.bikeReturnStep, BikeReturnStep.complete);

    final settings = userSettingsToJson(const UserSettings())
      ..remove('bigThreeEnabled')
      ..remove('backRoutineDoneDay');
    final restored = userSettingsFromJson(settings);
    expect(restored.bigThreeEnabled, isTrue);
    expect(restored.backRoutineDoneDay, isNull);
  });

  test('cardio modality round-trips and legacy protocols stay rides', () {
    final walk = const CardioEngine().prescriptionFor(
      sessionId: SessionTypeId.s6,
      durationMinutes: 45,
      heartRateMaxBpm: 190,
      walk: true,
    );
    final restored = cardioPrescriptionFromJson(
      cardioPrescriptionToJson(walk),
    );
    expect(restored.protocol.isWalk, isTrue);
    expect(restored.protocol.type, CardioProtocolType.zone2Base);
    expect(restored.protocol.name, CardioProtocol.zone2Walk.name);
    expect(restored.plannedDurationSeconds, walk.plannedDurationSeconds);

    final legacy = cardioProtocolToJson(CardioProtocol.zone2Base)
      ..remove('modality');
    expect(cardioProtocolFromJson(legacy).modality, CardioModality.bike);
  });
}
