import '../models/equipment.dart';
import '../models/exercise_metric.dart';
import '../models/exercise_state.dart';
import '../models/lower_back_recovery.dart';
import '../models/movement_pattern.dart';
import '../models/plan.dart';
import '../models/set_log.dart';
import 'equipment_engine.dart';

/// Pure, symptom-response-gated progression for lower-back recovery mode.
/// Completion never advances the dose by itself: a next-morning response is
/// required, and two tolerated exposures are needed for every small step.
class LowerBackRecoveryEngine {
  const LowerBackRecoveryEngine();

  static const _minimumSpacingDays = 2;
  static const _maximumSessionsInRollingWeek = 2;
  static const _minimumHoldSeconds = 20;
  static const _maximumHoldSeconds = 60;
  static const _holdIncrementSeconds = 10;
  static const _minimumDynamicReps = 6;
  static const _maximumDynamicReps = 12;
  static const _dynamicRepIncrement = 2;
  static const _equipmentEngine = EquipmentEngine();

  LowerBackRecoveryState activate({
    required DateTime now,
    required DateTime symptomOnsetDate,
    required ExerciseState? hingeState,
  }) =>
      LowerBackRecoveryState(
        active: true,
        activatedAt: _day(now),
        symptomOnsetDate: _day(symptomOnsetDate),
        neurologicalSymptomsAbsentConfirmedAt: now,
        preRecoveryHingeLoad: hingeState?.currentLoad,
        preRecoveryHingeLadderStepIndex: hingeState?.ladderStepIndex,
      );

  LowerBackRecoveryState deactivate(
    LowerBackRecoveryState state, {
    required DateTime now,
  }) =>
      state.copyWith(
        active: false,
        completedAt: now,
        consecutiveToleratedSessions: 0,
        clearPendingResponse: true,
      );

  bool isSessionDue(LowerBackRecoveryState state, DateTime today) {
    if (!state.active || state.awaitingNextMorningResponse) return false;
    final day = _day(today);
    final windowStart = day.subtract(const Duration(days: 6));
    final recent = state.recoverySessionDates
        .map(_day)
        .where((date) => !date.isBefore(windowStart) && !date.isAfter(day))
        .toList()
      ..sort();
    if (recent.length >= _maximumSessionsInRollingWeek) return false;
    if (recent.isEmpty) return true;
    return day.difference(recent.last).inDays >= _minimumSpacingDays;
  }

  PlannedExercise? prescriptionFor(
    LowerBackRecoveryState state, {
    required DateTime today,
    required EquipmentConfig equipment,
  }) {
    if (!isSessionDue(state, today)) return null;
    switch (state.stage) {
      case LowerBackRecoveryStage.isometricHold:
        return PlannedExercise(
          trackKey: lowerBackRecoveryTrackKey,
          pattern: MovementPattern.hinge,
          name: 'Static back-extension hold',
          visualId: 'backExtensionHold',
          sets: 3,
          metric: ExerciseMetric.seconds,
          targetRange: (
            state.targetHoldSeconds,
            state.targetHoldSeconds,
          ),
          suggestedValue: state.targetHoldSeconds,
          rirTarget: Rir.rir4plus,
          substitutedFrom: MovementPattern.hinge.name,
          progressionEligible: false,
          instruction:
              'Use the secured setup and a comfortable neutral-to-near-neutral position. Keep effort moderate; stop for sharp, spreading, numb, tingling, or weak symptoms. Do not train to failure.',
        );
      case LowerBackRecoveryStage.dynamicUnloaded:
        return PlannedExercise(
          trackKey: lowerBackRecoveryTrackKey,
          pattern: MovementPattern.hinge,
          name: 'Controlled back extension (unweighted)',
          visualId: 'backExtensionDynamic',
          sets: 2,
          metric: ExerciseMetric.reps,
          targetRange: (
            state.targetDynamicReps,
            state.targetDynamicReps,
          ),
          rirTarget: Rir.rir4plus,
          substitutedFrom: MovementPattern.hinge.name,
          progressionEligible: false,
          instruction:
              'Move slowly through the comfortable range without forcing end-range extension. Stop for sharp, spreading, numb, tingling, or weak symptoms. Do not train to failure.',
        );
      case LowerBackRecoveryStage.deadliftReentry:
        final achievable = _equipmentEngine.twoDbAchievableTotals(
          equipment,
          allowUneven: equipment.unevenPairModeEnabled,
        );
        final preRecovery = state.preRecoveryHingeLoad ?? 0;
        final requested = preRecovery > 0
            ? preRecovery * 0.5
            : achievable.first;
        final load = _equipmentEngine.roundDownToAchievable(
          requested,
          achievable,
        );
        final resolved = _equipmentEngine.resolveTwoDb(
          load,
          equipment,
          allowUneven: equipment.unevenPairModeEnabled,
        );
        return PlannedExercise(
          trackKey: lowerBackRecoveryTrackKey,
          pattern: MovementPattern.hinge,
          name: 'Elevated-start DB deadlift re-entry',
          sets: 1,
          metric: ExerciseMetric.reps,
          targetRange: const (8, 8),
          loadTotal: load,
          loadDisplay: _equipmentEngine.describeLoad(resolved, equipment),
          loadSteps: achievable,
          dumbbellCount: 2,
          allowsUnevenPair: equipment.unevenPairModeEnabled,
          rirTarget: Rir.rir4plus,
          substitutedFrom: MovementPattern.hinge.name,
          progressionEligible: false,
          instruction:
              'Graded re-entry: limited comfortable range, at least 4 RIR, no load increase. Stop if symptoms return or spread.',
        );
    }
  }

