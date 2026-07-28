import 'dart:math' as math;

import '../models/equipment.dart';
import '../models/exercise_metric.dart';
import '../models/exercise_state.dart';
import '../models/ladders.dart';
import '../models/movement_pattern.dart';
import '../models/set_log.dart';
import 'equipment_engine.dart';

/// Today's resolved starting point for an exercise, before pain
/// substitution (§8) is applied on top.
class PrescriptionResolution {
  final ExerciseState state;
  final bool detrainFired;
  final bool painReentryTestFired;
  final bool deloadActive;

  const PrescriptionResolution(
    this.state, {
    this.detrainFired = false,
    this.painReentryTestFired = false,
    this.deloadActive = false,
  });
}

/// Display-ready projection of one persisted progression state. Keeping this
/// pure and engine-owned prevents Today, Logger, and restored plans from
/// disagreeing about the current milestone or the next difficulty.
class ProgressionPresentation {
  final double fraction;
  final String label;
  final String nextLabel;

  const ProgressionPresentation({
    required this.fraction,
    required this.label,
    required this.nextLabel,
  });
}

class _PrescriptionSnapshot {
  final String exerciseName;
  final ExerciseMetric metric;
  final int targetValue;
  final double load;
  final int microStepStage;

  const _PrescriptionSnapshot({
    required this.exerciseName,
    required this.metric,
    required this.targetValue,
    required this.load,
    required this.microStepStage,
  });
}

/// §6: per-pattern progression state machine + §6.4 rep-cap ladder rule +
/// §6.6 detraining adjustment (with §7.2 pain-reentry precedence).
///
/// Micro-progressions between ladder steps (§2.3: load -> tempo -> pause ->
/// deficit -> next step) are tracked with a single `microStepStage` counter
/// (0=load stage, 1=+tempo, 2=+pause, 3=+deficit, then the ladder advances)
/// rather than separate booleans - the display layer renders the stage as
/// text, but the state machine only needs to know how many are used up.
class ProgressionEngine {
  const ProgressionEngine();

  static const EquipmentEngine equipment = EquipmentEngine();

  ExerciseMetric metricFor(ExerciseState state) => ladderStepFor(state).metric;

  (int, int) targetRangeFor(ExerciseState state) {
    if (state.trackKey.startsWith('sub:')) return (8, 15); // §7.1 ONBOARD_SUBSTITUTE
    final step = ladderStepFor(state);
    return step.targetRange ?? state.pattern.repRange;
  }

  (int, int) repRangeFor(ExerciseState state) => targetRangeFor(state);

  /// The exact metric value Logger should open with. Plank intentionally
  /// migrates to Sebastian's established 60-second baseline; other timed
  /// steps begin at their own lower bound until progression persists a value.
  int suggestedValueFor(ExerciseState state) {
    final range = targetRangeFor(state);
    final persisted = state.currentTargetValue;
    if (persisted != null) return persisted.clamp(range.$1, range.$2).toInt();
    final step = ladderStepFor(state);
    if (state.trackKey == MovementPattern.coreGrip.name &&
        state.ladderStepIndex == 0 &&
        step.name == 'Plank') {
      return 60.clamp(range.$1, range.$2).toInt();
    }
    return range.$1;
  }

  /// Timed deloads reduce the actual hold target, not the irrelevant zero-load
  /// dimension used by bodyweight work.
  int deloadTargetValueFor(ExerciseState state) {
    final range = targetRangeFor(state);
    return _roundTimedTarget(suggestedValueFor(state) * 0.6, range);
  }

