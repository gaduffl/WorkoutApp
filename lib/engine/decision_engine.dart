import '../models/check_in.dart';
import '../models/decision_trace.dart';
import '../models/equipment.dart';
import '../models/exercise_metric.dart';
import '../models/exercise_state.dart';
import '../models/floor_category.dart';
import '../models/ladders.dart';
import '../models/movement_pattern.dart';
import '../models/pain.dart';
import '../models/plan.dart';
import '../models/recovery_snapshot.dart';
import '../models/rule_key.dart';
import '../models/session_log.dart';
import '../models/session_type.dart';
import '../models/set_log.dart';
import '../models/stimulus_ledger.dart';
import '../models/training_status.dart';
import '../models/training_targets.dart';
import '../models/user_settings.dart';
import 'cardio_engine.dart';
import 'equipment_engine.dart';
import 'intensity_recovery_policy.dart';
import 'pain_engine.dart';
import 'progression_engine.dart';
import 'queue_engine.dart';
import 'readiness_engine.dart';
import 'session_templates.dart';
import 'strength_duration_engine.dart';
import 'stimulus_ledger_engine.dart';
import 'training_status_engine.dart';

/// Why a caller asked the engine to preserve or choose a specific session.
/// Internal recomputations must not masquerade as an explicit user swap in
/// the persisted decision trace.
enum ForcedSessionProvenance {
  manualOverride,
  internalRefresh,
}

class DecisionEngineInput {
  final CheckIn checkin;
  final RecoverySnapshot? todaySnapshot;
  final List<RecoverySnapshot> recoveryHistory;
  final List<CheckIn> checkinHistory;
  final List<SessionLog> sessionLogs;
  final Map<String, ExerciseState> exerciseStates;
  final QueueState queueState;
  final UserSettings settings;
  final DateTime today;

  /// Optional personal optimization targets. The default remains immutable
  /// and app-owned; callers only need to pass this when evaluating a target
  /// variant in a deterministic simulation.
  final TrainingTargets? trainingTargets;

  /// §11's "swap session": when set, Step 5 picks this candidate instead
  /// of the natural highest scorer (it must still be one of the ranked
  /// candidates - the caller offers only real alternatives). Every other
  /// step (readiness modulation, time compression, pain substitution,
  /// load resolution) still runs normally against it. A forced strength
  /// template that has no pain-safe work can never override the hard medical
  /// gate; the engine selects the highest-ranked pain-feasible strength
  /// alternative instead.
  final SessionTypeId? forcedSessionId;

  /// Defaults to the public/manual behavior for backwards compatibility.
  /// Callers that merely preserve a plan during an internal refresh must opt
  /// into [ForcedSessionProvenance.internalRefresh].
  final ForcedSessionProvenance forcedSessionProvenance;

  const DecisionEngineInput({
    required this.checkin,
    required this.todaySnapshot,
    required this.recoveryHistory,
    required this.checkinHistory,
    required this.sessionLogs,
    required this.exerciseStates,
    required this.queueState,
    required this.settings,
    required this.today,
    this.trainingTargets,
    this.forcedSessionId,
    this.forcedSessionProvenance = ForcedSessionProvenance.manualOverride,
  });
}

class DecisionEngineOutput {
  final DecisionTrace trace;

  /// Pain-lifecycle bookkeeping updates that should be persisted immediately
  /// (this happens at check-in time, independent of whether the session is
  /// later completed - §7.2's "scheduled" counter must tick regardless).
  final Map<String, ExerciseState> patchedExerciseStates;

  const DecisionEngineOutput(this.trace, this.patchedExerciseStates);
}

/// §5: the core recommendation algorithm. `(CheckIn, RecoverySnapshot,
/// History, States) -> (Plan, DecisionTrace)` - pure and deterministic.
class DecisionEngine {
  const DecisionEngine();

  static const _hardTimeWindows = {0, 20, 35, 60};
  static const _fourByFourAvailabilityWindowMin = 35;

  static const readinessEngine = ReadinessEngine();
  static const cardioEngine = CardioEngine();
  static const queueEngine = QueueEngine();
  static const painEngine = PainEngine();
  static const progressionEngine = ProgressionEngine();
  static const equipmentEngine = EquipmentEngine();
  static const intensityRecoveryPolicy = IntensityRecoveryPolicy();
  static const stimulusLedgerEngine = StimulusLedgerEngine();
  static const trainingStatusEngine = TrainingStatusEngine();
  static const exerciseMuscleMap = ExerciseMuscleMap();
  static const strengthDurationBudgeter = StrengthDurationBudgeter();

