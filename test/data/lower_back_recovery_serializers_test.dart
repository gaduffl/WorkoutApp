import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/serializers.dart';
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
}