  ProgressionPresentation progressionPresentationFor(
    ExerciseState state,
    EquipmentConfig cfg,
  ) {
    final step = ladderStepFor(state);
    final ladder = substituteRegistry.containsKey(state.trackKey)
        ? null
        : ladders[state.pattern];
    final difficulty = ladder == null
        ? step.name
        : 'Difficulty ${state.ladderStepIndex.clamp(0, ladder.steps.length - 1) + 1} of ${ladder.steps.length}';
    final target = suggestedValueFor(state);
    final range = targetRangeFor(state);
    final stage = state.microStepStage.clamp(0, 3);

    if (step.metric == ExerciseMetric.seconds) {
      final targetSteps = math.max(0, ((range.$2 - range.$1) / 5).ceil());
      final completedTargetSteps =
          ((target - range.$1) / 5).ceil().clamp(0, targetSteps);
      final totalMilestones = math.max(1, targetSteps + 4);
      final fraction = ((completedTargetSteps + stage) / totalMilestones)
          .clamp(0.0, 1.0)
          .toDouble();
      final next = target < range.$2
          ? 'Next: ${math.min(range.$2, target + 5)} seconds'
          : stage < 3
              ? 'Next: ${_microStageName(stage + 1, step.metric)}'
              : ladder != null &&
                      state.ladderStepIndex < ladder.steps.length - 1
                  ? 'Next difficulty: ${ladder.steps[state.ladderStepIndex + 1].name}'
                  : 'Current progression maximum reached';
      return ProgressionPresentation(
        fraction: fraction,
        label: '$target-second ${step.name} · $difficulty',
        nextLabel: next,
      );
    }

    final achievable = step.backpackLoaded
        ? equipment.allPerDumbbellSteps(cfg)
        : _achievableSet(step, cfg);
    final loadIndex = achievable == null || achievable.isEmpty
        ? 0
        : achievable.indexWhere((value) => value >= state.currentLoad);
    final normalizedLoadIndex =
        loadIndex < 0 ? achievable?.length ?? 0 : loadIndex;
    final loadMilestones =
        achievable == null ? 0 : math.max(0, achievable.length - 1);
    final totalMilestones = math.max(1, loadMilestones + 4);
    final fraction = ((normalizedLoadIndex + stage) / totalMilestones)
        .clamp(0.0, 1.0)
        .toDouble();
    final loadLabel = state.currentLoad > 0
        ? '${_formatLoad(state.currentLoad)} lb ${step.name}'
        : step.name;
    final next = stage > 0 && stage < 3
        ? 'Next: ${_microStageName(stage + 1, step.metric)}'
        : stage == 3
            ? ladder != null &&
                    state.ladderStepIndex < ladder.steps.length - 1
                ? 'Next difficulty: ${ladder.steps[state.ladderStepIndex + 1].name}'
                : 'Current progression maximum reached'
            : 'Next: complete every set at the top of the range with RIR 2+';
    return ProgressionPresentation(
      fraction: fraction,
      label: ladder == null ? loadLabel : '$loadLabel · $difficulty',
      nextLabel: next,
    );
  }

  LadderStep ladderStepFor(ExerciseState state) {
    // Named exercises (§7.1 substitutes, S5 accessories) carry their own
    // dumbbell count — never fall back to the pattern ladder's step, which
    // would compute increments on the wrong achievable-load set.
    final named = substituteRegistry[state.trackKey];
    if (named != null) return named.ladderStep;
    final ladder = ladders[state.pattern]!;
    final idx = state.ladderStepIndex.clamp(0, ladder.steps.length - 1);
    return ladder.steps[idx];
  }

  List<double>? _achievableSet(LadderStep step, EquipmentConfig cfg) {
    if (step.backpackLoaded || step.dumbbells == 0) return null;
    if (step.dumbbells == 1) return equipment.singleDbAchievableTotals(cfg);
    return equipment.twoDbAchievableTotals(cfg, allowUneven: !step.unilateral);
  }

  double _detrainPercent(int daysUntrained) {
    if (daysUntrained > 42) return 0.70;
    if (daysUntrained > 21) return 0.80;
    if (daysUntrained >= 10) return 0.90;
    return 1.0; // §6.6 detraining only starts at a 10-day gap
  }