  DecisionEngineOutput decide(DecisionEngineInput input) {
    if (!_hardTimeWindows.contains(input.checkin.timeMinutes)) {
      throw ArgumentError.value(
        input.checkin.timeMinutes,
        'checkin.timeMinutes',
        'Must be one of the immutable 0, 20, 35, or 60 minute windows',
      );
    }
    final fired = <FiredRule>[];
    final today = input.today;
    final checkin = input.checkin;

    final recovery = readinessEngine.compute(
      subjective: checkin.subjective,
      today: input.todaySnapshot,
      history: input.recoveryHistory,
      asOf: today,
    );
    if (recovery.illnessGuardFired) fired.add(const FiredRule(RuleKey.illnessGuard));
    if (recovery.subjOverrideDownFired) fired.add(const FiredRule(RuleKey.subjOverrideDown));
    if (recovery.subjOverrideUpBlockedFired) fired.add(const FiredRule(RuleKey.subjOverrideUpBlocked));

    final recoveryTrace = RecoveryTrace(
      hrvZToday: recovery.hrvZToday,
      hrvTrend3: recovery.hrvTrend3,
      sleepScore: recovery.sleepScore,
      rhrDev: recovery.rhrDev,
      bucket: recovery.bucket,
      compositeScore: recovery.compositeScore,
      inputsMissing: recovery.inputsMissing,
    );

    final queueTraceBase = QueueTraceInfo(pointerBefore: input.queueState.pointer, servedBefore: input.queueState.served);

    // Pain-lifecycle bookkeeping: tick "scheduled while flagged" counters
    // regardless of what gets picked below (§7.2). Patched at the very end
    // once we know which patterns were actually scheduled.
    var patchedStates = Map<String, ExerciseState>.from(input.exerciseStates);

    // §6.3 automatic global deload is one episode per threshold crossing,
    // not a level-trigger that resets completed tracks on every evaluation
    // while the same RED cluster remains in the rolling window. Apply the
    // crossing before any rest short circuit so the current third RED still
    // persists the episode even when it is also the second consecutive RED.
    final redDaysToday =
        _redDaysInRollingWindow(input, recovery.bucket, today);
    final yesterday = today.subtract(const Duration(days: 1));
    final redDaysYesterday = _redDaysInRollingWindow(
      input,
      _bucketForDate(input, yesterday),
      yesterday,
    );
    final automaticGlobalDeload =
        redDaysToday >= 3 && redDaysYesterday < 3;
    if (automaticGlobalDeload) {
      patchedStates = progressionEngine.forceGlobalDeloadForBuiltInTracks(
        patchedStates,
      );
    }

    // A pain tap is check-in state, not plan state. Persist it before either
    // Step-1 rest return and before session selection so a rest/cardio day or
    // a pain-driven session swap cannot make the flag disappear tomorrow.
    // Only normal plan-backed tracks are eligible here: the seven progressing
    // pattern ladders plus S5's three named accessories. Pain-only substitute
    // tracks are materialized later, and only when actually prescribed.
    patchedStates = _persistCurrentCheckInPain(
      patchedStates,
      checkin.pain,
      today,
    );
    final sharpHipPainActive = painEngine.hipSharpActive(checkin.pain) ||
        patchedStates.values.any(
          (state) =>
              state.painFrozen &&
              state.painSeverity == PainSeverity.sharp &&
              state.painRegion == BodyRegion.hip,
        );

    // --- Step 1: rest-day short-circuit ---
    if (checkin.timeMinutes == 0) {
      fired.add(const FiredRule(RuleKey.restTimeZero));
      return DecisionEngineOutput(
        DecisionTrace(
          date: today,
          checkin: checkin,
          recovery: recoveryTrace,
          candidates: const [],
          firedRules: fired,
          plan: null,
          restReason: 'Rest day',
          queue: queueTraceBase,
        ),
        patchedStates,
      );
    }

    final yesterdayBucket = _bucketForDate(input, yesterday);
    if (recovery.bucket == ReadinessBucket.red && yesterdayBucket == ReadinessBucket.red) {
      fired.add(const FiredRule(RuleKey.restDoubleRed));
      return DecisionEngineOutput(
        DecisionTrace(
          date: today,
          checkin: checkin,
          recovery: recoveryTrace,
          candidates: const [],
          firedRules: fired,
          plan: null,
          restReason: 'Two RED days in a row - full rest or a light walk',
          queue: queueTraceBase,
        ),
        patchedStates,
      );
    }

    // --- Step 2: candidate filtering and target-status calculation ---
    final feasible = _feasibleCandidates(checkin.timeMinutes)
        .where(
          (id) =>
              !input.settings.travelMode ||
              (id != SessionTypeId.s3 && id != SessionTypeId.s7),
        )
        .toList();
    final targets = input.trainingTargets ?? TrainingTargets();
    final ledgerAsOf = _isSameDate(checkin.timestamp, today)
        ? checkin.timestamp
        : today;
    final ledger = stimulusLedgerEngine.buildFromSessionLogs(
      logs: input.sessionLogs,
      asOf: ledgerAsOf,
    );
    final trainingStatus = trainingStatusEngine.build(
      targets: targets,
      ledger: ledger,
    );
    final fourByFour = _aerobicStatus(
      trainingStatus,
      AerobicTargetKind.norwegian4x4Anchor,
    );
    final rehitFallback = _aerobicStatus(
      trainingStatus,
      AerobicTargetKind.rehitSeparateDayFallback,
    );
    final longBase = _aerobicStatus(
      trainingStatus,
      AerobicTargetKind.longBaseExposure,
    );
    final shortBase = _aerobicStatus(
      trainingStatus,
      AerobicTargetKind.shortBaseExposure,
    );
    final fourByFourDue = fourByFour.exposureDeficit > 0;
    final rehitFallbackDue = targets.fallbackRehitRequiresSeparateDays
        ? rehitFallback.distinctDayDeficit > 0
        : rehitFallback.exposureDeficit > 0;
    // The weekly high-intensity target is disjunctive: one qualifying 4x4 is
    // preferred, while the configured REHIT dose is its fallback. Once either
    // path is complete, natural planning must not add the other as surplus
    // intensity. Protocol-specific history remains separate in the ledger.
    final naturalHighIntensityTargetDue =
        fourByFourDue && rehitFallbackDue;
    final highIntensitySafety =
        intensityRecoveryPolicy.evaluateHighIntensitySafety(
      logs: input.sessionLogs,
      asOf: ledgerAsOf,
      checkInPain: checkin.pain,
      exerciseStates: input.exerciseStates.values,
      automaticGlobalDeload: automaticGlobalDeload,
      travelMode: input.settings.travelMode,
    );
    final canAdvanceFourByFour = naturalHighIntensityTargetDue &&
        checkin.timeMinutes >= _fourByFourAvailabilityWindowMin &&
        !highIntensitySafety.blocked;
    final strengthStimulusMultiplier = automaticGlobalDeload
        ? 0.0
        : switch (recovery.bucket) {
            ReadinessBucket.green => 1.0,
            ReadinessBucket.yellow => 0.75,
            // RED technique work runs at RIR 4+ and is deliberately
            // nonqualifying under TargetEffortPolicy.
            ReadinessBucket.red => 0.0,
          };

    // --- Step 3: target-dose scoring ---
    final yesterdayLegHeavy = input.sessionLogs.any((l) =>
        _isSameDate(l.date, yesterday) && l.countsTowardQueueAndFloor && sessionTypes[l.templateId]!.legHeavy);

    final scored = <_Scored>[];
    for (final id in feasible) {
      final def = sessionTypes[id]!;
      final tier = id == SessionTypeId.s3 || id == SessionTypeId.s7
          ? SessionTier.full
          : tierForTime(checkin.timeMinutes);
      final terms = <String, int>{};

      // The queue remains useful as a deterministic rotation/tie-breaker,
      // but its maximum five-point effect cannot outweigh an actual target
      // deficit.
      terms['base'] = 10;
      if (cycleOrder.contains(id)) {
        final dist = queueEngine.cycleDistance(id, input.queueState);
        terms['queueTieBreak'] = cycleOrder.length - dist;
      }

      if (id == SessionTypeId.s3 && canAdvanceFourByFour) {
        // The preferred VO2-max anchor is always the first target in any
        // slot that can actually hold it.
        terms['norwegian4x4Due'] = 20000;
      }

      final canAdvanceRehitFallback = naturalHighIntensityTargetDue &&
          checkin.timeMinutes == 20 &&
          !highIntensitySafety.blocked;
      if (id == SessionTypeId.s7 && canAdvanceRehitFallback) {
        terms['rehitFallbackDue'] = 20000;
      }
      final surplusOrRecoveryBlockedFourByFour =
          id == SessionTypeId.s3 && !canAdvanceFourByFour;
      final surplusRehit =
          id == SessionTypeId.s7 && !canAdvanceRehitFallback;
      final unadvanceableConceptualS3 = id == SessionTypeId.s3 &&
          checkin.timeMinutes == 20 &&
          !canAdvanceRehitFallback;
      if (surplusOrRecoveryBlockedFourByFour ||
          surplusRehit ||
          unadvanceableConceptualS3) {
        // Natural recommendations never add surplus high intensity. A forced
        // surplus selection remains an explicit personal override only when
        // every hard recovery/safety gate below passes.
        terms['surplusIntensitySuppressed'] = -100000;
      }

      if (id == SessionTypeId.s6) {
        if (checkin.timeMinutes >= targets.baseLongExposureMinutes &&
            longBase.exposureDeficit > 0) {
          terms['baseLongDeficit'] = 15000;
        } else if (checkin.timeMinutes >=
                targets.baseShortExposureMinutes.reduce(
                  (current, next) => current < next ? current : next,
                ) &&
            shortBase.exposureDeficit > 0) {
          terms['baseShortDeficit'] = 12000;
        }
      }

      if (def.countsAs.contains(FloorCategory.strength)) {
        final workSlots = _workSlotsForSession(
          sessionId: id,
          tier: tier,
          ledger: ledger,
          targets: targets,
          stimulusSetMultiplier: strengthStimulusMultiplier,
          travelMode: input.settings.travelMode,
        );
        final painAdjusted = _painAdjustedStrengthProjection(
          workSlots,
          template: sessionTemplates[id]!,
          tier: tier,
          input: input,
          states: patchedStates,
        );
        if (!painAdjusted.hasPainSafeWork) {
          // Retain the candidate in the audit trace, but make its hard
          // unavailability explicit for selection and UI alternative lists.
          terms[painNoSafeWorkScoreTerm] = 0;
        }
        terms.addAll(_strengthScoreTerms(
          slots: painAdjusted.stimulusSlots,
          template: sessionTemplates[id]!,
          tier: tier,
          ledger: ledger,
          targets: targets,
          stimulusSetMultiplier: strengthStimulusMultiplier,
        ));
      }

      if (def.legHeavy && yesterdayLegHeavy) {
        terms['legHeavyDemoted'] = -30;
      }

      final score = terms.values.fold(0, (a, b) => a + b);
      scored.add(_Scored(id, tier, score, terms, def));
    }

    // --- Step 5: selection ---
    int compareCandidates(
      _Scored a,
      _Scored b, {
      bool ignoreLegHeavyDemotion = false,
    }) {
      final aScore = ignoreLegHeavyDemotion
          ? a.score - (a.terms['legHeavyDemoted'] ?? 0)
          : a.score;
      final bScore = ignoreLegHeavyDemotion
          ? b.score - (b.terms['legHeavyDemoted'] ?? 0)
          : b.score;
      final byScore = bScore.compareTo(aScore);
      if (byScore != 0) return byScore;
      final aCycle = cycleOrder.contains(a.id);
      final bCycle = cycleOrder.contains(b.id);
      if (aCycle && bCycle) return cycleOrder.indexOf(a.id).compareTo(cycleOrder.indexOf(b.id));
      if (aCycle != bCycle) return aCycle ? -1 : 1; // cycle members before S6/S7
      if (a.id == SessionTypeId.s7 && b.id == SessionTypeId.s6) return -1;
      if (a.id == SessionTypeId.s6 && b.id == SessionTypeId.s7) return 1;
      return 0;
    }

    scored.sort((a, b) => compareCandidates(a, b));
    final winnerWithoutLegHeavyDemotion = yesterdayLegHeavy
        ? (scored.toList()
              ..sort(
                (a, b) => compareCandidates(
                  a,
                  b,
                  ignoreLegHeavyDemotion: true,
                ),
              ))
            .first
        : scored.first;

    final candidatesTrace = scored
        .map((s) => ScoredCandidate(sessionId: s.id, tier: s.tier, score: s.score, scoreTerms: s.terms))
        .toList();

    _Scored? forcedCandidate;
    if (input.forcedSessionId != null) {
      for (final candidate in scored) {
        if (candidate.id == input.forcedSessionId) {
          forcedCandidate = candidate;
          break;
        }
      }
    }
    final winner = forcedCandidate ?? scored.first;

    // §7.1: sharp hip pain swaps to the highest-ranked feasible upper-body
    // strength session. Cycling is also contraindicated, so this applies to
    // intensity/base-cardio winners as well as leg-heavy strength choices.
    // Only if no upper-strength option exists do we fall back to any other
    // non-leg-heavy candidate and let the shared safety gate resolve it.
    var chosen = winner;
    if (sharpHipPainActive) {
      final alt = scored.firstWhere(
        (candidate) =>
            !candidate.def.legHeavy &&
            candidate.def.countsAs.contains(FloorCategory.strength),
        orElse: () => scored.firstWhere(
          (candidate) => !candidate.def.legHeavy,
          orElse: () => chosen,
        ),
      );
      if (!identical(alt, chosen)) {
        chosen = alt;
        fired.add(const FiredRule(RuleKey.painSubSharp, pattern: 'HIP_SESSION_SWAP'));
      }
    }

    // Pattern-level medical escalation is evaluated before committing to a
    // strength template. If every work slot that the normal assembler would
    // emit is escalated or removed, a forced choice cannot bypass that hard
    // gate. Stay within the strength candidates and retain their established
    // score/order; cardio must not become a generic escape from a viable
    // pain-safe strength session. If none exists, keep the selected template
    // so normal assembly returns the existing explicit no-work/rest outcome.
    final slotStimulusMultiplier = switch (recovery.bucket) {
      ReadinessBucket.green => 1.0,
      ReadinessBucket.yellow => 0.75,
      ReadinessBucket.red => 0.0,
    };
    var chosenHasPainSafeWork = true;
    if (chosen.def.countsAs.contains(FloorCategory.strength)) {
      chosenHasPainSafeWork = _hasPainSafeStrengthWork(
        chosen,
        input: input,
        states: patchedStates,
        ledger: ledger,
        targets: targets,
        slotStimulusMultiplier: slotStimulusMultiplier,
      );
    }
    if (!chosenHasPainSafeWork) {
      for (final candidate in scored) {
        if (!candidate.def.countsAs.contains(FloorCategory.strength)) {
          continue;
        }
        if (sharpHipPainActive && candidate.def.legHeavy) continue;
        if (_hasPainSafeStrengthWork(
          candidate,
          input: input,
          states: patchedStates,
          ledger: ledger,
          targets: targets,
          slotStimulusMultiplier: slotStimulusMultiplier,
        )) {
          chosen = candidate;
          chosenHasPainSafeWork = true;
          break;
        }
      }
    }

    // A manual-override trace describes the final manual choice only. If a
    // hard pain gate rejects that choice, claiming it was selected would make
    // the explanation and persisted provenance false.
    if (forcedCandidate != null &&
        identical(chosen, forcedCandidate) &&
        chosenHasPainSafeWork &&
        input.forcedSessionProvenance ==
            ForcedSessionProvenance.manualOverride) {
      fired.add(FiredRule(
        RuleKey.manualSessionOverride,
        params: {'session': forcedCandidate.def.name},
      ));
    }

    var volumeCutForLegHeavyEscape = false;
    if (forcedCandidate == null &&
        identical(chosen, winner) &&
        yesterdayLegHeavy &&
        winner.id != winnerWithoutLegHeavyDemotion.id &&
        winnerWithoutLegHeavyDemotion.def.legHeavy) {
      fired.add(const FiredRule(RuleKey.legheavyDemoted));
    }
    if (chosen.def.legHeavy && yesterdayLegHeavy) {
      final allFeasibleLegHeavy = scored.every((s) => s.def.legHeavy);
      if (allFeasibleLegHeavy) {
        volumeCutForLegHeavyEscape = true;
        fired.add(const FiredRule(RuleKey.legheavyBacktobackVolumecut));
      }
    }
    // --- Step 6/7: readiness modulation + time compression (baseline first) ---
    var effectiveSessionId = chosen.id;
    var tier = chosen.tier;
    double setMultiplier = 1.0;
    double loadMultiplier = 1.0;
    Rir rirFloor = Rir.rir2;
    var progressionEligible = recovery.bucket == ReadinessBucket.green;
    var redTechnique = false;

    if (checkin.timeMinutes != 60 && chosen.tier == SessionTier.full && sessionTypes[effectiveSessionId]!.fullDurationMin == 60) {
      fired.add(const FiredRule(RuleKey.timeCompress60_35));
    }
    if (checkin.timeMinutes == 20 &&
        chosen.def.cycleMember &&
        chosen.def.countsAs.contains(FloorCategory.strength) &&
        chosen.def.isCompressible) {
      fired.add(const FiredRule(RuleKey.timeCompress35_20));
    }

    if (effectiveSessionId == SessionTypeId.s3 &&
        checkin.timeMinutes < _fourByFourAvailabilityWindowMin) {
      effectiveSessionId = SessionTypeId.s7;
      if (!highIntensitySafety.blocked) {
        fired.add(const FiredRule(RuleKey.s7TimeSub));
      }
    }

    // Target surplus can be chosen explicitly, but recovery, active deload,
    // contraindicating pain/escalation, and travel equipment are hard safety
    // gates. A forced or restored intensity choice must use recovery-safe
    // continuous work without claiming the 4x4/REHIT target rationale.
    if (highIntensitySafety.blocked &&
        (effectiveSessionId == SessionTypeId.s3 ||
            effectiveSessionId == SessionTypeId.s7)) {
      effectiveSessionId = SessionTypeId.s6;
      progressionEligible = false;
      fired.add(const FiredRule(RuleKey.recoverySwapEasyCardio));
    }

    // Readiness modulation evaluates the time-adjusted effective type. Both
    // intensity protocols are GREEN-only; YELLOW/RED use easy continuous
    // work that fits the same hard time window. A 20-minute version is
    // explicitly recovery work and cannot qualify as the 30+ minute base
    // exposure tracked by the ledger.
    if (recovery.bucket == ReadinessBucket.yellow) {
      if (effectiveSessionId == SessionTypeId.s1 ||
          effectiveSessionId == SessionTypeId.s2 ||
          effectiveSessionId == SessionTypeId.s4 ||
          effectiveSessionId == SessionTypeId.s5) {
        // Integer set prescriptions are reduced deterministically below;
        // avoid narrating a fixed percentage because 3 -> 2 and 2 -> 1 are
        // materially different reductions.
        setMultiplier = 0.75;
        rirFloor = Rir.rir2;
        progressionEligible = false;
        fired.add(const FiredRule(RuleKey.yellowVolumeCut));
      } else if (effectiveSessionId == SessionTypeId.s3 ||
          effectiveSessionId == SessionTypeId.s7) {
        effectiveSessionId = SessionTypeId.s6;
        progressionEligible = false;
        fired.add(const FiredRule(RuleKey.recoverySwapEasyCardio));
      }
    } else if (recovery.bucket == ReadinessBucket.red) {
      if (effectiveSessionId == SessionTypeId.s3 || effectiveSessionId == SessionTypeId.s7) {
        effectiveSessionId = SessionTypeId.s6;
        fired.add(const FiredRule(RuleKey.redSwapZ2));
      } else if (effectiveSessionId == SessionTypeId.s6) {
        // Zone 2 is already the recovery-safe cardio outcome. Keep it as-is;
        // strength technique load/set modifiers have no meaning here.
        fired.add(const FiredRule(RuleKey.redSwapZ2));
      } else {
        setMultiplier = 0.5;
        loadMultiplier = 0.6;
        rirFloor = Rir.rir4plus;
        progressionEligible = false;
        redTechnique = true; // §5 Step 6: a swap — the queue item stays pending
        fired.add(const FiredRule(RuleKey.redSwapTechnique));
      }
    }

    // CAROL interval presets are fixed bike programs. Availability can swap
    // S3 to S7, but neither preset is represented as a compressed or extended
    // app-authored tier.
    if (effectiveSessionId == SessionTypeId.s3 ||
        effectiveSessionId == SessionTypeId.s7) {
      tier = SessionTier.full;
    }

    if (volumeCutForLegHeavyEscape) {
      setMultiplier *= 0.8;
    }

    // Target rationale describes only the final protocol/session. A target
    // that caused a GREEN intensity candidate to become recovery cardio stays
    // open and is deliberately not claimed as completed here.
    if (effectiveSessionId == SessionTypeId.s3 &&
        chosen.terms.containsKey('norwegian4x4Due')) {
      fired.add(const FiredRule(RuleKey.norwegian4x4Due));
    }
    if (effectiveSessionId == SessionTypeId.s7 &&
        chosen.terms.containsKey('rehitFallbackDue')) {
      fired.add(const FiredRule(RuleKey.rehitFallbackDue));
    }
    if (effectiveSessionId == SessionTypeId.s6 &&
        chosen.terms.containsKey('baseLongDeficit')) {
      fired.add(const FiredRule(RuleKey.baseLongDeficit));
    }
    if (effectiveSessionId == SessionTypeId.s6 &&
        chosen.terms.containsKey('baseShortDeficit')) {
      fired.add(const FiredRule(RuleKey.baseShortDeficit));
    }
    if (effectiveSessionId == SessionTypeId.s6 &&
        !chosen.terms.containsKey('baseLongDeficit') &&
        !chosen.terms.containsKey('baseShortDeficit') &&
        !fired.any(
          (rule) =>
              rule.key == RuleKey.recoverySwapEasyCardio ||
              rule.key == RuleKey.redSwapZ2,
        )) {
      // S6 is also a useful low-fatigue/recovery choice when every tracked
      // base target is already filled. Keep that rationale explicit instead
      // of implying queue membership or inventing a base-target deficit.
      fired.add(const FiredRule(RuleKey.easyRecoveryCardio));
    }
    if (chosen.terms.containsKey('muscleRecoveryDemotion')) {
      fired.add(const FiredRule(RuleKey.muscleRecoveryDemotion));
    }
    if (chosen.terms.containsKey('muscleOverMaxDemotion')) {
      fired.add(const FiredRule(RuleKey.muscleOverMaxDemotion));
    }
    // QUEUE_NEXT only describes an unchanged, credit-bearing natural cycle
    // pick. Forced, pain-swapped, readiness-swapped, and time-substituted
    // plans are explained by their own rule keys.
    if (input.forcedSessionId == null &&
        chosen.id == input.queueState.pointer &&
        chosen.id == effectiveSessionId &&
        !redTechnique &&
        cycleOrder.contains(chosen.id)) {
      fired.add(FiredRule(
        RuleKey.queueNext,
        params: {'session': chosen.def.name},
      ));
    }

    // --- Plan assembly (Steps 7-9) ---
    // Keep the post-global-deload baseline so duration trimming can undo
    // pain-scheduling bookkeeping for work that is not ultimately emitted.
    final planAssemblyStateBaseline = {
      for (final entry in patchedStates.entries) entry.key: entry.value.clone(),
    };
    final template = sessionTemplates[effectiveSessionId];
    final exercises = <PlannedExercise>[];

    if (template != null && !template.isCardioOnly) {
      final prepPainAware = _prepPainActive(input, template);
      final kneePainActive = _activeKneePain(input);
      // S4's ATG block replaces general movement prep, not the first loaded
      // compound's percent-load ramp.
      var loadedCompoundRampDone = false;
      if (template.hasKneeHealthBlock) {
        final atgMinutes =
            StrengthPrepPolicy.atgMinutes(checkin.timeMinutes);
        final String prepName;
        final String prepInstruction;
        if (kneePainActive) {
          prepName = 'Pain-aware general + upper/scapular prep';
          prepInstruction =
              'Within $atgMinutes min: use easy pain-free whole-body movement, breathing/bracing, and non-reproducing upper/scapular motion. Skip backward treadmill and every flagged or pain-provoking knee movement.';
        } else if (prepPainAware) {
          prepName = 'Pain-aware movement prep';
          prepInstruction =
              'Within $atgMinutes min: use only pain-free movement, breathing/bracing, and non-reproducing lower-body or scapular rehearsal. Skip every flagged or pain-provoking movement.';
        } else {
          prepName = input.settings.travelMode
              ? 'Travel ATG + upper-body prep'
              : 'ATG + upper-body prep';
          prepInstruction = input.settings.travelMode
              ? atgMinutes == 3
                  ? '0:00–1:00 · Safe backward walking\n'
                      '1:00–1:30 · Wall tibialis raises (10–15)\n'
                      '1:30–2:00 · Wall calf raises (10–15)\n'
                      '2:00–2:30 · Shoulder circles (8 each direction)\n'
                      '2:30–3:00 · Scapular push-ups (6–10)\n'
                      'No equipment; replaces general movement prep.'
                  : '0:00–2:00 · Safe backward walking\n'
                      '2:00–2:45 · Wall tibialis raises (15–20)\n'
                      '2:45–3:30 · Wall calf raises (15–20)\n'
                      '3:30–4:15 · Shoulder circles (10 each direction)\n'
                      '4:15–5:00 · Scapular push-ups (8–12)\n'
                      'No equipment; replaces general movement prep.'
              : atgMinutes == 3
                  ? '0:00–1:00 · Backward treadmill\n'
                      '1:00–1:30 · Tibialis raises (10–15)\n'
                      '1:30–2:00 · Calf raises (10–15)\n'
                      '2:00–2:30 · Shoulder circles (8 each direction)\n'
                      '2:30–3:00 · Scapular push-ups (6–10)\n'
                      'Replaces general movement prep.'
                  : '0:00–2:00 · Backward treadmill\n'
                      '2:00–2:45 · Tibialis raises (15–20)\n'
                      '2:45–3:30 · Calf raises (15–20)\n'
                      '3:30–4:15 · Shoulder circles (10 each direction)\n'
                      '4:15–5:00 · Scapular push-ups (8–12)\n'
                      'Replaces general movement prep.';
        }
        exercises.add(PlannedExercise(
          trackKey: 'atg_block',
          pattern: MovementPattern.kneeHealth,
          name: prepName,
          sets: 1,
          metric: ExerciseMetric.minutes,
          targetRange: (atgMinutes, atgMinutes),
          rirTarget: Rir.rir3plus,
          isWarmup: true,
          instruction: prepInstruction,
          progressionEligible: false,
          isTravel: input.settings.travelMode,
        ));
      } else {
        exercises.add(_generalWarmupEntry(
          effectiveSessionId,
          slotMinutes: checkin.timeMinutes,
          travelMode: input.settings.travelMode,
          painAware: prepPainAware,
        ));
      }
      final slots = _workSlotsForSession(
        sessionId: effectiveSessionId,
        tier: tier,
        ledger: ledger,
        targets: targets,
        stimulusSetMultiplier:
            recovery.bucket == ReadinessBucket.red ? 0.0 : setMultiplier,
        travelMode: input.settings.travelMode,
      );
      for (final (pattern, usesCompoundSetCount, namedExercise) in slots) {
        final isGenuineCompound = namedExercise == null &&
            template.compoundPatterns.contains(pattern);
        final baseSets = template.setsFor(usesCompoundSetCount, tier);
        final cutSets = (baseSets * setMultiplier).floor().clamp(baseSets == 0 ? 0 : 1, baseSets);

        final trackKey = namedExercise?.trackKey ?? pattern.name;
        var state = patchedStates[trackKey] ??
            ExerciseState(trackKey: trackKey, pattern: pattern);

        // Pain flag lifecycle for this pattern.
        final persistedFlag = state.painFrozen && state.painRegion != null
            ? PainFlag(
                region: state.painRegion!,
                severity: state.painSeverity ?? PainSeverity.sharp,
                flaggedDate: state.painFlaggedDate ?? today,
                tags: state.painTags,
              )
            : null;
        final effectiveFlag = _flagFor(
          [
            ...checkin.pain,
            if (persistedFlag != null) persistedFlag,
          ],
          pattern,
          today,
        );
        state = painEngine.advanceFlagState(
          state,
          activeFlag: effectiveFlag,
          // Check-in persistence and scheduling are separate. The counter is
          // advanced only after duration fitting identifies the final work
          // slots that the plan actually emits.
          patternScheduledToday: false,
          sessionRanPainFree: false,
          today: today,
        );
        patchedStates[trackKey] = state;

        // Effective flag = today's tap OR the persisted freeze from a prior
        // day (§7.2: flags decay by rule, not by the user re-tapping the map).
        var flag = effectiveFlag;
        if (flag == null && state.painFrozen && state.painRegion != null) {
          flag = PainFlag(
            region: state.painRegion!,
            severity: state.painSeverity ?? PainSeverity.sharp,
            flaggedDate: state.painFlaggedDate ?? today,
            tags: state.painTags,
          );
        }
        final reentryPending = state.painReentryTestOffered && !state.painReentryTestPassed;

        // §7.2 escalation: persistent sharp flag / radiating symptoms — the
        // pattern stays off the plan until the flag is cleared manually.
        if (flag != null && painEngine.isEscalated(flag, today)) {
          fired.add(FiredRule(RuleKey.painFreeze, pattern: pattern.name));
          fired.add(FiredRule(
            RuleKey.painMedicalEscalation,
            pattern: pattern.name,
          ));
          continue;
        }

        PainAction action = const PainAction(PainActionKind.none);
        if (flag != null && !reentryPending) {
          action = painEngine.resolve(flag.region, flag.severity, pattern);
          if (action.kind != PainActionKind.none) {
            fired.add(FiredRule(
              flag.severity == PainSeverity.mild ? RuleKey.painSubMild : RuleKey.painSubSharp,
              pattern: pattern.name,
            ));
          }
        }
        if (state.painFrozen) {
          fired.add(FiredRule(RuleKey.painFreeze, pattern: pattern.name));
          // reentry-test rule fires via resolveTodaysPrescription below
        }

        if (action.kind == PainActionKind.removePattern) {
          continue;
        }

        String? substitutedFrom;
        ExerciseState prescriptionState;
        int exerciseSets = cutSets.toInt();
        var exerciseLoadMultiplier = loadMultiplier;
        var exerciseRir = rirFloor;
        var persistLoad = false;
        var painReentryPrescription = false;
        var capLadderJumpFired = false;
        var substituteIsNew = false;
        var suppressMicroProgressionCue = input.settings.travelMode ||
            flag != null ||
            state.painFrozen ||
            action.kind != PainActionKind.none;
        if (action.kind == PainActionKind.substituteNamed && action.substitute != null) {
          final sub = action.substitute!;
          substituteIsNew = !patchedStates.containsKey(sub.trackKey);
          final subState = patchedStates[sub.trackKey] ??
              ExerciseState(trackKey: sub.trackKey, pattern: sub.pattern);
          patchedStates[sub.trackKey] = subState;
          substitutedFrom = pattern.name;
          final resolution = progressionEngine.resolveTodaysPrescription(
            subState,
            today,
            input.settings.equipment,
          );
          prescriptionState = resolution.state;
          if (resolution.detrainFired ||
              resolution.painReentryTestFired ||
              resolution.deloadActive) {
            suppressMicroProgressionCue = true;
          }
          if (resolution.detrainFired && !input.settings.travelMode) {
            fired.add(FiredRule(
              RuleKey.detrainAdjust,
              pattern: sub.pattern.name,
            ));
            // Persist the exact emitted comeback baseline after real work,
            // even when YELLOW/RED disables normal progression. A lower
            // readiness-modulated baseline is safer than snapping back to
            // the harder pre-break state on the next plan.
            persistLoad = true;
          }
          if (resolution.deloadActive) {
            exerciseLoadMultiplier *= 0.6;
            exerciseSets = exerciseSets == 0
                ? 0
                : (exerciseSets * 0.5)
                    .floor()
                    .clamp(1, exerciseSets)
                    .toInt();
            exerciseRir = Rir.rir4plus;
            fired.add(FiredRule(
              RuleKey.deloadActive,
              pattern: sub.pattern.name,
            ));
          }
          if (substituteIsNew) {
            fired.add(const FiredRule(RuleKey.onboardSubstitute));
          }
        } else {
          final resolution = progressionEngine.resolveTodaysPrescription(state, today, input.settings.equipment);
          prescriptionState = resolution.state;
          if (resolution.detrainFired ||
              resolution.painReentryTestFired ||
              resolution.deloadActive) {
            suppressMicroProgressionCue = true;
          }
          if (resolution.detrainFired && !input.settings.travelMode) {
            fired.add(FiredRule(RuleKey.detrainAdjust, pattern: pattern.name));
            // §6.6: the emitted comeback load/step becomes the safe working
            // baseline once real canonical work occurs. Readiness can block
            // advancement without restoring the harder pre-break state.
            persistLoad = true;
          }
          if (resolution.painReentryTestFired) {
            // The graded test is a deliberately fixed light prescription
            // (1 x 8 for reps, 10 seconds for a hold), unaffected by
            // readiness volume or load multipliers.
            exerciseSets = 1;
            exerciseLoadMultiplier = 1.0;
            exerciseRir = Rir.rir4plus;
            painReentryPrescription = true;
            // A no-equipment travel variant can be used only as a light
            // pain-free movement check. It must not be represented as the
            // formal 50%-load re-entry test that resumes home progression.
            if (!input.settings.travelMode) {
              fired.add(FiredRule(RuleKey.painReentryTest, pattern: pattern.name));
            }
          }
          if (resolution.deloadActive) {
            // §6.5 deload parameters: 60% load, 50% of sets, RIR >= 4.
            exerciseLoadMultiplier *= 0.6;
            exerciseSets = exerciseSets == 0 ? 0 : (exerciseSets * 0.5).floor().clamp(1, exerciseSets).toInt();
            exerciseRir = Rir.rir4plus;
            fired.add(FiredRule(RuleKey.deloadActive, pattern: pattern.name));
          }

          capLadderJumpFired = !input.settings.travelMode &&
              state.awaitingUndershootCheck &&
              !resolution.detrainFired &&
              !resolution.painReentryTestFired &&
              !resolution.deloadActive;

          if (action.kind == PainActionKind.reduceLoadOne) {
            prescriptionState = _reduceLoadOne(prescriptionState, input.settings.equipment);
          } else if (action.kind == PainActionKind.regressLadderAndReduce) {
            prescriptionState = _regressLadderAndReduce(prescriptionState, input.settings.equipment);
          }
        }

        final prescriptionStep = progressionEngine.ladderStepFor(prescriptionState);
        final reentryTarget = painReentryPrescription
            ? prescriptionStep.metric == ExerciseMetric.seconds
                ? const (10, 10)
                : const (8, 8)
            : null;
        final painActionInstruction = switch (action.kind) {
          PainActionKind.reduceLoadOne ||
          PainActionKind.regressLadderAndReduce =>
            'Use a pain-free range and controlled reps; stop if pain worsens.',
          PainActionKind.substituteNamed => substituteIsNew
              ? 'This substitute starts deliberately light. Use a pain-free range and stop if pain worsens.'
              : 'Use a pain-free range and stop if pain worsens.',
          PainActionKind.none || PainActionKind.removePattern => null,
        };
        var planned = _buildPlannedExercise(
          prescriptionState,
          sets: exerciseSets,
          rirFloor: exerciseRir,
          loadMultiplier: exerciseLoadMultiplier,
          equipmentConfig: input.settings.equipment,
          substitutedFrom: substitutedFrom,
          progressionEligible: progressionEligible,
          isCompoundWork: isGenuineCompound,
          microProgressionCueEligible: !suppressMicroProgressionCue,
          persistLoadOnCompletion: persistLoad,
          isPainReentryTest:
              painReentryPrescription && !input.settings.travelMode,
          targetRangeOverride: reentryTarget,
          instruction: painReentryPrescription
              ? prescriptionStep.metric == ExerciseMetric.seconds
                  ? 'Pain re-entry check: one easy 10-second hold, keep at least 4 RIR and stop if pain returns'
                  : 'Pain re-entry test: 1 x 8 at 50% load, keep at least 4 RIR and stop if pain returns'
              : painActionInstruction,
        );

        // §12 travel / no-equipment mode: ladders resolve to bodyweight
        // steps. Named S5 accessories and pain substitutes use explicit
        // equipment-free equivalents while keeping their own state tracks.
        if (input.settings.travelMode) {
          final travelNamedExercise =
              action.kind == PainActionKind.substituteNamed ? action.substitute : namedExercise;
          final travel = _travelStepFor(pattern, travelNamedExercise);
          if (travel != null) {
            final painAdjusted = painReentryPrescription ||
                action.kind == PainActionKind.reduceLoadOne ||
                action.kind == PainActionKind.regressLadderAndReduce ||
                action.kind == PainActionKind.substituteNamed;
            planned = PlannedExercise(
              trackKey: planned.trackKey,
              pattern: pattern,
              name: travel.name,
              sets: planned.sets,
              metric: travel.metric,
              targetRange: painReentryPrescription
                  ? travel.metric == ExerciseMetric.seconds
                      ? const (10, 10)
                      : const (8, 8)
                  : travel.targetRange ?? const (8, 15),
              rirTarget: painAdjusted ? Rir.rir4plus : planned.rirTarget,
              substitutedFrom: planned.substitutedFrom,
              instruction: painReentryPrescription
                  ? 'Travel mode - light pain-free check only; the formal loaded re-entry remains pending'
                  : painAdjusted
                      ? 'Travel mode - use an easier variation and pain-free range; stop if pain worsens'
                      : travel.metric == ExerciseMetric.seconds
                          ? 'Travel mode - no equipment; progress with hold duration, control, or position'
                          : 'Travel mode - no equipment; progress with reps, tempo, or range of motion',
              progressionEligible: false,
              isTravel: true,
              isCompoundWork: planned.isCompoundWork,
            );
          }
        }

        // Percent-load warm-ups belong only to genuine compound slots. Named
        // accessories may share a compound pattern for pain mapping but must
        // not acquire a compound ramp. Substitutes and bodyweight/backpack
        // steps also skip percent-load warm-ups.
        if (planned.isCompoundWork &&
            planned.loadTotal != null &&
            action.kind != PainActionKind.substituteNamed) {
          final step = progressionEngine.ladderStepFor(prescriptionState);
          if (step.dumbbells > 0 && !step.backpackLoaded) {
            if (!loadedCompoundRampDone) {
              loadedCompoundRampDone = true;
              final ramp = checkin.timeMinutes <= 20
                  ? const [(0.50, 5), (0.75, 3)]
                  : const [(0.40, 8), (0.60, 5), (0.80, 3)];
              exercises.addAll(ramp
                  .map((entry) => _warmupEntry(
                        planned,
                        step,
                        entry.$1,
                        entry.$2,
                        input.settings.equipment,
                      ))
                  .whereType<PlannedExercise>());
            } else {
              final feeder = _warmupEntry(
                planned,
                step,
                0.60,
                5,
                input.settings.equipment,
                isFeederWarmup: true,
              );
              if (feeder != null) exercises.add(feeder);
            }
          }
        }
        exercises.add(planned);

        if (capLadderJumpFired && action.kind == PainActionKind.none) {
          fired.add(FiredRule(RuleKey.capLadderJump, pattern: pattern.name));
        }
      }

      if (template.hasOptionalRehitFinisher && tier == SessionTier.extended) {
        // Surfaced as an optional add-on in the UI; not a hard plan entry.
      }

      // §2.5 superset pairing: templates order compounds as antagonist pairs
      // (squat+hinge, push+pull). Pair consecutive compound WORK exercises
      // into superset groups; accessories and any odd remainder run straight.
      final compoundWork = <int>[];
      for (var i = 0; i < exercises.length; i++) {
        final e = exercises[i];
        if (!e.isWarmup && e.isCompoundWork) compoundWork.add(i);
      }
      for (var g = 0; g + 1 < compoundWork.length; g += 2) {
        exercises[compoundWork[g]] = exercises[compoundWork[g]].copyWith(supersetGroup: g ~/ 2);
        exercises[compoundWork[g + 1]] = exercises[compoundWork[g + 1]].copyWith(supersetGroup: g ~/ 2);
      }
    }

    final planSessionDef = sessionTypes[effectiveSessionId]!;
    final queueCreditType = redTechnique ? null : _queueCreditType(chosen.id, effectiveSessionId, recovery.bucket);
    if (template != null &&
        !template.isCardioOnly &&
        exercises.where((exercise) => !exercise.isWarmup).fold<int>(
              0,
              (sum, exercise) => sum + exercise.sets,
            ) ==
            0) {
      return DecisionEngineOutput(
        DecisionTrace(
          date: today,
          checkin: checkin,
          recovery: recoveryTrace,
          candidates: candidatesTrace,
          firedRules: fired,
          plan: null,
          restReason: 'No pain-free work is available for this session',
          queue: queueTraceBase,
        ),
        patchedStates,
      );
    }
    final int estimatedDuration;
    final optionalRehitFinisherReserved = template != null &&
        template.hasOptionalRehitFinisher &&
        effectiveSessionId == SessionTypeId.s2 &&
        tier == SessionTier.extended &&
        recovery.bucket == ReadinessBucket.green &&
        !recovery.illnessGuardFired &&
        !highIntensitySafety.blocked;
    if (template != null && !template.isCardioOnly) {
      final unbudgetedWork =
          exercises.where((exercise) => !exercise.isWarmup).toList();
      final optionalRehitReserve = optionalRehitFinisherReserved
          ? sessionTypes[SessionTypeId.s7]!.fullDurationMin
          : 0;
      final budgeted = strengthDurationBudgeter.fit(
        exercises: exercises,
        slotMinutes: checkin.timeMinutes - optionalRehitReserve,
      );
      if (!budgeted.fits) {
        patchedStates = {
          for (final entry in planAssemblyStateBaseline.entries)
            entry.key: entry.value.clone(),
        };
        return DecisionEngineOutput(
          DecisionTrace(
            date: today,
            checkin: checkin,
            recovery: recoveryTrace,
            candidates: candidatesTrace,
            firedRules: fired,
            plan: null,
            restReason:
                'No meaningful strength prescription fits the selected time window',
            queue: queueTraceBase,
          ),
          patchedStates,
        );
      }
      exercises
        ..clear()
        ..addAll(budgeted.exercises);
      final finalTrackKeys = exercises
          .where((exercise) => !exercise.isWarmup)
          .map((exercise) => exercise.trackKey)
          .toSet();
      final removedStateKeys = <String>{};
      for (final exercise in unbudgetedWork) {
        if (finalTrackKeys.contains(exercise.trackKey)) continue;
        removedStateKeys.add(exercise.trackKey);
        final substitutedFrom = exercise.substitutedFrom;
        if (substitutedFrom != null) removedStateKeys.add(substitutedFrom);
      }
      for (final key in removedStateKeys) {
        final baseline = planAssemblyStateBaseline[key];
        if (baseline == null) {
          patchedStates.remove(key);
        } else {
          patchedStates[key] = baseline.clone();
        }
      }
      estimatedDuration = budgeted.estimatedDurationMin;
    } else {
      // Cardio protocols own their preparation, transitions, and cooldown.
      // No generic strength warm-up is added and the protocol is capped at
      // the selected hard time window.
      estimatedDuration = planSessionDef.fullDurationMin < checkin.timeMinutes
          ? planSessionDef.fullDurationMin
          : checkin.timeMinutes;
    }
    if (template != null && !template.isCardioOnly) {
      final targetedMuscles = _targetedMusclesForFinalExercises(
        exercises,
        ledger: ledger,
        targets: targets,
      );
      if (targetedMuscles.isNotEmpty) {
        fired.add(FiredRule(
          RuleKey.muscleStimulusDeficit,
          params: {'muscles': targetedMuscles},
        ));
      }
    }
    _advanceFinalScheduledPainStates(
      patchedStates,
      exercises,
      today,
    );
    if (exercises.any((exercise) => exercise.isTravel)) {
      fired.add(const FiredRule(RuleKey.travelModeActive));
    }
    final cardioPrescription = template?.isCardioOnly == true
        ? cardioEngine.prescriptionFor(
            sessionId: effectiveSessionId,
            durationMinutes: estimatedDuration,
            heartRateMaxBpm: input.settings.hrMax,
          )
        : null;
    final plan = SessionPlan(
      sessionId: effectiveSessionId,
      sessionName: planSessionDef.name,
      tier: tier,
      exercises: exercises,
      estimatedDurationMin: estimatedDuration,
      cardioPrescription: cardioPrescription,
      grantsQueueCredit: queueCreditType != null,
      travelMode: input.settings.travelMode,
      optionalRehitFinisherReserved: optionalRehitFinisherReserved,
    );

    return DecisionEngineOutput(
      DecisionTrace(
        date: today,
        checkin: checkin,
        recovery: recoveryTrace,
        candidates: candidatesTrace,
        firedRules: fired,
        plan: plan,
        queue: QueueTraceInfo(
          pointerBefore: input.queueState.pointer,
          servedBefore: input.queueState.served,
          pointerAfterIfCompleted: queueEngine.advance(input.queueState, queueCreditType).pointer,
        ),
      ),
      patchedStates,
    );
  }

