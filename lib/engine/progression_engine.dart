import 'dart:math' as math;

import '../models/equipment.dart';
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

  (int, int) repRangeFor(ExerciseState state) {
    if (state.trackKey.startsWith('sub:')) return (8, 15); // §7.1 ONBOARD_SUBSTITUTE
    return state.pattern.repRange;
  }

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
    if (workSets.isEmpty) return state;
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

    final (low, high) = repRangeFor(next);
    final anyBelowRange = workSets.any((s) => s.reps < low);
    final anyRir0 = workSets.any((s) => s.rir == Rir.rir0);
    final allAtTopHighRir =
        workSets.every((s) => s.reps >= high && (s.rir == Rir.rir2 || s.rir == Rir.rir3plus));

    if (next.awaitingUndershootCheck) {
      next.awaitingUndershootCheck = false;
      if (workSets.every((s) => s.rir == Rir.rir3plus)) {
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
    final step = ladderStepFor(s);
    if (step.backpackLoaded) {
      s.currentLoad = math.max(0, s.currentLoad - 5);
      return;
    }
    final achievable = _achievableSet(step, cfg);
    if (achievable == null) return;
    s.currentLoad = equipment.nextAchievableBelow(s.currentLoad, achievable);
  }

  void _enterDeload(ExerciseState s) {
    s.preDeloadLoad = s.currentLoad;
    s.preDeloadLadderStepIndex = s.ladderStepIndex;
    s.status = ExerciseStatus.deload;
    s.deloadSessionsRemaining = 2;
  }

  /// §6.5: deload parameters (60% load, 50% sets, RIR>=4) are applied by the
  /// plan-assembly step; here we just count down the 2-session window and
  /// auto-return "at the pre-deload prescription minus one micro-step".
  ExerciseState _handleDeloadSession(ExerciseState s, EquipmentConfig cfg) {
    s.deloadSessionsRemaining -= 1;
    if (s.deloadSessionsRemaining <= 0) {
      final preLoad = s.preDeloadLoad ?? s.currentLoad;
      final step = ladderStepFor(s);
      final achievable = _achievableSet(step, cfg);
      s.currentLoad = achievable == null
          ? preLoad
          : equipment.nextAchievableBelow(preLoad, achievable);
      s.status = ExerciseStatus.progress;
      s.deloadSessionsRemaining = 0;
      s.preDeloadLoad = null;
      s.preDeloadLadderStepIndex = null;
    }
    return s;
  }

  /// Global deload trigger (§6.3): >=3 RED days in 7, or a manual "feeling
  /// beat up" trigger. Applies to every non-frozen pattern.
  List<ExerciseState> forceGlobalDeload(List<ExerciseState> states) {
    return states.map((s) {
      if (s.painFrozen || s.status == ExerciseStatus.deload) return s;
      final next = s.clone();
      _enterDeload(next);
      return next;
    }).toList();
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

    final days = state.daysUntrained(today);
    if (days < 10) return PrescriptionResolution(state);

    final next = state.clone();
    if (days > 21) {
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
    next.painFlaggedDate = null;
    next.sessionsScheduledWhileFlagged = 0;
    next.painReentryTestOffered = false;
    next.painReentryTestPassed = false;
    next.prePainLoad = null;
    next.prePainLadderStepIndex = null;
    return next;
  }
}