  /// §6.2: evaluate transitions once, at session completion, per exercise,
  /// using only that session's completed work sets (warm-ups excluded).
  ExerciseState evaluateSession(
    ExerciseState state,
    List<SetLog> workSets, {
    required EquipmentConfig equipmentConfig,
    required DateTime sessionDate,
  }) {
    // Callers normally pre-filter these, but keeping the state machine
    // defensive guarantees prep/ramp entries can never drive progression.
    final eligibleSets = workSets
        .where((setLog) => !setLog.isWarmup && setLog.value > 0)
        .toList();
    if (eligibleSets.isEmpty) return state;
    final next = state.clone();
    final before = _snapshotFor(next);
    next.lastPrescriptionChange = null;
    if (metricFor(next) == ExerciseMetric.seconds) {
      next.currentTargetValue = suggestedValueFor(next);
    }
    next.lastTrainedDate = sessionDate;

    // §6.2.4: pain freeze - sessions while flagged never count as
    // holds/progressions, regardless of severity.
    if (next.painFrozen) return _finishChange(next, before);

    // §6.2 note: a REGRESS label lasts exactly one session, then reverts
    // to PROGRESS before this session's own trigger is evaluated.
    if (next.status == ExerciseStatus.regress) {
      next.status = ExerciseStatus.progress;
    }

    if (next.pattern.patternClass == PatternClass.kneeHealth) {
      return _finishChange(next, before); // rep/ROM only, no state machine.
    }

    if (next.status == ExerciseStatus.deload) {
      return _finishChange(
        _handleDeloadSession(next, equipmentConfig),
        before,
      );
    }

    final expectedMetric = metricFor(next);
    final metricSets = eligibleSets
        .where((setLog) => setLog.metric == expectedMetric)
        .toList();
    // A mismatched legacy/new metric must not accidentally advance a state.
    // Stamp recency above, but otherwise leave the prescription unchanged.
    if (metricSets.isEmpty) return _finishChange(next, before);

    // The logger is authoritative for a regular session's working load. A
    // user may adjust the prescription before or between sets, so progression
    // must start from the most recently completed work set rather than stale
    // planned state. Bodyweight steps have no persisted load dimension, while
    // backpack-loaded steps are intentionally free-entry.
    final step = ladderStepFor(next);
    if (step.backpackLoaded || _achievableSet(step, equipmentConfig) != null) {
      next.currentLoad = metricSets.last.weight;
    }

    final (low, high) = targetRangeFor(next);
    final anyBelowRange = metricSets.any((setLog) => setLog.value < low);
    final anyRir0 = metricSets.any((setLog) => setLog.rir == Rir.rir0);
    final progressionTarget = expectedMetric == ExerciseMetric.seconds
        ? suggestedValueFor(next)
        : high;
    final allAtTargetHighRir = metricSets.every((setLog) =>
        setLog.value >= progressionTarget &&
        (setLog.rir == Rir.rir2 ||
            setLog.rir == Rir.rir3plus ||
            setLog.rir == Rir.rir4plus));

    if (next.awaitingUndershootCheck) {
      next.awaitingUndershootCheck = false;
      if (metricSets.every((setLog) =>
          setLog.value >= low &&
          (setLog.rir == Rir.rir3plus ||
              setLog.rir == Rir.rir4plus))) {
        _applyOneIncrement(next, equipmentConfig);
        next.status = ExerciseStatus.progress;
        next.consecutiveHoldCount = 0;
        return _finishChange(next, before);
      }
    }

    if (allAtTargetHighRir) {
      if (expectedMetric == ExerciseMetric.seconds &&
          progressionTarget < high) {
        next.currentTargetValue = math.min(high, progressionTarget + 5);
      } else {
        _applyProgressTrigger(next, equipmentConfig);
      }
      next.status = ExerciseStatus.progress;
      next.consecutiveHoldCount = 0;
    } else if (anyBelowRange || anyRir0) {
      if (next.status == ExerciseStatus.hold) {
        next.consecutiveHoldCount += 1;
        if (next.consecutiveHoldCount >= 2) {
          _applyRegression(next, equipmentConfig, sessionDate);
          next.status = ExerciseStatus.regress;
          next.consecutiveHoldCount = 0;
        }
      } else {
        next.status = ExerciseStatus.hold;
        next.consecutiveHoldCount = 1;
      }
    } else {
      // §6.2.5 middle zone: neither trigger - repeat unchanged, no counters.
      next.status = ExerciseStatus.progress;
    }

    // §6.3: >=2 regressions on this pattern within a rolling 28 days.
    if (next.status != ExerciseStatus.deload &&
        next.regressionCountWithinDays(sessionDate, 28) >= 2) {
      _enterDeload(next);
    }

    return _finishChange(next, before);
  }