  bool _prepPainActive(
    DecisionEngineInput input,
    SessionTemplateDef template,
  ) {
    final rehearsedPatterns = <MovementPattern>{
      ...template.compoundPatterns,
      ...template.accessoryPatterns,
      ...template.namedAccessories.map((exercise) => exercise.pattern),
    };
    final currentPain = input.checkin.pain.any(
      (flag) => flag.region.affectedPatterns.any(rehearsedPatterns.contains),
    );
    final persistedPain = input.exerciseStates.values.any(
      (state) =>
          state.painFrozen &&
          (rehearsedPatterns.contains(state.pattern) ||
              (state.painRegion?.affectedPatterns
                      .any(rehearsedPatterns.contains) ??
                  false)),
    );
    return currentPain || persistedPain;
  }

  Map<String, ExerciseState> _persistCurrentCheckInPain(
    Map<String, ExerciseState> states,
    List<PainFlag> currentPain,
    DateTime today,
  ) {
    if (currentPain.isEmpty) return states;

    final normalPlanSeeds = <ExerciseState>[
      for (final pattern in ladders.keys)
        if (pattern.patternClass != PatternClass.kneeHealth)
          ExerciseState(trackKey: pattern.name, pattern: pattern),
      for (final named in s5NamedAccessories)
        ExerciseState(trackKey: named.trackKey, pattern: named.pattern),
    ];
    final result = Map<String, ExerciseState>.from(states);

    for (final seed in normalPlanSeeds) {
      // This first lookup is deliberately current-check-in-only: an old
      // freeze must not materialize unrelated tracks that were never frozen.
      final currentFlag = _flagFor(currentPain, seed.pattern, today);
      if (currentFlag == null) continue;

      final state = result[seed.trackKey] ?? seed;
      final persistedFlag = state.painFrozen && state.painRegion != null
          ? PainFlag(
              region: state.painRegion!,
              severity: state.painSeverity ?? PainSeverity.sharp,
              flaggedDate: state.painFlaggedDate ?? today,
              tags: state.painTags,
            )
          : null;
      // Preserve the same deterministic most-restrictive resolution used by
      // plan assembly when multiple regions affect one movement pattern.
      final effectiveFlag = _flagFor(
        [
          ...currentPain,
          if (persistedFlag != null) persistedFlag,
        ],
        seed.pattern,
        today,
      );
      result[seed.trackKey] = painEngine.advanceFlagState(
        state,
        activeFlag: effectiveFlag,
        patternScheduledToday: false,
        sessionRanPainFree: false,
        today: today,
      );
    }
    return result;
  }

