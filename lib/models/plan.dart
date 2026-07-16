import 'cardio_protocol.dart';
import 'exercise_metric.dart';
import 'movement_pattern.dart';
import 'session_type.dart';
import 'set_log.dart';

class PlannedExercise {
  final String trackKey;
  final MovementPattern pattern;
  final String name;
  final int sets;
  final ExerciseMetric metric;
  final (int, int) targetRange;
  final double? loadTotal;

  /// Human-readable load setup, e.g. "2x large @ 25 lb" or
  /// "L: 45 / R: 50, swap after each set" (§2.6 rule 1 & 3).
  final String? loadDisplay;
  final Rir rirTarget;
  final String? substitutedFrom;
  final bool isWarmup;
  final String? instruction;

  /// §6.6: after real positive work, a detraining-adjusted prescription
  /// becomes the safe baseline (otherwise stamping recency after a partial
  /// comeback would snap the next plan back to the harder pre-break state).
  /// Full prescribed work is still required for normal progression.
  final bool persistLoadOnCompletion;

  /// Whether completing this work is allowed to advance the exercise state.
  /// Readiness-modulated YELLOW/RED prescriptions deliberately retain the
  /// exercise but suppress progression for that session.
  final bool progressionEligible;

  /// §12 travel mode: bodyweight variant — progression state is frozen for
  /// the pattern (lastTrained still updates on completion).
  final bool isTravel;

  /// §2.6: the achievable dumbbell *totals* for this exercise, so the logger
  /// steps weight through real PowerBlock jumps instead of a flat ±5.
  /// Null for bodyweight / backpack-loaded / travel (free-entry) exercises.
  final List<double>? loadSteps;

  /// §2.5: work exercises that share a superset group are alternated with
  /// ~90 s rest after the *pair*. Null = run as straight sets. Warm-ups are
  /// never grouped.
  final int? supersetGroup;

  /// True only when this entry fills a primary compound slot in the session
  /// template. This is explicit because named accessories can reuse a
  /// compound movement-pattern bucket for pain mapping without needing a
  /// compound load ramp or compound minimum-set protection.
  final bool isCompoundWork;

  /// Marks the single 60%-load feeder before a later loaded compound. The
  /// duration budgeter may remove these only after accessory and work-set
  /// reductions; the first compound's load ramp is never a feeder.
  final bool isFeederWarmup;

  /// This exact work entry is the formal pain re-entry test generated from a
  /// pending frozen state. Legacy or merely similar-looking work must never
  /// clear the freeze.
  final bool isPainReentryTest;

  const PlannedExercise({
    required this.trackKey,
    required this.pattern,
    required this.name,
    required this.sets,
    required this.targetRange,
    this.metric = ExerciseMetric.reps,
    this.loadTotal,
    this.loadDisplay,
    required this.rirTarget,
    this.substitutedFrom,
    this.isWarmup = false,
    this.instruction,
    this.persistLoadOnCompletion = false,
    this.progressionEligible = true,
    this.isTravel = false,
    this.loadSteps,
    this.supersetGroup,
    this.isCompoundWork = false,
    this.isFeederWarmup = false,
    this.isPainReentryTest = false,
  });

  /// Compatibility alias for existing callers and persisted plan consumers.
  /// New code should use [targetRange] together with [metric].
  (int, int) get repRange => targetRange;

  String get targetLabel => metric.formatRange(targetRange);

  PlannedExercise copyWith({
    int? sets,
    int? supersetGroup,
  }) =>
      PlannedExercise(
        trackKey: trackKey,
        pattern: pattern,
        name: name,
        sets: sets ?? this.sets,
        targetRange: targetRange,
        metric: metric,
        loadTotal: loadTotal,
        loadDisplay: loadDisplay,
        rirTarget: rirTarget,
        substitutedFrom: substitutedFrom,
        isWarmup: isWarmup,
        instruction: instruction,
        persistLoadOnCompletion: persistLoadOnCompletion,
        progressionEligible: progressionEligible,
        isTravel: isTravel,
        loadSteps: loadSteps,
        supersetGroup: supersetGroup ?? this.supersetGroup,
        isCompoundWork: isCompoundWork,
        isFeederWarmup: isFeederWarmup,
        isPainReentryTest: isPainReentryTest,
      );
}

class SessionPlan {
  final SessionTypeId sessionId;
  final String sessionName;
  final SessionTier tier;
  final List<PlannedExercise> exercises;
  final int estimatedDurationMin;

  /// Exact cardio dose for cardio-only plans. Null keeps legacy strength and
  /// not-yet-migrated cardio plans fully backward compatible.
  final CardioPrescription? cardioPrescription;

  /// §2.1/§5 Step 6: readiness swaps (RED technique session) leave the
  /// original queue item pending — completing them grants no queue credit.
  final bool grantsQueueCredit;

  /// The plan was generated while no-equipment travel mode was active.
  /// Stored on the plan rather than inferred from exercises so cardio-only
  /// plans and historical logs retain the correct context too.
  final bool travelMode;

  /// The conservative 9-minute upper bound of CAROL's REHIT Intense preset
  /// was explicitly withheld from this strength plan after all
  /// recommendation-time hard gates passed. A later safety change cannot
  /// create an unbudgeted finisher.
  final bool optionalRehitFinisherReserved;

  const SessionPlan({
    required this.sessionId,
    required this.sessionName,
    required this.tier,
    required this.exercises,
    required this.estimatedDurationMin,
    this.cardioPrescription,
    this.grantsQueueCredit = true,
    this.travelMode = false,
    this.optionalRehitFinisherReserved = false,
  });

  int get plannedWorkSets =>
      exercises.where((e) => !e.isWarmup).fold(0, (sum, e) => sum + e.sets);
}

/// Non-workout outcomes: rest day, forced rest, "wrap up" style short plans
/// are still represented as a [SessionPlan] with sessionId == null via
/// [RestOutcome] instead, keeping the pure function's return type simple.
class RestOutcome {
  final String reason;
  final bool queueFrozen;
  const RestOutcome({required this.reason, this.queueFrozen = true});
}