  void _applyOneIncrement(ExerciseState s, EquipmentConfig cfg) {
    final step = ladderStepFor(s);
    if (step.metric == ExerciseMetric.seconds) {
      final range = targetRangeFor(s);
      final target = suggestedValueFor(s);
      if (target < range.$2) {
        s.currentTargetValue = math.min(range.$2, target + 5);
        return;
      }
    }
    if (step.backpackLoaded) {
      final cap = _backpackLoadCap(cfg);
      if (cap != null && s.currentLoad >= cap) {
        _advanceMicroOrLadder(s, cfg);
      } else {
        s.currentLoad = cap == null
            ? s.currentLoad + 5
            : math.min(cap, s.currentLoad + 5);
      }
      return;
    }
    final achievable = _achievableSet(step, cfg);
    if (achievable == null) {
      _advanceMicroOrLadder(s, cfg);
      return;
    }
    final nextLoad = equipment.nextAchievableAbove(s.currentLoad, achievable);
    if (nextLoad == s.currentLoad) {
      _advanceMicroOrLadder(s, cfg);
    } else {
      s.currentLoad = nextLoad;
    }
  }

  void _applyProgressTrigger(ExerciseState s, EquipmentConfig cfg) {
    final step = ladderStepFor(s);

    if (step.backpackLoaded) {
      final cap = _backpackLoadCap(cfg);
      if (cap != null && s.currentLoad >= cap) {
        _advanceMicroOrLadder(s, cfg);
      } else {
        s.currentLoad = cap == null
            ? s.currentLoad + 5
            : math.min(cap, s.currentLoad + 5);
        s.microStepStage = 0;
      }
      return;
    }
    final achievable = _achievableSet(step, cfg);
    if (achievable == null) {
      // Bodyweight step: no load dimension, progress via ladder/tempo.
      _advanceMicroOrLadder(s, cfg);
      return;
    }

    final nextLoad = equipment.nextAchievableAbove(s.currentLoad, achievable);
    if (nextLoad == s.currentLoad) {
      _advanceMicroOrLadder(s, cfg);
      return;
    }
    if (equipment.incrementExceedsGuard(s.currentLoad, nextLoad) && s.microStepStage < 1) {
      // §2.6 rule 2: guard inserts exactly one micro-progression (tempo)
      // before permitting the jump, even below equipment max.
      s.microStepStage += 1;
      return;
    }
    s.currentLoad = nextLoad;
    s.microStepStage = 0;
  }

  void _advanceMicroOrLadder(ExerciseState s, EquipmentConfig cfg) {
    if (s.microStepStage < 3) {
      s.microStepStage += 1; // tempo -> pause -> deficit
      return;
    }
    // Named substitutes/accessories deliberately have no movement ladder.
    // Once their load and micro-progressions are exhausted, keep the named
    // exercise capped instead of falling through to the underlying pattern's
    // ladder (which can change an irrelevant index and reset the load).
    if (substituteRegistry.containsKey(s.trackKey)) return;

    final ladder = ladders[s.pattern]!;
    if (s.ladderStepIndex < ladder.steps.length - 1) {
      s.ladderStepIndex += 1;
      s.microStepStage = 0;
      final newStep = ladder.steps[s.ladderStepIndex];
      final reduction = s.pattern.ladderJumpReductionFraction;
      final target = s.currentLoad * (1 - reduction);
      final achievable = _achievableSet(newStep, cfg);
      if (newStep.backpackLoaded) {
        final cap = _backpackLoadCap(cfg);
        final capped = cap == null ? target : math.min(target, cap);
        s.currentLoad = math.max(0, (capped / 5).floor() * 5).toDouble();
      } else {
        s.currentLoad = achievable == null
            ? 0
            : equipment.roundDownToAchievable(target, achievable);
      }
      s.currentTargetValue = newStep.metric == ExerciseMetric.seconds
          ? (newStep.targetRange ?? s.pattern.repRange).$1
          : null;
      s.awaitingUndershootCheck = true; // §6.4 undershoot correction
    }
  }

  void _applyRegression(ExerciseState s, EquipmentConfig cfg, DateTime date) {
    s.regressionDates.add(date);
    _stepPrescriptionBack(s, cfg);
  }