  LowerBackRecoveryState recordSession(
    LowerBackRecoveryState state, {
    required DateTime sessionDate,
    required LowerBackSymptomResponse sameDayResponse,
    double? performedLoad,
  }) {
    if (!state.active) return state;
    final day = _day(sessionDate);
    final dates = <DateTime>{
      ...state.recoverySessionDates.map(_day),
      day,
    }.toList()
      ..sort();
    final retained = dates
        .where((date) => !date.isBefore(day.subtract(const Duration(days: 30))))
        .toList();
    return state.copyWith(
      recoverySessionDates: retained,
      pendingNextMorningSessionDate: day,
      pendingSameDayResponse: sameDayResponse,
      lastReentryLoad: performedLoad,
    );
  }

  LowerBackRecoveryState recordNextMorningResponse(
    LowerBackRecoveryState state, {
    required LowerBackSymptomResponse response,
    required DateTime responseDate,
  }) {
    if (!state.active || !state.awaitingNextMorningResponse) return state;
    final sessionDate = state.pendingNextMorningSessionDate!;
    if (!_day(responseDate).isAfter(_day(sessionDate))) return state;

    final tolerated = state.pendingSameDayResponse !=
            LowerBackSymptomResponse.worse &&
        response != LowerBackSymptomResponse.worse;
    if (!tolerated) {
      return _regress(state).copyWith(
        lastNextMorningResponse: response,
        clearPendingResponse: true,
      );
    }

    final toleratedCount = state.consecutiveToleratedSessions + 1;
    if (toleratedCount < 2) {
      return state.copyWith(
        consecutiveToleratedSessions: toleratedCount,
        lastNextMorningResponse: response,
        clearPendingResponse: true,
      );
    }

    final advanced = switch (state.stage) {
      LowerBackRecoveryStage.isometricHold
          when state.targetHoldSeconds < _maximumHoldSeconds =>
        state.copyWith(
          targetHoldSeconds:
              state.targetHoldSeconds + _holdIncrementSeconds,
          consecutiveToleratedSessions: 0,
        ),
      LowerBackRecoveryStage.isometricHold => state.copyWith(
          stage: LowerBackRecoveryStage.dynamicUnloaded,
          targetDynamicReps: _minimumDynamicReps,
          consecutiveToleratedSessions: 0,
        ),
      LowerBackRecoveryStage.dynamicUnloaded
          when state.targetDynamicReps < _maximumDynamicReps =>
        state.copyWith(
          targetDynamicReps:
              state.targetDynamicReps + _dynamicRepIncrement,
          consecutiveToleratedSessions: 0,
        ),
      LowerBackRecoveryStage.dynamicUnloaded => state.copyWith(
          stage: LowerBackRecoveryStage.deadliftReentry,
          consecutiveToleratedSessions: 0,
        ),
      LowerBackRecoveryStage.deadliftReentry => state.copyWith(
          active: false,
          completedAt: responseDate,
          consecutiveToleratedSessions: 0,
        ),
    };
    return advanced.copyWith(
      lastNextMorningResponse: response,
      clearPendingResponse: true,
    );
  }

  LowerBackRecoveryState _regress(LowerBackRecoveryState state) {
    switch (state.stage) {
      case LowerBackRecoveryStage.isometricHold:
        return state.copyWith(
          targetHoldSeconds: (state.targetHoldSeconds -
                  _holdIncrementSeconds)
              .clamp(_minimumHoldSeconds, _maximumHoldSeconds)
              .toInt(),
          consecutiveToleratedSessions: 0,
        );
      case LowerBackRecoveryStage.dynamicUnloaded:
        if (state.targetDynamicReps > _minimumDynamicReps) {
          return state.copyWith(
            targetDynamicReps: (state.targetDynamicReps -
                    _dynamicRepIncrement)
                .clamp(_minimumDynamicReps, _maximumDynamicReps)
                .toInt(),
            consecutiveToleratedSessions: 0,
          );
        }
        return state.copyWith(
          stage: LowerBackRecoveryStage.isometricHold,
          targetHoldSeconds: _maximumHoldSeconds,
          consecutiveToleratedSessions: 0,
        );
      case LowerBackRecoveryStage.deadliftReentry:
        return state.copyWith(
          stage: LowerBackRecoveryStage.dynamicUnloaded,
          targetDynamicReps: _maximumDynamicReps -
              _dynamicRepIncrement,
          consecutiveToleratedSessions: 0,
        );
    }
  }

  static DateTime _day(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}
