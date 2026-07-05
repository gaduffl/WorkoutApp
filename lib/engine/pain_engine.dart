import '../models/exercise_state.dart';
import '../models/ladders.dart';
import '../models/movement_pattern.dart';
import '../models/pain.dart';

enum PainActionKind { none, reduceLoadOne, regressLadderAndReduce, substituteNamed, removePattern }

class PainAction {
  final PainActionKind kind;
  final SubstituteExercise? substitute;

  const PainAction(this.kind, {this.substitute});
}

/// §7.1 region/pattern substitution table, made deterministic. The design
/// doc's table is written in free text for a human coach; this resolves it
/// to one of a small set of mechanical actions per (region, pattern,
/// severity), anchored to the worked example in §5 (sharp lower back:
/// hinge -> "bridge hamstring curl" substitute, squat -> -1 increment).
class PainEngine {
  const PainEngine();

  PainAction resolve(BodyRegion region, PainSeverity severity, MovementPattern pattern) {
    const mild = PainSeverity.mild;
    switch (region) {
      case BodyRegion.lowerBack:
        if (pattern == MovementPattern.hinge) {
          return severity == mild
              ? const PainAction(PainActionKind.regressLadderAndReduce)
              : const PainAction(PainActionKind.substituteNamed, substitute: bridgeHamstringCurl);
        }
        if (pattern == MovementPattern.squat) {
          return const PainAction(PainActionKind.reduceLoadOne);
        }
        return const PainAction(PainActionKind.none);

      case BodyRegion.kneeLeft:
      case BodyRegion.kneeRight:
        if (pattern == MovementPattern.squat) {
          return severity == mild
              ? const PainAction(PainActionKind.regressLadderAndReduce)
              : const PainAction(PainActionKind.removePattern);
        }
        return const PainAction(PainActionKind.none);

      case BodyRegion.shoulderLeft:
      case BodyRegion.shoulderRight:
        const affected = {
          MovementPattern.pushVertical,
          MovementPattern.pushHorizontal,
          MovementPattern.pullVertical,
          MovementPattern.pullHorizontal,
        };
        if (!affected.contains(pattern)) return const PainAction(PainActionKind.none);
        if (severity == mild) return const PainAction(PainActionKind.regressLadderAndReduce);
        if (pattern == MovementPattern.pushVertical) return const PainAction(PainActionKind.removePattern);
        if (pattern == MovementPattern.pushHorizontal) {
          return const PainAction(PainActionKind.substituteNamed, substitute: floorPress);
        }
        if (pattern == MovementPattern.pullVertical) return const PainAction(PainActionKind.removePattern);
        return const PainAction(PainActionKind.reduceLoadOne); // pullHorizontal: rows preferred over pull-ups

      case BodyRegion.elbow:
      case BodyRegion.wrist:
        const affected = {
          MovementPattern.pullVertical,
          MovementPattern.pullHorizontal,
          MovementPattern.coreGrip,
          MovementPattern.pushVertical,
          MovementPattern.pushHorizontal,
        };
        if (!affected.contains(pattern)) return const PainAction(PainActionKind.none);
        if (severity == mild) return const PainAction(PainActionKind.reduceLoadOne);
        if (pattern == MovementPattern.coreGrip) return const PainAction(PainActionKind.removePattern);
        return const PainAction(PainActionKind.reduceLoadOne);

      case BodyRegion.hip:
        if (pattern == MovementPattern.squat || pattern == MovementPattern.hinge) {
          // Sharp hip is a session-level swap (see [hipSharpForcesSessionSwap]),
          // not a per-exercise action.
          return severity == mild
              ? const PainAction(PainActionKind.regressLadderAndReduce)
              : const PainAction(PainActionKind.none);
        }
        return const PainAction(PainActionKind.none);
    }
  }

  /// §7.1: sharp hip pain -> "swap to upper session" is resolved at the
  /// session-selection level rather than per exercise.
  bool hipSharpActive(List<PainFlag> pain) {
    return pain.any((f) => f.region == BodyRegion.hip && f.severity == PainSeverity.sharp);
  }

  /// §7.2 escalation rule: sharp flag persisting > 7 days, or any of the
  /// radiating/numbness/tingling tags, triggers a fixed medical notice and
  /// stops recommending the pattern until manually cleared. Deterministic;
  /// the AI layer must never soften or override this text.
  bool isEscalated(PainFlag flag, DateTime today) {
    final daysSince = today.difference(flag.flaggedDate).inDays;
    final hardTag = flag.tags.intersection(const {
      PainTag.radiating,
      PainTag.numbness,
      PainTag.tingling,
    }).isNotEmpty;
    return (flag.severity == PainSeverity.sharp && daysSince > 7) || hardTag;
  }

  /// Advances one pattern's pain-freeze bookkeeping for today. Call once
  /// per pattern per day, in Step 6.2.4/§7.2 order: after any session
  /// scheduling/completion is known.
  ExerciseState advanceFlagState(
    ExerciseState state, {
    required PainFlag? activeFlag,
    required bool patternScheduledToday,
    required bool sessionRanPainFree,
  }) {
    final next = state.clone();

    if (activeFlag == null) {
      if (next.painFrozen && next.painSeverity == PainSeverity.mild && sessionRanPainFree) {
        _clearFreeze(next);
        return next;
      } else if (next.painFrozen && next.painSeverity == PainSeverity.sharp && next.painReentryTestPassed) {
        _clearFreeze(next);
        return next;
      }
      // A freeze persists across days without re-tapping the body map
      // (§7.2: the flag lives until it decays/clears, not per check-in) —
      // the scheduled-while-flagged counter must keep ticking.
      if (next.painFrozen && patternScheduledToday) {
        next.sessionsScheduledWhileFlagged += 1;
        if (next.painSeverity == PainSeverity.sharp && next.sessionsScheduledWhileFlagged >= 2) {
          next.painReentryTestOffered = true;
        }
      }
      return next;
    }

    if (!next.painFrozen) {
      next.painFrozen = true;
      next.painSeverity = activeFlag.severity;
      next.painRegion = activeFlag.region;
      next.painFlaggedDate = activeFlag.flaggedDate;
      next.sessionsScheduledWhileFlagged = 0;
      next.prePainLoad = next.currentLoad;
      next.prePainLadderStepIndex = next.ladderStepIndex;
      next.painReentryTestOffered = false;
      next.painReentryTestPassed = false;
    } else {
      // Severity can only escalate while frozen (mild -> sharp); a sharp
      // freeze never softens just because today's tap said mild.
      if (activeFlag.severity == PainSeverity.sharp) {
        next.painSeverity = PainSeverity.sharp;
      }
      next.painRegion ??= activeFlag.region;
    }

    if (patternScheduledToday) {
      next.sessionsScheduledWhileFlagged += 1;
    }

    // §7.2: sharp flags substituted for >=2 scheduled sessions, then the
    // app offers the graded re-entry test (50% of pre-pain load x 8).
    if (next.painSeverity == PainSeverity.sharp && next.sessionsScheduledWhileFlagged >= 2) {
      next.painReentryTestOffered = true;
    }

    return next;
  }

  void _clearFreeze(ExerciseState s) {
    s.painFrozen = false;
    s.painSeverity = null;
    s.painRegion = null;
    s.painFlaggedDate = null;
    s.sessionsScheduledWhileFlagged = 0;
    s.painReentryTestOffered = false;
    s.painReentryTestPassed = false;
  }
}
