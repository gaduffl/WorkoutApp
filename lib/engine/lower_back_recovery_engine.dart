import '../models/equipment.dart';
import '../models/exercise_metric.dart';
import '../models/exercise_state.dart';
import '../models/ladders.dart';
import '../models/lower_back_recovery.dart';
import '../models/movement_pattern.dart';
import '../models/plan.dart';
import '../models/set_log.dart';
import 'equipment_engine.dart';

/// Result of one next-morning check.
class BackCheckOutcome {
  final LowerBackRecoveryState state;

  /// The hinge lane just finished: the caller hands the hinge back to the
  /// normal ladder.
  final bool finished;

  /// A worse morning moved the lane back out of this stage.
  final BackRebuildStage? steppedBackFrom;

  const BackCheckOutcome(
    this.state, {
    this.finished = false,
    this.steppedBackFrom,
  });
}

/// Pure, symptom-response-gated progression for Back rebuild.
///
/// Only the hinge slot and the bike return have stages. Completion never
/// advances anything by itself: a same-or-better next morning is required.
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

  /// Stage load window as fractions of the preserved pre-rebuild load.
  static const blockDeadliftFloor = 0.5;
  static const blockDeadliftCap = 0.7;
  static const romanianDeadliftFloor = 0.7;
  static const romanianDeadliftCap = 1.0;

  static const goodMorningsToAdvance = 2;

  /// A bike exposure shorter than this is not a meaningful test ride.
  static const minimumTestRideSeconds = 10 * 60;

  static const _equipmentEngine = EquipmentEngine();

  LowerBackRecoveryState activate({
    required DateTime now,
    required DateTime symptomOnsetDate,
    required ExerciseState? hingeState,
  }) => LowerBackRecoveryState(
    active: true,
    activatedAt: _day(now),
    symptomOnsetDate: _day(symptomOnsetDate),
    neurologicalSymptomsAbsentConfirmedAt: now,
    preRecoveryHingeLoad: hingeState?.currentLoad,
    preRecoveryHingeLadderStepIndex: hingeState?.ladderStepIndex,
    rebuildStage: BackRebuildStage.bridges,
    bikeReturnStep: BikeReturnStep.walkOnly,
  );

  /// Explicit end chosen by the user: normal training, cycling included.
  LowerBackRecoveryState deactivate(
    LowerBackRecoveryState state, {
    required DateTime now,
  }) => state.copyWith(
    active: false,
    completedAt: now,
    consecutiveToleratedSessions: 0,
    rebuildGoodMornings: 0,
    bikeReturnStep: BikeReturnStep.complete,
    clearPendingResponse: true,
  );

  /// Whether a spaced exposure (a loaded hinge step or the optional back
  /// extension) may be planned today: at most twice per rolling week, at
  /// least 48 hours apart, and never before the last check is answered.
  bool isSessionDue(LowerBackRecoveryState state, DateTime today) {
    if (!state.active || state.awaitingNextMorningResponse) return false;
    final day = _day(today);
    final windowStart = day.subtract(const Duration(days: 6));
    final recent =
        state.recoverySessionDates
            .map(_day)
            .where((date) => !date.isBefore(windowStart) && !date.isAfter(day))
            .toList()
          ..sort();
    if (recent.length >= _maximumSessionsInRollingWeek) return false;
    if (recent.isEmpty) return true;
    return day.difference(recent.last).inDays >= _minimumSpacingDays;
  }

  /// The loaded hinge exercise of the current stage, if any.
  SubstituteExercise? loadedStepFor(LowerBackRecoveryState state) =>
      switch (state.rebuildStage) {
        BackRebuildStage.bridges => null,
        BackRebuildStage.blockDeadlift => backRebuildBlockDeadlift,
        BackRebuildStage.romanianDeadlift => backRebuildRomanianDeadlift,
      };

  List<double> _hingeTotals(EquipmentConfig equipment) =>
      _equipmentEngine.twoDbAchievableTotals(equipment, allowUneven: true);

  double _stageLoad(
    LowerBackRecoveryState state,
    SubstituteExercise exercise,
    EquipmentConfig equipment, {
    required bool cap,
  }) {
    final totals = _hingeTotals(equipment);
    final reference = state.preRecoveryHingeLoad ?? 0;
    if (reference <= 0) return totals.first;
    final fraction = exercise.trackKey == backRebuildBlockDeadlift.trackKey
        ? (cap ? blockDeadliftCap : blockDeadliftFloor)
        : (cap ? romanianDeadliftCap : romanianDeadliftFloor);
    return _equipmentEngine.roundDownToAchievable(reference * fraction, totals);
  }

  /// Starting load of a stage track that has never been trained.
  double stageFloorLoad(
    LowerBackRecoveryState state,
    SubstituteExercise exercise,
    EquipmentConfig equipment,
  ) => _stageLoad(state, exercise, equipment, cap: false);

  /// Highest load the stage may prescribe.
  double stageCapLoad(
    LowerBackRecoveryState state,
    SubstituteExercise exercise,
    EquipmentConfig equipment,
  ) => _stageLoad(state, exercise, equipment, cap: true);

  bool stageCapReached(
    LowerBackRecoveryState state,
    ExerciseState? trackState,
    EquipmentConfig equipment,
  ) {
    final exercise = loadedStepFor(state);
    if (exercise == null) return true;
    final load = trackState?.currentLoad ?? 0;
    return load >= stageCapLoad(state, exercise, equipment);
  }

  /// The optional back-extension prescription when due. It never becomes a
  /// loaded hinge.
  PlannedExercise? prescriptionFor(
    LowerBackRecoveryState state, {
    required DateTime today,
    required EquipmentConfig equipment,
  }) {
    if (!isSessionDue(state, today)) return null;
    if (state.stage == LowerBackRecoveryStage.isometricHold) {
      return PlannedExercise(
        trackKey: lowerBackRecoveryTrackKey,
        pattern: MovementPattern.hinge,
        name: 'Static back-extension hold',
        visualId: 'backExtensionHold',
        sets: 3,
        metric: ExerciseMetric.seconds,
        targetRange: (state.targetHoldSeconds, state.targetHoldSeconds),
        suggestedValue: state.targetHoldSeconds,
        rirTarget: Rir.rir4plus,
        substitutedFrom: MovementPattern.hinge.name,
        progressionEligible: false,
        instruction:
            'Use the secured setup and a comfortable neutral-to-near-neutral position. Keep effort moderate; stop for sharp, spreading, numb, tingling, or weak symptoms. Do not train to failure.',
      );
    }
    final reps = state.stage == LowerBackRecoveryStage.deadliftReentry
        ? _maximumDynamicReps
        : state.targetDynamicReps;
    return PlannedExercise(
      trackKey: lowerBackRecoveryTrackKey,
      pattern: MovementPattern.hinge,
      name: 'Controlled back extension (unweighted)',
      visualId: 'backExtensionDynamic',
      sets: 2,
      metric: ExerciseMetric.reps,
      targetRange: (reps, reps),
      rirTarget: Rir.rir4plus,
      substitutedFrom: MovementPattern.hinge.name,
      progressionEligible: false,
      instruction:
          'Move slowly through the comfortable range without forcing end-range extension. Stop for sharp, spreading, numb, tingling, or weak symptoms. Do not train to failure.',
    );
  }

  /// Records completed hinge-slot work of a rebuild session. The stage can
  /// only change after the next-morning check.
  LowerBackRecoveryState recordRebuildSession(
    LowerBackRecoveryState state, {
    required DateTime sessionDate,
    required BackRebuildExposure exposure,
    required bool extension,
    required bool painFlagged,
  }) {
    if (!state.active || (exposure == BackRebuildExposure.none && !extension)) {
      return state;
    }
    final day = _day(sessionDate);
    final spaced = exposure == BackRebuildExposure.loaded || extension;
    final dates = spaced
        ? _retainedDates({...state.recoverySessionDates.map(_day), day}, day)
        : state.recoverySessionDates;
    final pendingExposure = exposure.index > state.pendingRebuildExposure.index
        ? exposure
        : state.pendingRebuildExposure;
    return state.copyWith(
      recoverySessionDates: dates,
      pendingNextMorningSessionDate: _later(
        state.pendingNextMorningSessionDate,
        day,
      ),
      pendingSameDayResponse:
          painFlagged ||
              state.pendingSameDayResponse == LowerBackSymptomResponse.worse
          ? LowerBackSymptomResponse.worse
          : LowerBackSymptomResponse.unchanged,
      pendingRebuildExposure: pendingExposure,
      pendingExtensionExposure: state.pendingExtensionExposure || extension,
    );
  }

  /// Records bike work while the stepped bike return is in progress.
  LowerBackRecoveryState recordBikeSession(
    LowerBackRecoveryState state, {
    required DateTime sessionDate,
    required BikeExposure exposure,
  }) {
    if (!state.bikeReturnInProgress || exposure == BikeExposure.none) {
      return state;
    }
    final day = _day(sessionDate);
    return state.copyWith(
      pendingNextMorningSessionDate: _later(
        state.pendingNextMorningSessionDate,
        day,
      ),
      pendingSameDayResponse:
          state.pendingSameDayResponse ?? LowerBackSymptomResponse.unchanged,
      pendingBikeExposure: exposure.index > state.pendingBikeExposure.index
          ? exposure
          : state.pendingBikeExposure,
    );
  }

  /// Applies one next-morning check to every pending exposure.
  BackCheckOutcome recordNextMorningResponse(
    LowerBackRecoveryState state, {
    required LowerBackSymptomResponse response,
    required DateTime responseDate,
    bool stageCapReached = false,
  }) {
    if (!state.awaitingNextMorningResponse) return BackCheckOutcome(state);
    final sessionDate = state.pendingNextMorningSessionDate!;
    if (!_day(responseDate).isAfter(_day(sessionDate))) {
      return BackCheckOutcome(state);
    }
    final tolerated =
        state.pendingSameDayResponse != LowerBackSymptomResponse.worse &&
        response != LowerBackSymptomResponse.worse;

    var next = state;
    var finished = false;
    BackRebuildStage? steppedBackFrom;

    if (state.active &&
        state.pendingRebuildExposure != BackRebuildExposure.none) {
      if (!tolerated) {
        if (state.rebuildStage != BackRebuildStage.bridges) {
          steppedBackFrom = state.rebuildStage;
        }
        next = next.copyWith(
          rebuildStage: BackRebuildStage
              .values[(state.rebuildStage.index - 1).clamp(0, 2).toInt()],
          rebuildGoodMornings: 0,
        );
      } else {
        final counts =
            state.rebuildStage == BackRebuildStage.bridges ||
            state.pendingRebuildExposure == BackRebuildExposure.loaded;
        final goodMornings = state.rebuildGoodMornings + (counts ? 1 : 0);
        final canAdvance =
            goodMornings >= goodMorningsToAdvance &&
            (state.rebuildStage == BackRebuildStage.bridges || stageCapReached);
        if (!canAdvance) {
          next = next.copyWith(rebuildGoodMornings: goodMornings);
        } else if (state.rebuildStage == BackRebuildStage.romanianDeadlift) {
          finished = true;
          next = next.copyWith(
            active: false,
            completedAt: responseDate,
            rebuildGoodMornings: 0,
          );
        } else {
          next = next.copyWith(
            rebuildStage: BackRebuildStage.values[state.rebuildStage.index + 1],
            rebuildGoodMornings: 0,
          );
        }
      }
    }

    if (state.pendingExtensionExposure) {
      next = tolerated ? _advanceExtension(next) : _regressExtension(next);
    }

    if (state.pendingBikeExposure != BikeExposure.none &&
        state.bikeReturnInProgress) {
      next = next.copyWith(
        bikeReturnStep: _nextBikeStep(
          state.bikeReturnStep,
          state.pendingBikeExposure,
          tolerated: tolerated,
        ),
      );
    }

    return BackCheckOutcome(
      next.copyWith(
        lastNextMorningResponse: response,
        clearPendingResponse: true,
      ),
      finished: finished,
      steppedBackFrom: steppedBackFrom,
    );
  }

  BikeReturnStep _nextBikeStep(
    BikeReturnStep step,
    BikeExposure exposure, {
    required bool tolerated,
  }) {
    if (!tolerated) {
      return BikeReturnStep.values[(step.index - 1).clamp(0, 3).toInt()];
    }
    final required = switch (step) {
      BikeReturnStep.walkOnly => BikeExposure.easyRide,
      BikeReturnStep.zone2Ride => BikeExposure.zone2Ride,
      BikeReturnStep.fourByFour => BikeExposure.fourByFour,
      BikeReturnStep.complete => BikeExposure.rehit,
    };
    if (step == BikeReturnStep.complete || exposure.index < required.index) {
      return step;
    }
    return BikeReturnStep.values[step.index + 1];
  }

  LowerBackRecoveryState _advanceExtension(LowerBackRecoveryState state) {
    final tolerated = state.consecutiveToleratedSessions + 1;
    if (tolerated < 2) {
      return state.copyWith(consecutiveToleratedSessions: tolerated);
    }
    return switch (state.stage) {
      LowerBackRecoveryStage.isometricHold
          when state.targetHoldSeconds < _maximumHoldSeconds =>
        state.copyWith(
          targetHoldSeconds: state.targetHoldSeconds + _holdIncrementSeconds,
          consecutiveToleratedSessions: 0,
        ),
      LowerBackRecoveryStage.isometricHold => state.copyWith(
        stage: LowerBackRecoveryStage.dynamicUnloaded,
        targetDynamicReps: _minimumDynamicReps,
        consecutiveToleratedSessions: 0,
      ),
      _ => state.copyWith(
        stage: LowerBackRecoveryStage.dynamicUnloaded,
        targetDynamicReps: (state.targetDynamicReps + _dynamicRepIncrement)
            .clamp(_minimumDynamicReps, _maximumDynamicReps)
            .toInt(),
        consecutiveToleratedSessions: 0,
      ),
    };
  }

  LowerBackRecoveryState _regressExtension(LowerBackRecoveryState state) {
    switch (state.stage) {
      case LowerBackRecoveryStage.isometricHold:
        return state.copyWith(
          targetHoldSeconds: (state.targetHoldSeconds - _holdIncrementSeconds)
              .clamp(_minimumHoldSeconds, _maximumHoldSeconds)
              .toInt(),
          consecutiveToleratedSessions: 0,
        );
      case LowerBackRecoveryStage.dynamicUnloaded:
      case LowerBackRecoveryStage.deadliftReentry:
        final reps = state.stage == LowerBackRecoveryStage.deadliftReentry
            ? _maximumDynamicReps
            : state.targetDynamicReps;
        if (reps > _minimumDynamicReps) {
          return state.copyWith(
            stage: LowerBackRecoveryStage.dynamicUnloaded,
            targetDynamicReps: (reps - _dynamicRepIncrement)
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
    }
  }

  static List<DateTime> _retainedDates(Set<DateTime> dates, DateTime day) =>
      (dates.toList()..sort())
          .where(
            (date) => !date.isBefore(day.subtract(const Duration(days: 30))),
          )
          .toList();

  static DateTime _later(DateTime? current, DateTime day) =>
      current == null || _day(current).isBefore(day) ? day : _day(current);

  static DateTime _day(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}
