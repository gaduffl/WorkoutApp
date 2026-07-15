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
import '../models/user_settings.dart';
import 'equipment_engine.dart';
import 'floor_engine.dart';
import 'pain_engine.dart';
import 'progression_engine.dart';
import 'queue_engine.dart';
import 'readiness_engine.dart';
import 'session_templates.dart';

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

  /// §11's "swap session": when set, Step 5 picks this candidate instead
  /// of the natural highest scorer (it must still be one of the ranked
  /// candidates - the caller offers only real alternatives). Every other
  /// step (readiness modulation, time compression, pain substitution,
  /// load resolution) still runs normally against it.
  final SessionTypeId? forcedSessionId;

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
    this.forcedSessionId,
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

  static const readinessEngine = ReadinessEngine();
  static const floorEngine = FloorEngine();
  static const queueEngine = QueueEngine();
  static const painEngine = PainEngine();
  static const progressionEngine = ProgressionEngine();
  static const equipmentEngine = EquipmentEngine();

  DecisionEngineOutput decide(DecisionEngineInput input) {
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

    // §6.3 automatic global deload: the current readiness day participates
    // in the rolling seven-day window. Apply this before any rest short
    // circuit so a third RED day still persists the deload state even when it
    // is also the second consecutive RED day.
    final automaticGlobalDeload =
        _redDaysInRollingWindow(input, recovery.bucket, today) >= 3;
    if (automaticGlobalDeload) {
      patchedStates = {
        for (final state in progressionEngine.forceGlobalDeload(patchedStates.values.toList()))
          state.trackKey: state,
      };
    }

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

    final yesterday = today.subtract(const Duration(days: 1));
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

    // --- Step 2: candidate filtering by time ---
    final feasible = _feasibleCandidates(checkin.timeMinutes);

    // --- Step 3: weekly-floor pressure ---
    final strengthReq = input.settings.weeklyFloor[FloorCategory.strength] ?? 2;
    final intensityReq = input.settings.weeklyFloor[FloorCategory.intensity] ?? 1;
    final strengthPressure = floorEngine.pressureFor(
      category: FloorCategory.strength,
      logs: input.sessionLogs,
      requirement: strengthReq,
      today: today,
    );
    final intensityPressure = floorEngine.pressureFor(
      category: FloorCategory.intensity,
      logs: input.sessionLogs,
      requirement: intensityReq,
      today: today,
    );
    final bothHardForced =
        strengthPressure.level == FloorPressureLevel.hard && intensityPressure.level == FloorPressureLevel.hard;
    if (bothHardForced) fired.add(const FiredRule(RuleKey.s7SecondSessionOffer));

    // --- Step 4: candidate scoring ---
    final yesterdayLegHeavy = input.sessionLogs.any((l) =>
        _isSameDate(l.date, yesterday) && l.countsTowardQueueAndFloor && sessionTypes[l.templateId]!.legHeavy);
    final s6ConditionMet = _s6ConditionMet(input, today, strengthPressure, intensityPressure);
    final mostOverdue = _mostOverduePattern(input.exerciseStates, today);

    final scored = <_Scored>[];
    for (final id in feasible) {
      final def = sessionTypes[id]!;
      final tier = id == SessionTypeId.s3 ? SessionTier.full : tierForTime(checkin.timeMinutes);
      final terms = <String, int>{};

      int base;
      if (cycleOrder.contains(id)) {
        final dist = queueEngine.cycleDistance(id, input.queueState);
        base = 50 - 10 * dist;
      } else if (id == SessionTypeId.s6) {
        base = 10;
        if (s6ConditionMet) terms['weekendPriority'] = 50;
      } else {
        base = 10; // S7
      }
      terms['base'] = base;

      if (def.countsAs.contains(FloorCategory.strength)) {
        if (bothHardForced) {
          terms['floorForceStrength'] = 100;
        } else if (strengthPressure.level == FloorPressureLevel.hard) {
          terms['floorForceStrength'] = 100;
        } else if (strengthPressure.level == FloorPressureLevel.soft) {
          terms['floorSoftBoost'] = 10;
        }
      }
      if (def.countsAs.contains(FloorCategory.intensity) && !bothHardForced) {
        if (intensityPressure.level == FloorPressureLevel.hard) {
          terms['floorForceIntensity'] = 100;
        } else if (intensityPressure.level == FloorPressureLevel.soft) {
          terms['floorSoftBoost'] = 10;
        }
      }

      if (def.legHeavy && yesterdayLegHeavy) {
        terms['legHeavyDemoted'] = -30;
      }

      if (mostOverdue != null && sessionTemplates[id] != null) {
        final tmpl = sessionTemplates[id]!;
        if (tmpl.compoundPatterns.contains(mostOverdue) || tmpl.accessoryPatterns.contains(mostOverdue)) {
          terms['recencyBoostCandidate'] = 0; // marked; +15 applied to the single best one below
        }
      }

      final score = terms.values.fold(0, (a, b) => a + b);
      scored.add(_Scored(id, tier, score, terms, def));
    }

    // Apply the single +15 recency boost to the best-priority eligible candidate.
    if (mostOverdue != null) {
      final eligible = scored.where((s) => s.terms.containsKey('recencyBoostCandidate')).toList();
      if (eligible.isNotEmpty) {
        eligible.sort((a, b) {
          final byScore = b.score.compareTo(a.score);
          if (byScore != 0) return byScore;
          return cycleOrder.contains(a.id) && cycleOrder.contains(b.id)
              ? queueEngine.cycleDistance(a.id, input.queueState).compareTo(queueEngine.cycleDistance(b.id, input.queueState))
              : 0;
        });
        final winner = eligible.first;
        winner.terms.remove('recencyBoostCandidate');
        winner.terms['recencyBoost'] = 15;
        winner.score += 15;
      }
      for (final s in scored) {
        s.terms.remove('recencyBoostCandidate');
      }
    }

    // --- Step 5: selection ---
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final aCycle = cycleOrder.contains(a.id);
      final bCycle = cycleOrder.contains(b.id);
      if (aCycle && bCycle) return cycleOrder.indexOf(a.id).compareTo(cycleOrder.indexOf(b.id));
      if (aCycle != bCycle) return aCycle ? -1 : 1; // cycle members before S6/S7
      if (a.id == SessionTypeId.s7 && b.id == SessionTypeId.s6) return -1;
      if (a.id == SessionTypeId.s6 && b.id == SessionTypeId.s7) return 1;
      return 0;
    });

    final candidatesTrace = scored
        .map((s) => ScoredCandidate(sessionId: s.id, tier: s.tier, score: s.score, scoreTerms: s.terms))
        .toList();

    var winner = input.forcedSessionId == null
        ? scored.first
        : scored.firstWhere((s) => s.id == input.forcedSessionId, orElse: () => scored.first);
    var volumeCutForLegHeavyEscape = false;
    if (winner.def.legHeavy && yesterdayLegHeavy) {
      final allFeasibleLegHeavy = scored.every((s) => s.def.legHeavy);
      if (allFeasibleLegHeavy) {
        volumeCutForLegHeavyEscape = true;
        fired.add(const FiredRule(RuleKey.legheavyBacktobackVolumecut));
      } else {
        fired.add(const FiredRule(RuleKey.legheavyDemoted));
      }
    }

    // §7.1: sharp hip pain forces a swap away from a leg-heavy winner,
    // including a manually forced leg-heavy alternative.
    var chosen = winner;
    if (painEngine.hipSharpActive(checkin.pain) && chosen.def.legHeavy) {
      final alt = scored.firstWhere((s) => !s.def.legHeavy, orElse: () => chosen);
      if (!identical(alt, chosen)) {
        chosen = alt;
        fired.add(const FiredRule(RuleKey.painSubSharp, pattern: 'HIP_SESSION_SWAP'));
      }
    }
    if (input.forcedSessionId == null &&
        winner.id == SessionTypeId.s6 &&
        s6ConditionMet) {
      fired.add(const FiredRule(RuleKey.s6WeekendRule));
    }
    if (chosen.terms.containsKey('recencyBoost') && mostOverdue != null) {
      fired.add(FiredRule(RuleKey.recencyBoost, pattern: mostOverdue.name));
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

    if (effectiveSessionId == SessionTypeId.s3 && checkin.timeMinutes < 35) {
      effectiveSessionId = SessionTypeId.s7;
      fired.add(const FiredRule(RuleKey.s7TimeSub));
    }

    // Readiness modulation evaluates the time-adjusted effective type. In
    // particular, RED S3@20 first becomes S7 for feasibility, then becomes
    // S6 because high-intensity REHIT is not a RED-day prescription.
    if (recovery.bucket == ReadinessBucket.yellow) {
      if (effectiveSessionId == SessionTypeId.s1 ||
          effectiveSessionId == SessionTypeId.s2 ||
          effectiveSessionId == SessionTypeId.s4 ||
          effectiveSessionId == SessionTypeId.s5) {
        setMultiplier = 0.75;
        rirFloor = Rir.rir2;
        progressionEligible = false;
        fired.add(const FiredRule(RuleKey.yellowVolumeCut));
      } else if (effectiveSessionId == SessionTypeId.s3) {
        effectiveSessionId = SessionTypeId.s7;
        fired.add(const FiredRule(RuleKey.yellow4x4ToRehit));
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

    if (volumeCutForLegHeavyEscape) {
      setMultiplier *= 0.8;
    }

    // Selection rationale must describe the plan that survives forced
    // selection, pain protection, and readiness/time substitutions. Pressure
    // still contributes to every candidate's score even when its rule is not
    // emitted for the final plan.
    final effectiveCountsAs = sessionTypes[effectiveSessionId]!.countsAs;
    if (strengthPressure.level == FloorPressureLevel.hard &&
        effectiveCountsAs.contains(FloorCategory.strength)) {
      fired.add(const FiredRule(RuleKey.floorForceStrength));
    }
    if (!bothHardForced &&
        intensityPressure.level == FloorPressureLevel.hard &&
        effectiveCountsAs.contains(FloorCategory.intensity)) {
      fired.add(const FiredRule(RuleKey.floorForceIntensity));
    }
    if (strengthPressure.level == FloorPressureLevel.soft &&
        effectiveCountsAs.contains(FloorCategory.strength)) {
      fired.add(const FiredRule(
        RuleKey.floorSoftBoost,
        params: {'category': 'strength'},
      ));
    }
    if (intensityPressure.level == FloorPressureLevel.soft &&
        effectiveCountsAs.contains(FloorCategory.intensity)) {
      fired.add(const FiredRule(
        RuleKey.floorSoftBoost,
        params: {'category': 'intensity'},
      ));
    }
    // QUEUE_NEXT only describes an unchanged, credit-bearing natural cycle
    // pick. Forced, pain-swapped, readiness-swapped, and time-substituted
    // plans are explained by their own rule keys.
    if (input.forcedSessionId == null &&
        chosen.id == input.queueState.pointer &&
        chosen.id == effectiveSessionId &&
        !redTechnique &&
        cycleOrder.contains(chosen.id) &&
        strengthPressure.level != FloorPressureLevel.hard &&
        intensityPressure.level != FloorPressureLevel.hard) {
      fired.add(FiredRule(
        RuleKey.queueNext,
        params: {'session': chosen.def.name},
      ));
    }

    // --- Plan assembly (Steps 7-9) ---
    final template = sessionTemplates[effectiveSessionId];
    final scheduledPatterns = <MovementPattern>{};
    final exercises = <PlannedExercise>[];

    if (template != null && !template.isCardioOnly) {
      // §2.5: when the ATG/knee-health block is present it runs first and
      // replaces the general warm-up (the 40/60/80 ramp); every lift still
      // gets its 60% feeder set below.
      var rampDone = false;
      if (template.hasKneeHealthBlock) {
        exercises.add(PlannedExercise(
          trackKey: 'atg_block',
          pattern: MovementPattern.kneeHealth,
          name: input.settings.travelMode
              ? 'Travel knee-health: backward walking, wall tibialis raises, calf raises'
              : 'ATG block: backward treadmill 3-4 min, tibialis raises, slant-board calf raises',
          sets: 1,
          metric: ExerciseMetric.minutes,
          targetRange: const (5, 7),
          rirTarget: Rir.rir3plus,
          isWarmup: true,
          instruction: input.settings.travelMode
              ? 'No equipment - walk backward only where it is safe and clear'
              : 'Runs first - replaces the general warm-up (§2.5)',
          progressionEligible: false,
          isTravel: input.settings.travelMode,
        ));
        rampDone = true;
      } else {
        exercises.add(_generalWarmupEntry(
          effectiveSessionId,
          travelMode: input.settings.travelMode,
        ));
      }
      // §5 Step 7 "60 -> 35": a natively-60-minute session (S2/S4) in a
      // 35-minute slot keeps its superset pairs but drops the accessory
      // block - otherwise the plan physically cannot fit the slot.
      final compress60to35 =
          tier == SessionTier.full && sessionTypes[effectiveSessionId]!.fullDurationMin >= 60;
      var slots = template.slotsForTier(tier, dropAccessories: compress60to35);
      if (input.settings.travelMode) {
        var travelViable = slots
            .where((slot) => _travelStepFor(slot.$1, slot.$3) != null)
            .toList();
        // S5's compressed source normally starts with two DB accessories.
        // In travel mode keep the foundational core slot plus one
        // equipment-free pump slot instead of dropping core entirely.
        if (effectiveSessionId == SessionTypeId.s5 && tier == SessionTier.compressed) {
          travelViable = [
            for (final pattern in template.accessoryPatterns)
              (pattern, true, null as SubstituteExercise?),
            for (final named in template.namedAccessories)
              (named.pattern, true, named as SubstituteExercise?),
          ].where((slot) => _travelStepFor(slot.$1, slot.$3) != null).take(2).toList();
        }
        if (travelViable.isEmpty) {
          final fallback = [
            for (final pattern in template.compoundPatterns)
              (pattern, true, null as SubstituteExercise?),
            for (final pattern in template.accessoryPatterns)
              (pattern, false, null as SubstituteExercise?),
          ].where((slot) => _travelStepFor(slot.$1, slot.$3) != null).toList();
          travelViable = tier == SessionTier.compressed
              ? fallback.take(2).map((slot) => (slot.$1, true, slot.$3)).toList()
              : fallback;
        }
        slots = travelViable;
      }
      for (final (pattern, isCompound, namedExercise) in slots) {
        scheduledPatterns.add(pattern);
        final baseSets = template.setsFor(isCompound, tier);
        final cutSets = (baseSets * setMultiplier).floor().clamp(baseSets == 0 ? 0 : 1, baseSets);

        final trackKey = namedExercise?.trackKey ?? pattern.name;
        final stateExisted = patchedStates.containsKey(trackKey);
        var state = patchedStates[trackKey] ??
            ExerciseState(trackKey: trackKey, pattern: pattern);
        if (automaticGlobalDeload && !stateExisted) {
          state = progressionEngine.forceGlobalDeload([state]).single;
        }

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
          patternScheduledToday: true,
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
        if (action.kind == PainActionKind.substituteNamed && action.substitute != null) {
          final sub = action.substitute!;
          final subStateExisted = patchedStates.containsKey(sub.trackKey);
          var subState = patchedStates[sub.trackKey] ??
              ExerciseState(trackKey: sub.trackKey, pattern: sub.pattern);
          if (automaticGlobalDeload && !subStateExisted) {
            subState = progressionEngine.forceGlobalDeload([subState]).single;
          }
          patchedStates[sub.trackKey] = subState;
          substitutedFrom = pattern.name;
          final resolution = progressionEngine.resolveTodaysPrescription(
            subState,
            today,
            input.settings.equipment,
          );
          prescriptionState = resolution.state;
          if (resolution.detrainFired && !input.settings.travelMode) {
            fired.add(FiredRule(
              RuleKey.detrainAdjust,
              pattern: sub.pattern.name,
            ));
            persistLoad = loadMultiplier == 1.0;
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
          fired.add(const FiredRule(RuleKey.onboardSubstitute));
        } else {
          final resolution = progressionEngine.resolveTodaysPrescription(state, today, input.settings.equipment);
          prescriptionState = resolution.state;
          if (resolution.detrainFired && !input.settings.travelMode) {
            fired.add(FiredRule(RuleKey.detrainAdjust, pattern: pattern.name));
            // §6.6: the ramp load becomes the working load once actually trained
            persistLoad = loadMultiplier == 1.0;
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
        var planned = _buildPlannedExercise(
          prescriptionState,
          sets: exerciseSets,
          rirFloor: exerciseRir,
          loadMultiplier: exerciseLoadMultiplier,
          equipmentConfig: input.settings.equipment,
          substitutedFrom: substitutedFrom,
          progressionEligible: progressionEligible,
          persistLoadOnCompletion: persistLoad,
          targetRangeOverride: reentryTarget,
          instruction: painReentryPrescription
              ? prescriptionStep.metric == ExerciseMetric.seconds
                  ? 'Pain re-entry check: one easy 10-second hold, keep at least 4 RIR and stop if pain returns'
                  : 'Pain re-entry test: 1 x 8 at 50% load, keep at least 4 RIR and stop if pain returns'
              : null,
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
            );
          }
        }

        // §2.5 warm-up protocol: full ramp (40%x8 / 60%x5 / 80%x3) before the
        // session's first compound, one 60%x5 feeder before every later
        // loaded lift. Substitutes onboard deliberately light (§7.1) and
        // bodyweight/backpack steps have no percent-load, so both skip it.
        if (planned.loadTotal != null && action.kind != PainActionKind.substituteNamed) {
          final step = progressionEngine.ladderStepFor(prescriptionState);
          if (step.dumbbells > 0 && !step.backpackLoaded) {
            if (!rampDone && isCompound) {
              rampDone = true;
              exercises.addAll([
                _warmupEntry(planned, step, 0.40, 8, input.settings.equipment),
                _warmupEntry(planned, step, 0.60, 5, input.settings.equipment),
                _warmupEntry(planned, step, 0.80, 3, input.settings.equipment),
              ].whereType<PlannedExercise>());
            } else {
              final feeder = _warmupEntry(planned, step, 0.60, 5, input.settings.equipment);
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
        if (!e.isWarmup && e.pattern.patternClass == PatternClass.compound) compoundWork.add(i);
      }
      for (var g = 0; g + 1 < compoundWork.length; g += 2) {
        exercises[compoundWork[g]] = exercises[compoundWork[g]].copyWith(supersetGroup: g ~/ 2);
        exercises[compoundWork[g + 1]] = exercises[compoundWork[g + 1]].copyWith(supersetGroup: g ~/ 2);
      }
    } else if (template?.isCardioOnly == true) {
      exercises.add(_cardioWarmupEntry(effectiveSessionId));
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
    if (exercises.any((exercise) => exercise.isTravel)) {
      fired.add(const FiredRule(RuleKey.travelModeActive));
    }
    final estimatedDuration = template?.isCardioOnly == true &&
            planSessionDef.fullDurationMin < checkin.timeMinutes
        ? planSessionDef.fullDurationMin
        : checkin.timeMinutes;
    final plan = SessionPlan(
      sessionId: effectiveSessionId,
      sessionName: planSessionDef.name,
      tier: tier,
      exercises: exercises,
      estimatedDurationMin: estimatedDuration,
      grantsQueueCredit: queueCreditType != null,
      travelMode: input.settings.travelMode,
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
      // S3 remains a conceptual candidate so its queue priority and floor
      // pressure are resolved first; Step 6 then substitutes the feasible
      // short REHIT plan without granting S3 queue credit.
      return [
        SessionTypeId.s1,
        SessionTypeId.s3,
        SessionTypeId.s5,
        SessionTypeId.s7,
      ];
    }
    final list = <SessionTypeId>[];
    for (final t in sessionTypes.values) {
      if (t.id == SessionTypeId.s3) {
        if (time >= t.fullDurationMin) list.add(t.id);
        continue;
      }
      if (t.minDurationMin != null && time >= t.minDurationMin!) list.add(t.id);
    }
    return list;
  }

  bool _s6ConditionMet(DecisionEngineInput input, DateTime today, FloorPressureResult strength, FloorPressureResult intensity) {
    final weekday = today.weekday;
    final isWeekend = weekday == DateTime.saturday || weekday == DateTime.sunday;
    if (!isWeekend) return false;
    if (input.checkin.timeMinutes < 30) return false;
    final last7 = input.sessionLogs.where((l) =>
        l.templateId == SessionTypeId.s6 &&
        l.countsTowardQueueAndFloor &&
        !l.date.isBefore(today.subtract(const Duration(days: 7))));
    if (last7.isNotEmpty) return false;
    final anyHardFloorPressure =
        strength.level == FloorPressureLevel.hard || intensity.level == FloorPressureLevel.hard;
    if (anyHardFloorPressure) return false;
    return true;
  }

  MovementPattern? _mostOverduePattern(Map<String, ExerciseState> states, DateTime today) {
    MovementPattern? best;
    var bestDays = 5;
    for (final s in states.values) {
      if (s.trackKey.startsWith('sub:')) continue;
      if (s.pattern.patternClass == PatternClass.kneeHealth) continue;
      final days = s.daysUntrained(today);
      if (days > bestDays ||
          (days == bestDays && best != null && s.pattern.index < best.index)) {
        bestDays = days;
        best = s.pattern;
      }
    }
    return best;
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
    final ladder = ladders[state.pattern]!;
    final step = ladder.steps[state.ladderStepIndex.clamp(0, ladder.steps.length - 1)];
    if (step.dumbbells == 0 || step.backpackLoaded) return state;
    final achievable = step.dumbbells == 1
        ? equipmentEngine.singleDbAchievableTotals(cfg)
        : equipmentEngine.twoDbAchievableTotals(cfg, allowUneven: !step.unilateral);
    final next = state.clone();
    next.currentLoad = equipmentEngine.nextAchievableBelow(state.currentLoad, achievable);
    return next;
  }

  ExerciseState _regressLadderAndReduce(ExerciseState state, EquipmentConfig cfg) {
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
    EquipmentConfig cfg,
  ) {
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
      rirTarget: Rir.rir3plus,
      isWarmup: true,
      instruction: 'Rest <= 60 s',
      progressionEligible: false,
    );
  }

  PlannedExercise _generalWarmupEntry(
    SessionTypeId id, {
    required bool travelMode,
  }) {
    final instruction = switch (id) {
      SessionTypeId.s1 =>
        'Start with easy walking or marching, then controlled hip hinges, squats, and ankle movement',
      SessionTypeId.s2 =>
        'Start with easy movement, then shoulder circles, scapular push-ups, and light reach-and-pulls',
      SessionTypeId.s5 =>
        'Start with easy movement, then shoulder, elbow, wrist, and trunk preparation',
      _ => 'Start easy, then rehearse today\'s movement patterns through a comfortable range',
    };
    return PlannedExercise(
      trackKey: 'warmup:${id.name}',
      pattern: MovementPattern.kneeHealth,
      name: 'General warm-up & movement prep',
      sets: 1,
      metric: ExerciseMetric.minutes,
      targetRange: const (5, 7),
      rirTarget: Rir.rir4plus,
      isWarmup: true,
      instruction: travelMode ? '$instruction. No equipment needed.' : instruction,
      progressionEligible: false,
      isTravel: travelMode,
    );
  }

  PlannedExercise _cardioWarmupEntry(SessionTypeId id) {
    final (range, instruction) = switch (id) {
      SessionTypeId.s3 => (
          const (8, 10),
          'Pedal easily, then include 2-3 short controlled builds before the first hard interval',
        ),
      SessionTypeId.s6 => (
          const (5, 10),
          'Begin below Zone 2 and increase gradually until breathing and cadence settle',
        ),
      SessionTypeId.s7 => (
          const (2, 3),
          'Pedal easily and include one short cadence build before the first sprint',
        ),
      _ => (const (5, 8), 'Begin at an easy effort and increase gradually'),
    };
    return PlannedExercise(
      trackKey: 'warmup:${id.name}',
      pattern: MovementPattern.kneeHealth,
      name: 'Easy cardio warm-up',
      sets: 1,
      metric: ExerciseMetric.minutes,
      targetRange: range,
      rirTarget: Rir.rir4plus,
      isWarmup: true,
      instruction: instruction,
      progressionEligible: false,
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
    bool persistLoadOnCompletion = false,
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
    if (!step.backpackLoaded && step.dumbbells > 0) {
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
      rirTarget: rirFloor,
      substitutedFrom: substitutedFrom,
      instruction: instruction,
      persistLoadOnCompletion: persistLoadOnCompletion,
      progressionEligible: progressionEligible,
    );
  }

  int _redDaysInRollingWindow(
    DecisionEngineInput input,
    ReadinessBucket currentBucket,
    DateTime today,
  ) {
    var redDays = currentBucket == ReadinessBucket.red ? 1 : 0;
    for (var offset = 1; offset < 7; offset++) {
      final date = today.subtract(Duration(days: offset));
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

class _Scored {
  final SessionTypeId id;
  final SessionTier tier;
  int score;
  final Map<String, int> terms;
  final SessionTypeDef def;

  _Scored(this.id, this.tier, this.score, this.terms, this.def);
}
