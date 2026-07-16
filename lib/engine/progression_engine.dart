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

  LadderStep ladderStepFor(ExerciseState state) {
    // Named exercises (§7.1 substitutes, S5 accessories) carry their own
    // dumbbell count — never fall back to the pattern ladder's step, which
    // would compute increments on the wrong achievable-load set.
    final named = substituteRegistry[state.trackKey];
    if (named != null) return LadderStep(name: named.name, dumbbells: named.dumbbells);
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
    next.lastTrainedDate = sessionDate;

    // §6.2.4: pain freeze - sessions while flagged never count as
    // holds/progressions, regardless of severity.
    if (next.painFrozen) return next;

    // §6.2 note: a REGRESS label lasts exactly one session, then reverts
    // to PROGRESS before this session's own trigger is evaluated.
    if (next.status == ExerciseStatus.regress) {
      next.status = ExerciseStatus.progress;
    }

    if (next.pattern.patternClass == PatternClass.kneeHealth) {
      return next; // rep/ROM progression only, no state machine (§6.1)
    }

    if (next.status == ExerciseStatus.deload) {
      return _handleDeloadSession(next, equipmentConfig);
    }

    final expectedMetric = metricFor(next);
    final metricSets = eligibleSets
        .where((setLog) => setLog.metric == expectedMetric)
        .toList();
    // A mismatched legacy/new metric must not accidentally advance a state.
    // Stamp recency above, but otherwise leave the prescription unchanged.
    if (metricSets.isEmpty) return next;

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
    final anyBelowRange = metricSets.any((s) => s.value < low);
    final anyRir0 = metricSets.any((s) => s.rir == Rir.rir0);
    final allAtTopHighRir = metricSets.every((s) =>
        s.value >= high &&
        (s.rir == Rir.rir2 || s.rir == Rir.rir3plus || s.rir == Rir.rir4plus));

    if (next.awaitingUndershootCheck) {
      next.awaitingUndershootCheck = false;
      if (metricSets.every((s) =>
          s.value >= low &&
          (s.rir == Rir.rir3plus || s.rir == Rir.rir4plus))) {
        _applyOneIncrement(next, equipmentConfig);
        next.status = ExerciseStatus.progress;
        next.consecutiveHoldCount = 0;
        return next;
      }
    }

    if (allAtTopHighRir) {
      _applyProgressTrigger(next, equipmentConfig);
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

    return next;
  }

  void _applyOneIncrement(ExerciseState s, EquipmentConfig cfg) {
    final step = ladderStepFor(s);
    if (step.backpackLoaded) {
      s.currentLoad += 5;
      return;
    }
    final achievable = _achievableSet(step, cfg);
    if (achievable == null) return; // bodyweight: nothing to increment
    s.currentLoad = equipment.nextAchievableAbove(s.currentLoad, achievable);
  }

  void _applyProgressTrigger(ExerciseState s, EquipmentConfig cfg) {
    final step = ladderStepFor(s);

    if (step.backpackLoaded) {
      s.currentLoad += 5;
      s.microStepStage = 0;
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
      s.currentLoad = achievable == null ? 0 : equipment.roundDownToAchievable(target, achievable);
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
    if (step.backpackLoaded) {
      s.currentLoad = math.max(0, s.currentLoad - 5);
      return;
    }
    final achievable = _achievableSet(step, cfg);
    if (achievable == null) {
      if (s.microStepStage > 0) {
        s.microStepStage -= 1;
        return;
      }
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
      }
      return;
    }
    final lowerLoad = equipment.nextAchievableBelow(s.currentLoad, achievable);
    if (lowerLoad < s.currentLoad) {
      s.currentLoad = lowerLoad;
    } else if (s.microStepStage > 0) {
      // At the equipment floor, remove one active tempo/pause/ROM modifier.
      s.microStepStage -= 1;
    }
  }

  void _enterDeload(ExerciseState s) {
    s.preDeloadLoad = s.currentLoad;
    s.preDeloadLadderStepIndex = s.ladderStepIndex;
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
      _stepPrescriptionBack(s, cfg);
      s.status = ExerciseStatus.progress;
      s.deloadSessionsRemaining = 0;
      s.preDeloadLoad = null;
      s.preDeloadLadderStepIndex = null;
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
    if (state.status == ExerciseStatus.deload) {
      return PrescriptionResolution(state, deloadActive: true);
    }
    if (state.painReentryTestOffered && !state.painReentryTestPassed) {
      final step = ladderStepFor(state);
      final achievable = _achievableSet(step, cfg);
      final base = state.prePainLoad ?? state.currentLoad;
      final testLoad = achievable == null ? base * 0.5 : equipment.roundDownToAchievable(base * 0.5, achievable);
      final next = state.clone()..currentLoad = testLoad;
      return PrescriptionResolution(next, painReentryTestFired: true);
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
    next.currentLoad = achievable == null ? next.currentLoad * pct : equipment.roundDownToAchievable(next.currentLoad * pct, achievable);
    next.status = ExerciseStatus.progress;
    return PrescriptionResolution(next, detrainFired: true);
  }

  /// Called for the first pain-free session after a passed re-entry test:
  /// resume at the *lower* of (detraining-adjusted load, pre-pain load - 1
  /// increment); detraining percentages never stack on top of an active
  /// pain protocol (§6.6 precedence note).
  ExerciseState resolvePostReentryResume(ExerciseState state, DateTime today, EquipmentConfig cfg) {
    final next = state.clone();
    final base = state.prePainLoad ?? state.currentLoad;
    final step = ladderStepFor(next);
    final achievable = _achievableSet(step, cfg);
    final detrainAdjusted =
        achievable == null ? base * _detrainPercent(state.daysUntrained(today)) : equipment.roundDownToAchievable(base * _detrainPercent(state.daysUntrained(today)), achievable);
    final preMinusOne = achievable == null ? base : equipment.nextAchievableBelow(base, achievable);
    next.currentLoad = math.min(detrainAdjusted, preMinusOne);
    next.status = ExerciseStatus.progress;
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
    return next;
  }
}