  void _advanceFinalScheduledPainStates(
    Map<String, ExerciseState> states,
    List<PlannedExercise> exercises,
    DateTime today,
  ) {
    final scheduledKeys = <String>{};
    for (final exercise in exercises.where(
      (value) => !value.isWarmup && value.sets > 0,
    )) {
      // A named pain substitute schedules the frozen source pattern, not the
      // substitute's independent progression track. Normal S5 named work has
      // no substitutedFrom value and therefore advances its own track.
      scheduledKeys.add(exercise.substitutedFrom ?? exercise.trackKey);
    }
    for (final key in scheduledKeys) {
      final state = states[key];
      if (state == null || !state.painFrozen) continue;
      states[key] = painEngine.advanceFlagState(
        state,
        activeFlag: null,
        patternScheduledToday: true,
        sessionRanPainFree: false,
        today: today,
      );
    }
  }

  bool _activeKneePain(DecisionEngineInput input) {
    bool isKnee(BodyRegion? region) =>
        region == BodyRegion.kneeLeft || region == BodyRegion.kneeRight;
    return input.checkin.pain.any((flag) => isKnee(flag.region)) ||
        input.exerciseStates.values.any(
          (state) => state.painFrozen && isKnee(state.painRegion),
        );
  }

  LadderStep? _travelStepFor(
    MovementPattern pattern,
    SubstituteExercise? namedExercise,
  ) {
    if (namedExercise != null) return travelNamedSteps[namedExercise.trackKey];
    return travelSteps[pattern];
  }