  /// Moves a prescription back by one real step without classifying why.
  /// Failure regressions record their date before calling this helper;
  /// scheduled deload exits deliberately do not.
  void _stepPrescriptionBack(ExerciseState s, EquipmentConfig cfg) {
    s.awaitingUndershootCheck = false;
    final step = ladderStepFor(s);

    // Reverse the actual progression order. A tempo/pause/ROM stage is the
    // newest dimension and must be removed before load or duration changes.
    if (s.microStepStage > 0) {
      s.microStepStage -= 1;
      return;
    }

    if (step.metric == ExerciseMetric.seconds) {
      final range = targetRangeFor(s);
      final target = suggestedValueFor(s);
      if (target > range.$1) {
        s.currentTargetValue = math.max(range.$1, target - 5);
        return;
      }
    }

    if (step.backpackLoaded) {
      s.currentLoad = math.max(0, s.currentLoad - 5);
      return;
    }
    final achievable = _achievableSet(step, cfg);
    if (achievable == null) {
      // Named substitutes/accessories have no independent movement ladder.
      // Keep a capped named exercise capped rather than mutating the index of
      // an unrelated pattern ladder.
      if (!substituteRegistry.containsKey(s.trackKey) &&
          s.ladderStepIndex > 0) {
        s.ladderStepIndex -= 1;
        // A ladder is advanced only after all three micro stages are used.
        // Therefore the immediately preceding prescription is the prior
        // ladder step at its final micro stage, not its unmodified form.
        s.microStepStage = 3;
        final previousStep = ladderStepFor(s);
        s.currentTargetValue = previousStep.metric == ExerciseMetric.seconds
            ? (previousStep.targetRange ?? s.pattern.repRange).$2
            : null;
      }
      return;
    }
    final lowerLoad = equipment.nextAchievableBelow(s.currentLoad, achievable);
    if (lowerLoad < s.currentLoad) {
      s.currentLoad = lowerLoad;
    }
  }

  void _enterDeload(ExerciseState s) {
    s.preDeloadLoad = s.currentLoad;
    s.preDeloadLadderStepIndex = s.ladderStepIndex;
    s.preDeloadTargetValue = suggestedValueFor(s);
    s.status = ExerciseStatus.deload;
    s.deloadSessionsRemaining = 2;
    // Consume the regression window that triggered this deload. Leaving the
    // same dates in place would immediately start another deload on the first
    // normal session after the two-session deload finishes.
    s.regressionDates.clear();
  }

  /// §6.5: deload parameters (60% load, 50% sets, RIR>=4) are applied by the
  /// plan-assembly step; here we just count down the 2-session window and
  /// auto-return after restoring the saved ladder/load and then moving back
  /// one actual prescription step (load, backpack load, micro stage, or
  /// bodyweight/timed ladder stage). This is planned recovery, not a failure
  /// regression, so it never adds a regression date.
  ExerciseState _handleDeloadSession(ExerciseState s, EquipmentConfig cfg) {
    s.deloadSessionsRemaining -= 1;
    if (s.deloadSessionsRemaining <= 0) {
      s.ladderStepIndex = s.preDeloadLadderStepIndex ?? s.ladderStepIndex;
      s.currentLoad = s.preDeloadLoad ?? s.currentLoad;
      if (s.preDeloadTargetValue != null) {
        s.currentTargetValue = s.preDeloadTargetValue;
      } else if (metricFor(s) == ExerciseMetric.seconds) {
        // Legacy active-deload rows predate timed-target snapshots. Resolve
        // against the restored ladder step rather than carrying a temporary
        // target initialized from whichever step happened to be scheduled.
        s.currentTargetValue = targetRangeFor(s).$1;
      }
      _stepPrescriptionBack(s, cfg);
      s.status = ExerciseStatus.progress;
      s.deloadSessionsRemaining = 0;
      s.preDeloadLoad = null;
      s.preDeloadLadderStepIndex = null;
      s.preDeloadTargetValue = null;
    }
    return s;
  }

  List<ExerciseState> _forceGlobalDeload(List<ExerciseState> states) {
    return states.map((s) {
      if (s.painFrozen || s.status == ExerciseStatus.deload) return s;
      final next = s.clone();
      _enterDeload(next);
      return next;
    }).toList();
  }