  /// Only a same-type completion grants queue credit; RED/YELLOW swaps
  /// (incl. the RED technique session, handled by the caller) and the
  /// S3->S7 time substitution never do (§2.1, §5 Step 6).
  SessionTypeId? _queueCreditType(SessionTypeId chosenId, SessionTypeId effectiveId, ReadinessBucket bucket) {
    if (chosenId != effectiveId) return null;
    if (!cycleOrder.contains(chosenId)) return null;
    return chosenId;
  }

  List<SessionTypeId> _feasibleCandidates(int time) {
    if (time == 20) {
      // S3 remains conceptual so a due anchor can route to the separate-day
      // REHIT fallback. All four strength families have a real compressed
      // pair, preventing the old 20-minute S1/S5 pattern starvation.
      return [
        SessionTypeId.s1,
        SessionTypeId.s2,
        SessionTypeId.s3,
        SessionTypeId.s4,
        SessionTypeId.s5,
        SessionTypeId.s6,
        SessionTypeId.s7,
      ];
    }
    final list = <SessionTypeId>[];
    for (final t in sessionTypes.values) {
      if (t.id == SessionTypeId.s3) {
        // The bike preset itself is 30 minutes, but the immutable personal
        // availability gate remains the 35-minute check-in window.
        if (time >= _fourByFourAvailabilityWindowMin) list.add(t.id);
        continue;
      }
      if (t.minDurationMin != null && time >= t.minDurationMin!) list.add(t.id);
    }
    return list;
  }

  /// Returns exactly the work slots that normal plan assembly will consider
  /// for a strength session, including 60 -> 35 accessory removal, dynamic
  /// compressed-pair selection, and travel-equipment filtering. Keeping this
  /// shared with the pain-feasibility gate prevents selection from approving
  /// a template that assembly would later reduce to zero work.
  List<_TemplateSlot> _workSlotsForSession({
    required SessionTypeId sessionId,
    required SessionTier tier,
    required StimulusLedgerSnapshot ledger,
    required TrainingTargets targets,
    required double stimulusSetMultiplier,
    required bool travelMode,
  }) {
    final template = sessionTemplates[sessionId]!;
    final compress60to35 = tier == SessionTier.full &&
        sessionTypes[sessionId]!.fullDurationMin >= 60;
    final slots = _slotsForPlan(
      sessionId: sessionId,
      tier: tier,
      ledger: ledger,
      targets: targets,
      stimulusSetMultiplier: stimulusSetMultiplier,
      dropAccessories: compress60to35,
    );
    if (!travelMode) return slots;

    final travelViable = slots
        .where((slot) => _travelStepFor(slot.$1, slot.$3) != null)
        .toList();
    if (travelViable.isNotEmpty) return travelViable;

    final fallback = [
      for (final pattern in template.compoundPatterns)
        (pattern, true, null as SubstituteExercise?),
      for (final pattern in template.accessoryPatterns)
        (pattern, false, null as SubstituteExercise?),
    ].where((slot) => _travelStepFor(slot.$1, slot.$3) != null).toList();
    return tier == SessionTier.compressed
        ? fallback.take(2).map((slot) => (slot.$1, true, slot.$3)).toList()
        : fallback;
  }

  bool _hasPainSafeStrengthWork(
    _Scored candidate, {
    required DecisionEngineInput input,
    required Map<String, ExerciseState> states,
    required StimulusLedgerSnapshot ledger,
    required TrainingTargets targets,
    required double slotStimulusMultiplier,
  }) {
    final template = sessionTemplates[candidate.id]!;
    if (template.isCardioOnly ||
        !candidate.def.countsAs.contains(FloorCategory.strength)) {
      return false;
    }

    final slots = _workSlotsForSession(
      sessionId: candidate.id,
      tier: candidate.tier,
      ledger: ledger,
      targets: targets,
      stimulusSetMultiplier: slotStimulusMultiplier,
      travelMode: input.settings.travelMode,
    );
    return _painAdjustedStrengthProjection(
      slots,
      template: template,
      tier: candidate.tier,
      input: input,
      states: states,
    ).hasPainSafeWork;
  }

  _PainAdjustedStrengthProjection _painAdjustedStrengthProjection(
    List<_TemplateSlot> slots, {
    required SessionTemplateDef template,
    required SessionTier tier,
    required DecisionEngineInput input,
    required Map<String, ExerciseState> states,
  }) {
    var hasPainSafeWork = false;
    final stimulusSlots = <_TemplateSlot>[];
    for (final slot in slots) {
      if (template.setsFor(slot.$2, tier) <= 0) continue;
      final resolution = _resolvePainAdjustedSlot(
        slot,
        input: input,
        states: states,
      );
      if (!resolution.hasWork) continue;
      hasPainSafeWork = true;
      final stimulusSlot = resolution.stimulusSlot;
      if (stimulusSlot != null) stimulusSlots.add(stimulusSlot);
    }
    return _PainAdjustedStrengthProjection(
      hasPainSafeWork: hasPainSafeWork,
      stimulusSlots: stimulusSlots,
    );
  }

  _PainAdjustedSlotResolution _resolvePainAdjustedSlot(
    _TemplateSlot slot, {
    required DecisionEngineInput input,
    required Map<String, ExerciseState> states,
  }) {
    final (pattern, usesCompoundSetCount, namedExercise) = slot;
    final trackKey = namedExercise?.trackKey ?? pattern.name;
    final state = states[trackKey] ??
        ExerciseState(trackKey: trackKey, pattern: pattern);
    final persistedFlag = state.painFrozen && state.painRegion != null
        ? PainFlag(
            region: state.painRegion!,
            severity: state.painSeverity ?? PainSeverity.sharp,
            flaggedDate: state.painFlaggedDate ?? input.today,
            tags: state.painTags,
          )
        : null;
    var flag = _flagFor(
      [
        ...input.checkin.pain,
        if (persistedFlag != null) persistedFlag,
      ],
      pattern,
      input.today,
    );
    if (flag == null && state.painFrozen && state.painRegion != null) {
      flag = persistedFlag;
    }
    if (flag != null && painEngine.isEscalated(flag, input.today)) {
      return const _PainAdjustedSlotResolution(hasWork: false);
    }

    final reentryPending = state.painReentryTestOffered &&
        !state.painReentryTestPassed;
    final action = flag == null || reentryPending
        ? const PainAction(PainActionKind.none)
        : painEngine.resolve(flag.region, flag.severity, pattern);
    if (action.kind == PainActionKind.removePattern) {
      return const _PainAdjustedSlotResolution(hasWork: false);
    }

    final projectedNamedExercise =
        action.kind == PainActionKind.substituteNamed
            ? action.substitute
            : namedExercise;
    final projectedPattern = projectedNamedExercise?.pattern ?? pattern;
    if (input.settings.travelMode &&
        _travelStepFor(pattern, projectedNamedExercise) == null) {
      return const _PainAdjustedSlotResolution(hasWork: false);
    }

    final prescriptionTrackKey =
        projectedNamedExercise?.trackKey ?? trackKey;
    final prescriptionState = states[prescriptionTrackKey] ??
        ExerciseState(
          trackKey: prescriptionTrackKey,
          pattern: projectedPattern,
        );
    final prescription = progressionEngine.resolveTodaysPrescription(
      prescriptionState,
      input.today,
      input.settings.equipment,
    );
    final nonqualifyingPrescription = prescription.deloadActive ||
        prescription.painReentryTestFired ||
        reentryPending;
    return _PainAdjustedSlotResolution(
      hasWork: true,
      stimulusSlot: nonqualifyingPrescription
          ? null
          : (
              projectedPattern,
              usesCompoundSetCount,
              projectedNamedExercise,
            ),
    );
  }

  AerobicTrainingStatus _aerobicStatus(
    TrainingStatus status,
    AerobicTargetKind target,
  ) =>
      status.aerobic.firstWhere((value) => value.target == target);