  /// Materializes every built-in progression track before applying a global
  /// deload. This includes each plan-backed movement ladder (but not the
  /// non-progressing knee-health warm-up block) and S5's normal named
  /// accessories. Pain-only substitutes and unknown/imported tracks are
  /// retained unchanged: the app cannot guarantee that either will be
  /// scheduled again to consume a two-touch deload.
  ///
  /// Keeping this as the single global-deload entry point prevents an empty
  /// or sparsely trained state map from limiting the deload to exercises the
  /// user happened to have touched already. Existing normal-plan state
  /// objects flow through the transition below, which preserves active
  /// deload countdowns and all pain-freeze metadata; newly materialized
  /// normal tracks begin the next-two-touch deload.
  Map<String, ExerciseState> forceGlobalDeloadForBuiltInTracks(
    Map<String, ExerciseState> states,
  ) {
    final normalPlanSeeds = <ExerciseState>[];
    for (final pattern in ladders.keys) {
      if (pattern.patternClass == PatternClass.kneeHealth) continue;
      normalPlanSeeds.add(
        ExerciseState(trackKey: pattern.name, pattern: pattern),
      );
    }
    for (final named in s5NamedAccessories) {
      normalPlanSeeds.add(
        ExerciseState(
          trackKey: named.trackKey,
          pattern: named.pattern,
        ),
      );
    }

    final result = Map<String, ExerciseState>.from(states);
    for (final seed in normalPlanSeeds) {
      final current = result[seed.trackKey] ?? seed;
      result[seed.trackKey] = _forceGlobalDeload([current]).single;
    }
    return result;
  }

  /// §6.6 detraining adjustment, with §7.2 pain-reentry precedence: if a
  /// re-entry test is pending, it runs first and overrides the detraining
  /// percentage for that one session.
  PrescriptionResolution resolveTodaysPrescription(
    ExerciseState state,
    DateTime today,
    EquipmentConfig cfg,
  ) {
    // A formal safety re-entry must outrank deload. Otherwise a state that
    // became pain-frozen on the same check-in as a global deload can be stuck:
    // the deload cannot be consumed while frozen and the test is never shown.
    if (state.painReentryTestOffered && !state.painReentryTestPassed) {
      final step = ladderStepFor(state);
      final achievable = _achievableSet(step, cfg);
      final base = state.prePainLoad ?? state.currentLoad;
      final testLoad = achievable == null
          ? base * 0.5
          : equipment.roundDownToAchievable(base * 0.5, achievable);
      final next = state.clone()..currentLoad = testLoad;
      return PrescriptionResolution(next, painReentryTestFired: true);
    }
    if (state.status == ExerciseStatus.deload) {
      return PrescriptionResolution(state, deloadActive: true);
    }

    // A missing training date means this is an onboarding prescription, not
    // a comeback after a very long layoff. Keep the untouched state here;
    // plan assembly will still round a zero starting load to the equipment's
    // minimum achievable load.
    if (state.lastTrainedDate == null) {
      return PrescriptionResolution(state);
    }

    final days = state.daysUntrained(today);
    if (days < 10) return PrescriptionResolution(state);

    final next = state.clone();
    if (days > 21 && !substituteRegistry.containsKey(next.trackKey)) {
      next.ladderStepIndex = math.max(0, next.ladderStepIndex - 1);
    }
    final step = ladderStepFor(next);
    final achievable = _achievableSet(step, cfg);
    final pct = _detrainPercent(days);
    next.currentLoad = achievable == null
        ? next.currentLoad * pct
        : equipment.roundDownToAchievable(next.currentLoad * pct, achievable);
    if (step.metric == ExerciseMetric.seconds) {
      next.currentTargetValue = _roundTimedTarget(
        suggestedValueFor(next) * pct,
        targetRangeFor(next),
      );
    }
    next.status = ExerciseStatus.progress;
    return PrescriptionResolution(next, detrainFired: true);
  }