  List<_TemplateSlot> _slotsForPlan({
    required SessionTypeId sessionId,
    required SessionTier tier,
    required StimulusLedgerSnapshot ledger,
    required TrainingTargets targets,
    double stimulusSetMultiplier = 1.0,
    bool dropAccessories = false,
  }) {
    final template = sessionTemplates[sessionId]!;
    if (template.isCardioOnly) return const [];
    if (tier != SessionTier.compressed) {
      return template.slotsForTier(
        tier,
        dropAccessories: dropAccessories,
      );
    }

    List<_TemplateSlot> pair(List<MovementPattern> patterns) => [
          for (final pattern in patterns)
            (pattern, true, null as SubstituteExercise?),
        ];

    switch (sessionId) {
      case SessionTypeId.s1:
        return pair(const [MovementPattern.squat, MovementPattern.hinge]);
      case SessionTypeId.s2:
        return _higherNeedPair(
          [
            pair(const [
              MovementPattern.pushHorizontal,
              MovementPattern.pullHorizontal,
            ]),
            pair(const [
              MovementPattern.pushVertical,
              MovementPattern.pullVertical,
            ]),
          ],
          template: template,
          tier: tier,
          ledger: ledger,
          targets: targets,
          stimulusSetMultiplier: stimulusSetMultiplier,
        );
      case SessionTypeId.s4:
        return _higherNeedPair(
          [
            pair(const [MovementPattern.squat, MovementPattern.hinge]),
            pair(const [
              MovementPattern.pushHorizontal,
              MovementPattern.pullHorizontal,
            ]),
          ],
          template: template,
          tier: tier,
          ledger: ledger,
          targets: targets,
          stimulusSetMultiplier: stimulusSetMultiplier,
        );
      case SessionTypeId.s5:
        final candidates = <_TemplateSlot>[
          for (final named in template.namedAccessories)
            (named.pattern, true, named),
          for (final pattern in template.accessoryPatterns)
            (pattern, true, null),
        ];
        final ranked = <({int index, _TemplateSlot slot, int score})>[
          for (var index = 0; index < candidates.length; index++)
            (
              index: index,
              slot: candidates[index],
              score: _slotNeedScore(
                candidates[index],
                template: template,
                tier: tier,
                ledger: ledger,
                targets: targets,
                stimulusSetMultiplier: stimulusSetMultiplier,
              ),
            ),
        ]
          ..sort((a, b) {
            final byScore = b.score.compareTo(a.score);
            return byScore != 0 ? byScore : a.index.compareTo(b.index);
          });
        return ranked.take(2).map((value) => value.slot).toList();
      case SessionTypeId.s3:
      case SessionTypeId.s6:
      case SessionTypeId.s7:
        return const [];
    }
  }

  List<_TemplateSlot> _higherNeedPair(
    List<List<_TemplateSlot>> pairs, {
    required SessionTemplateDef template,
    required SessionTier tier,
    required StimulusLedgerSnapshot ledger,
    required TrainingTargets targets,
    required double stimulusSetMultiplier,
  }) {
    var bestIndex = 0;
    var bestScore = _strengthScoreTerms(
      slots: pairs.first,
      template: template,
      tier: tier,
      ledger: ledger,
      targets: targets,
      stimulusSetMultiplier: stimulusSetMultiplier,
    ).values.fold(0, (sum, value) => sum + value);
    for (var index = 1; index < pairs.length; index++) {
      final score = _strengthScoreTerms(
        slots: pairs[index],
        template: template,
        tier: tier,
        ledger: ledger,
        targets: targets,
        stimulusSetMultiplier: stimulusSetMultiplier,
      ).values.fold(0, (sum, value) => sum + value);
      if (score > bestScore) {
        bestIndex = index;
        bestScore = score;
      }
    }
    return pairs[bestIndex];
  }

  int _slotNeedScore(
    _TemplateSlot slot, {
    required SessionTemplateDef template,
    required SessionTier tier,
    required StimulusLedgerSnapshot ledger,
    required TrainingTargets targets,
    required double stimulusSetMultiplier,
  }) =>
      _strengthScoreTerms(
        slots: [slot],
        template: template,
        tier: tier,
        ledger: ledger,
        targets: targets,
        stimulusSetMultiplier: stimulusSetMultiplier,
      ).values.fold(0, (sum, value) => sum + value);

  Map<String, int> _strengthScoreTerms({
    required List<_TemplateSlot> slots,
    required SessionTemplateDef template,
    required SessionTier tier,
    required StimulusLedgerSnapshot ledger,
    required TrainingTargets targets,
    required double stimulusSetMultiplier,
  }) {
    final projection = _projectedMuscleCredit(
      slots,
      template: template,
      tier: tier,
      setMultiplier: stimulusSetMultiplier,
    );
    double weekly = 0;
    double minimum28d = 0;
    double center28d = 0;
    double overMax = 0;
    double recovery = 0;

    for (final entry in projection.entries) {
      final observed = ledger.muscle(entry.key);
      final band = targets.hypertrophyTargetBands[entry.key]!;
      final projected = entry.value;
      final weeklyDeficit = (band.minimum - observed.effectiveSets7d)
          .clamp(0, double.infinity)
          .toDouble();
      final minimumDeficit28d = (band.minimumForWindow(28) -
              observed.effectiveSets28d)
          .clamp(0, double.infinity)
          .toDouble();
      final centerDeficit28d = (band.centerForWindow(28) -
              observed.effectiveSets28d)
          .clamp(0, double.infinity)
          .toDouble();

      weekly += projected < weeklyDeficit ? projected : weeklyDeficit;
      minimum28d +=
          projected < minimumDeficit28d ? projected : minimumDeficit28d;
      center28d +=
          projected < centerDeficit28d ? projected : centerDeficit28d;

      final projectedOverWeeklyMaximum =
          (observed.effectiveSets7d + projected - band.maximum)
              .clamp(0, projected)
              .toDouble();
      final projectedOver28DayMaximum =
          (observed.effectiveSets28d + projected -
                  band.maximumForWindow(28))
          .clamp(0, projected)
          .toDouble();
      // The same projected set can cross both rolling maxima. Penalize the
      // larger crossing only, so one set is never counted twice.
      overMax += projectedOverWeeklyMaximum > projectedOver28DayMaximum
          ? projectedOverWeeklyMaximum
          : projectedOver28DayMaximum;
      if (observed.daysSinceLastStimulus == 0) {
        recovery += projected * 2;
      } else if (observed.daysSinceLastStimulus == 1) {
        recovery += projected;
      }
    }

    final terms = <String, int>{};
    if (weekly > 0) {
      terms['muscleWeeklyDeficit'] = (weekly * 120).round();
    }
    if (minimum28d > 0) {
      terms['muscle28dMinimumDeficit'] = (minimum28d * 50).round();
    }
    if (center28d > 0) {
      terms['muscle28dCenterDeficit'] = (center28d * 15).round();
    }
    if (overMax > 0) {
      terms['muscleOverMaxDemotion'] = -(overMax * 180).round();
    }
    if (recovery > 0) {
      terms['muscleRecoveryDemotion'] = -(recovery * 90).round();
    }
    return terms;
  }

  Map<MajorMuscleGroup, double> _projectedMuscleCredit(
    List<_TemplateSlot> slots, {
    required SessionTemplateDef template,
    required SessionTier tier,
    required double setMultiplier,
  }) {
    final result = <MajorMuscleGroup, double>{};
    for (final (pattern, isCompound, named) in slots) {
      final perSet = exerciseMuscleMap.contributionForExercise(
        trackKey: named?.trackKey ?? pattern.name,
        pattern: pattern,
        exerciseName: named?.name,
      );
      final baseSets = template.setsFor(isCompound, tier);
      final sets = setMultiplier <= 0 || baseSets == 0
          ? 0
          : (baseSets * setMultiplier)
              .floor()
              .clamp(1, baseSets)
              .toInt();
      for (final contribution in perSet.entries) {
        result.update(
          contribution.key,
          (value) => value + contribution.value * sets,
          ifAbsent: () => contribution.value * sets,
        );
      }
    }
    return result;
  }

  String _targetedMusclesForFinalExercises(
    List<PlannedExercise> exercises, {
    required StimulusLedgerSnapshot ledger,
    required TrainingTargets targets,
  }) {
    final projection = <MajorMuscleGroup, double>{};
    for (final exercise in exercises.where(
      (value) =>
          !value.isWarmup &&
          value.sets > 0 &&
          value.rirTarget != Rir.rir4plus,
    )) {
      final perSet = exerciseMuscleMap.contributionForExercise(
        trackKey: exercise.trackKey,
        pattern: exercise.pattern,
        exerciseName: exercise.name,
      );
      for (final contribution in perSet.entries) {
        projection.update(
          contribution.key,
          (value) => value + contribution.value * exercise.sets,
          ifAbsent: () => contribution.value * exercise.sets,
        );
      }
    }
    final targeted = <String>[];
    for (final muscle in MajorMuscleGroup.values) {
      if ((projection[muscle] ?? 0) <= 0) continue;
      final observed = ledger.muscle(muscle);
      final band = targets.hypertrophyTargetBands[muscle]!;
      if (observed.effectiveSets7d < band.minimum ||
          observed.effectiveSets28d < band.centerForWindow(28)) {
        targeted.add(muscle.name);
      }
    }
    return targeted.join(', ');
  }

  PainFlag? _flagFor(List<PainFlag> pain, MovementPattern pattern, DateTime today) {
    final applicable = pain
        .where((flag) => flag.region.affectedPatterns.contains(pattern))
        .toList();
    if (applicable.isEmpty) return null;
    applicable.sort((a, b) {
      final byRestriction =
          _painRestrictionRank(b, pattern, today).compareTo(_painRestrictionRank(a, pattern, today));
      if (byRestriction != 0) return byRestriction;
      final byRegion = a.region.index.compareTo(b.region.index);
      if (byRegion != 0) return byRegion;
      final byDate = a.flaggedDate.compareTo(b.flaggedDate);
      if (byDate != 0) return byDate;
      return a.severity.index.compareTo(b.severity.index);
    });
    return applicable.first;
  }

  int _painRestrictionRank(
    PainFlag flag,
    MovementPattern pattern,
    DateTime today,
  ) {
    if (painEngine.isEscalated(flag, today)) return 100;
    final action = painEngine.resolve(flag.region, flag.severity, pattern);
    final actionRank = switch (action.kind) {
      PainActionKind.removePattern => 4,
      PainActionKind.substituteNamed => 3,
      PainActionKind.regressLadderAndReduce => 2,
      PainActionKind.reduceLoadOne => 1,
      PainActionKind.none => 0,
    };
    return actionRank * 10 + (flag.severity == PainSeverity.sharp ? 1 : 0);
  }

  ExerciseState _reduceLoadOne(ExerciseState state, EquipmentConfig cfg) {
    // Named S5 accessories and pain substitutes have their own equipment
    // shape in the registry. Resolving through ProgressionEngine prevents a
    // curl from being treated as the core/grip Plank step and prevents
    // single-DB raises/extensions from using a two-DB press increment.
    final step = progressionEngine.ladderStepFor(state);
    if (step.dumbbells == 0 || step.backpackLoaded) return state;
    final achievable = step.dumbbells == 1
        ? equipmentEngine.singleDbAchievableTotals(cfg)
        : equipmentEngine.twoDbAchievableTotals(cfg, allowUneven: !step.unilateral);
    final next = state.clone();
    next.currentLoad = equipmentEngine.nextAchievableBelow(state.currentLoad, achievable);
    return next;
  }

  ExerciseState _regressLadderAndReduce(ExerciseState state, EquipmentConfig cfg) {
    if (substituteRegistry.containsKey(state.trackKey)) {
      // A named exercise has no backing movement ladder to regress. Its pain
      // adjustment is exactly one achievable step on that exercise's real
      // single-/double-dumbbell load dimension.
      return _reduceLoadOne(state, cfg);
    }
    final next = state.clone();
    if (next.ladderStepIndex > 0) next.ladderStepIndex -= 1;
    return _reduceLoadOne(next, cfg);
  }

  /// One §2.5 warm-up entry at [pct] of the work load, rounded down to the
  /// exercise's achievable set. Returns null when rounding lands at or above
  /// the work load itself (very light prescriptions need no warm-up).
  PlannedExercise? _warmupEntry(
    PlannedExercise work,
    LadderStep step,
    double pct,
    int reps,
    EquipmentConfig cfg, {
    bool isFeederWarmup = false,
  }) {
    final achievable = step.dumbbells == 1
        ? equipmentEngine.singleDbAchievableTotals(cfg)
        : equipmentEngine.twoDbAchievableTotals(cfg, allowUneven: !step.unilateral);
    final load = equipmentEngine.roundDownToAchievable(work.loadTotal! * pct, achievable);
    if (load >= work.loadTotal!) return null;
    final resolved = step.dumbbells == 1
        ? equipmentEngine.resolveSingleDb(load, cfg)
        : equipmentEngine.resolveTwoDb(load, cfg, allowUneven: !step.unilateral);
    return PlannedExercise(
      trackKey: work.trackKey,
      pattern: work.pattern,
      name: '${work.name} - warm-up ${(pct * 100).round()}%',
      sets: 1,
      targetRange: (reps, reps),
      metric: ExerciseMetric.reps,
      loadTotal: load,
      loadDisplay: equipmentEngine.describeLoad(resolved, cfg),
      loadSteps: achievable,
      dumbbellCount: work.dumbbellCount,
      allowsUnevenPair: work.allowsUnevenPair,
      rirTarget: Rir.rir3plus,
      isWarmup: true,
      instruction: 'Rest <= 45 s',
      progressionEligible: false,
      isFeederWarmup: isFeederWarmup,
    );
  }

  PlannedExercise _generalWarmupEntry(
    SessionTypeId id, {
    required int slotMinutes,
    required bool travelMode,
    required bool painAware,
  }) {
    final prepMinutes = StrengthPrepPolicy.generalMinutes(slotMinutes);
    final instruction = painAware
        ? switch (id) {
            SessionTypeId.s1 =>
              'Use easy pain-free movement and breathing/bracing only. Skip every flagged or pain-provoking squat, hinge, or lower-body rehearsal.',
            SessionTypeId.s2 || SessionTypeId.s5 =>
              'Use easy pain-free movement, breathing/bracing, and non-reproducing scapular motion only. Skip every flagged or pain-provoking upper-body movement.',
            _ =>
              'Use easy pain-free movement, breathing/bracing, and non-reproducing rehearsal only. Skip every flagged or pain-provoking movement.',
          }
        : switch (id) {
            SessionTypeId.s1 =>
              'Start with easy walking or marching, then controlled hip hinges, squats, and ankle movement',
            SessionTypeId.s2 =>
              'Start with easy movement, then shoulder circles, scapular push-ups, and light reach-and-pulls',
            SessionTypeId.s5 =>
              'Start with easy movement, then shoulder, elbow, wrist, and trunk preparation',
            _ =>
              'Start easy, then rehearse today\'s movement patterns through a comfortable range',
          };
    return PlannedExercise(
      trackKey: 'warmup:${id.name}',
      pattern: MovementPattern.kneeHealth,
      name: 'General warm-up & movement prep',
      sets: 1,
      metric: ExerciseMetric.minutes,
      targetRange: (prepMinutes, prepMinutes),
      rirTarget: Rir.rir4plus,
      isWarmup: true,
      instruction: travelMode ? '$instruction. No equipment needed.' : instruction,
      progressionEligible: false,
      isTravel: travelMode,
    );
  }

  PlannedExercise _buildPlannedExercise(
    ExerciseState state, {
    required int sets,
    required Rir rirFloor,
    required double loadMultiplier,
    required EquipmentConfig equipmentConfig,
    String? substitutedFrom,
    required bool progressionEligible,
    required bool isCompoundWork,
    required bool microProgressionCueEligible,
    bool persistLoadOnCompletion = false,
    bool isPainReentryTest = false,
    (int, int)? targetRangeOverride,
    String? instruction,
  }) {
    final substitute = substituteRegistry[state.trackKey];
    final step = substitute != null
        ? LadderStep(name: substitute.name, dumbbells: substitute.dumbbells)
        : ladders[state.pattern]!.steps[state.ladderStepIndex.clamp(0, ladders[state.pattern]!.steps.length - 1)];
    final metric = step.metric;
    final targetRange = targetRangeOverride ??
        step.targetRange ??
        (state.trackKey.startsWith('sub:') ? (8, 15) : state.pattern.repRange);

    double? loadTotal;
    String? loadDisplay;
    List<double>? loadSteps;
    int? dumbbellCount;
    bool? allowsUnevenPair;
    if (!step.backpackLoaded && step.dumbbells > 0) {
      dumbbellCount = step.dumbbells;
      allowsUnevenPair = step.dumbbells == 2 && !step.unilateral;
      loadTotal = state.currentLoad * loadMultiplier;
      final achievable = step.dumbbells == 1
          ? equipmentEngine.singleDbAchievableTotals(equipmentConfig)
          : equipmentEngine.twoDbAchievableTotals(equipmentConfig, allowUneven: !step.unilateral);
      loadSteps = achievable;
      loadTotal = equipmentEngine.roundDownToAchievable(loadTotal, achievable);
      final resolved = step.dumbbells == 1
          ? equipmentEngine.resolveSingleDb(loadTotal, equipmentConfig)
          : equipmentEngine.resolveTwoDb(loadTotal, equipmentConfig, allowUneven: !step.unilateral);
      loadDisplay = equipmentEngine.describeLoad(resolved, equipmentConfig);
    } else if (step.backpackLoaded) {
      loadTotal = state.currentLoad * loadMultiplier;
      loadDisplay = 'backpack/DB @ ${loadTotal.toStringAsFixed(0)} lb';
    }

    return PlannedExercise(
      trackKey: state.trackKey,
      pattern: state.pattern,
      name: step.name,
      sets: sets,
      metric: metric,
      targetRange: targetRange,
      loadTotal: loadTotal,
      loadDisplay: loadDisplay,
      loadSteps: loadSteps,
      dumbbellCount: dumbbellCount,
      allowsUnevenPair: allowsUnevenPair,
      rirTarget: rirFloor,
      substitutedFrom: substitutedFrom,
      instruction: instruction ??
          _microProgressionInstruction(
            state,
            metric,
            enabled:
                progressionEligible && microProgressionCueEligible,
          ),
      persistLoadOnCompletion: persistLoadOnCompletion,
      progressionEligible: progressionEligible,
      isCompoundWork: isCompoundWork,
      isPainReentryTest: isPainReentryTest,
    );
  }

  String? _microProgressionInstruction(
    ExerciseState state,
    ExerciseMetric metric, {
    required bool enabled,
  }) {
    if (!enabled ||
        state.painFrozen ||
        state.status == ExerciseStatus.deload ||
        state.microStepStage < 1 ||
        state.microStepStage > 3) {
      return null;
    }

    if (metric == ExerciseMetric.seconds) {
      return switch (state.microStepStage) {
        1 =>
          'Micro-progression - controlled transition: enter and leave the hold slowly, then keep a strict position',
        2 =>
          'Micro-progression - strict hold: use a more exact, motionless position with no momentum or drift',
        3 =>
          'Micro-progression - harder leverage: use a longer lever, deeper position, or the next harder hold while staying controlled',
        _ => null,
      };
    }

    if (metric == ExerciseMetric.reps) {
      return switch (state.microStepStage) {
        1 =>
          'Micro-progression - tempo: use a slow 3-second eccentric on every rep',
        2 =>
          'Micro-progression - pause: hold a controlled 1-second pause at the hardest safe point of every rep',
        3 =>
          'Micro-progression - range/leverage: add a small pain-free deficit or range of motion; otherwise use slightly harder leverage',
        _ => null,
      };
    }

    return null;
  }

  int _redDaysInRollingWindow(
    DecisionEngineInput input,
    ReadinessBucket? endingDayBucket,
    DateTime endingDay,
  ) {
    var redDays = endingDayBucket == ReadinessBucket.red ? 1 : 0;
    for (var offset = 1; offset < 7; offset++) {
      final date = endingDay.subtract(Duration(days: offset));
      if (_bucketForDate(input, date) == ReadinessBucket.red) redDays += 1;
    }
    return redDays;
  }

  ReadinessBucket? _bucketForDate(DecisionEngineInput input, DateTime date) {
    final checkin = input.checkinHistory.where((c) => _isSameDate(c.date, date)).toList();
    if (checkin.isEmpty) return null;
    final snapshot = input.recoveryHistory.where((s) => _isSameDate(s.date, date)).toList();
    return readinessEngine
        .compute(
          subjective: checkin.first.subjective,
          today: snapshot.isEmpty ? null : snapshot.first,
          history: input.recoveryHistory,
          asOf: date,
        )
        .bucket;
  }

  bool _isSameDate(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}

typedef _TemplateSlot = (
  MovementPattern,
  bool,
  SubstituteExercise?,
);

class _PainAdjustedStrengthProjection {
  final bool hasPainSafeWork;
  final List<_TemplateSlot> stimulusSlots;

  _PainAdjustedStrengthProjection({
    required this.hasPainSafeWork,
    required List<_TemplateSlot> stimulusSlots,
  }) : stimulusSlots = List<_TemplateSlot>.unmodifiable(stimulusSlots);
}

class _PainAdjustedSlotResolution {
  final bool hasWork;
  final _TemplateSlot? stimulusSlot;

  const _PainAdjustedSlotResolution({
    required this.hasWork,
    this.stimulusSlot,
  });
}

class _Scored {
  final SessionTypeId id;
  final SessionTier tier;
  int score;
  final Map<String, int> terms;
  final SessionTypeDef def;

  _Scored(this.id, this.tier, this.score, this.terms, this.def);
}