  /// Called for the first pain-free session after a passed re-entry test:
  /// resume at the *lower* of (detraining-adjusted load, pre-pain load - 1
  /// increment); detraining percentages never stack on top of an active
  /// pain protocol (§6.6 precedence note).
  ExerciseState resolvePostReentryResume(
    ExerciseState state,
    DateTime today,
    EquipmentConfig cfg,
  ) {
    final next = state.clone();
    final resumesIntoDeload = state.status == ExerciseStatus.deload &&
        state.deloadSessionsRemaining > 0;
    final step = ladderStepFor(next);
    final achievable = _achievableSet(step, cfg);
    final pct = _detrainPercent(state.daysUntrained(today));
    final base = state.prePainLoad ?? state.currentLoad;
    final detrainAdjusted = achievable == null
        ? base * pct
        : equipment.roundDownToAchievable(base * pct, achievable);
    final preMinusOne = achievable == null
        ? base
        : equipment.nextAchievableBelow(base, achievable);
    next.currentLoad = math.min(detrainAdjusted, preMinusOne);
    if (step.metric == ExerciseMetric.seconds) {
      final baseTarget =
          state.prePainTargetValue ?? suggestedValueFor(state);
      final detrainTarget =
          _roundTimedTarget(baseTarget * pct, targetRangeFor(next));
      final oneStepBack = math.max(targetRangeFor(next).$1, baseTarget - 5);
      next.currentTargetValue = math.min(detrainTarget, oneStepBack);
    }
    next.status = resumesIntoDeload
        ? ExerciseStatus.deload
        : ExerciseStatus.progress;
    next.painFrozen = false;
    next.painSeverity = null;
    next.painRegion = null;
    next.painFlaggedDate = null;
    next.painTags.clear();
    next.sessionsScheduledWhileFlagged = 0;
    next.lastPainScheduledDate = null;
    next.painReentryTestOffered = false;
    next.painReentryTestPassed = false;
    next.prePainLoad = null;
    next.prePainLadderStepIndex = null;
    next.prePainTargetValue = null;
    // If a global deload overlapped the pain episode, it remains reachable on
    // the next prescription now that the safety freeze has cleared.
    return next;
  }

  double? _backpackLoadCap(EquipmentConfig cfg) {
    final achievable = equipment.allPerDumbbellSteps(cfg);
    return achievable.isEmpty ? null : achievable.last;
  }

  int _roundTimedTarget(double value, (int, int) range) {
    final rounded = (value.floor() ~/ 5) * 5;
    return rounded.clamp(range.$1, range.$2).toInt();
  }

  _PrescriptionSnapshot _snapshotFor(ExerciseState state) {
    return _PrescriptionSnapshot(
      exerciseName: ladderStepFor(state).name,
      metric: metricFor(state),
      targetValue: suggestedValueFor(state),
      load: state.currentLoad,
      microStepStage: state.microStepStage,
    );
  }

  ExerciseState _finishChange(
    ExerciseState state,
    _PrescriptionSnapshot before,
  ) {
    final after = _snapshotFor(state);
    if (before.exerciseName != after.exerciseName) {
      state.lastPrescriptionChange =
          'New difficulty: ${before.exerciseName} → ${after.exerciseName}';
    } else if (before.metric == ExerciseMetric.seconds &&
        before.targetValue != after.targetValue) {
      final verb = after.targetValue > before.targetValue
          ? 'Target increased'
          : 'Target adjusted';
      state.lastPrescriptionChange =
          '$verb: ${before.targetValue} → ${after.targetValue} seconds';
    } else if ((before.load - after.load).abs() > 0.001) {
      final verb = after.load > before.load ? 'Load increased' : 'Load adjusted';
      state.lastPrescriptionChange =
          '$verb: ${_formatLoad(before.load)} → ${_formatLoad(after.load)} lb';
    } else if (before.microStepStage != after.microStepStage) {
      final verb = after.microStepStage > before.microStepStage
          ? 'New technique'
          : 'Technique adjusted';
      state.lastPrescriptionChange =
          '$verb: ${_microStageName(after.microStepStage, after.metric)}';
    }
    return state;
  }

  String _microStageName(int stage, ExerciseMetric metric) {
    if (metric == ExerciseMetric.seconds) {
      return switch (stage) {
        1 => 'controlled transition',
        2 => 'stricter hold',
        3 => 'harder leverage',
        _ => 'standard hold',
      };
    }
    return switch (stage) {
      1 => '3-second eccentric',
      2 => '1-second pause',
      3 => 'extended range',
      _ => 'standard tempo',
    };
  }

  String _formatLoad(double load) =>
      load == load.roundToDouble() ? load.toInt().toString() : load.toString();
}
