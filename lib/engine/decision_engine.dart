import '../models/check_in.dart';
import '../models/decision_trace.dart';
import '../models/equipment.dart';
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
    final patchedStates = Map<String, ExerciseState>.from(input.exerciseStates);

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
    if (strengthPressure.level == FloorPressureLevel.hard) fired.add(const FiredRule(RuleKey.floorForceStrength));
    if (!bothHardForced && intensityPressure.level == FloorPressureLevel.hard) {
      fired.add(const FiredRule(RuleKey.floorForceIntensity));
    }
    if (strengthPressure.level == FloorPressureLevel.soft) fired.add(const FiredRule(RuleKey.floorSoftBoost, params: {'category': 'strength'}));
    if (intensityPressure.level == FloorPressureLevel.soft) fired.add(const FiredRule(RuleKey.floorSoftBoost, params: {'category': 'intensity'}));
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
        base = s6ConditionMet ? 60 : 10;
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
        fired.add(FiredRule(RuleKey.recencyBoost, pattern: mostOverdue.name));
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

    // QUEUE_NEXT only when the plan really is "next in queue" — a forced or
    // weekend-rule pick is explained by its own rule key instead.
    if (winner.id == input.queueState.pointer &&
        strengthPressure.level != FloorPressureLevel.hard &&
        intensityPressure.level != FloorPressureLevel.hard) {
      fired.add(FiredRule(RuleKey.queueNext, params: {'session': winner.def.name}));
    }

    // §7.1: sharp hip pain forces a swap away from a leg-heavy winner - but
    // not when the user just explicitly chose this alternative themselves.
    var chosen = winner;
    if (input.forcedSessionId == null && painEngine.hipSharpActive(checkin.pain) && chosen.def.legHeavy) {
      final alt = scored.firstWhere((s) => !s.def.legHeavy, orElse: () => chosen);
      if (!identical(alt, chosen)) {
        chosen = alt;
        fired.add(const FiredRule(RuleKey.painSubSharp, pattern: 'HIP_SESSION_SWAP'));
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
    if (checkin.timeMinutes == 20) {
      fired.add(const FiredRule(RuleKey.timeCompress35_20));
    }

    if (effectiveSessionId == SessionTypeId.s3 && checkin.timeMinutes < 35) {
      effectiveSessionId = SessionTypeId.s7;
      fired.add(const FiredRule(RuleKey.s7TimeSub));
    } else if (recovery.bucket == ReadinessBucket.yellow) {
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
      } else {
        setMultiplier = 0.5;
        loadMultiplier = 0.6;
        rirFloor = Rir.rir3plus;
        progressionEligible = false;
        redTechnique = true; // §5 Step 6: a swap — the queue item stays pending
        fired.add(const FiredRule(RuleKey.redSwapTechnique));
      }
    }

    if (volumeCutForLegHeavyEscape) {
      setMultiplier *= 0.8;
    }

    // --- Plan assembly (Steps 7-9) ---
    final template = sessionTemplates[effectiveSessionId];
    final scheduledPatterns = <MovementPattern>{};
    final exercises = <PlannedExercise>[];

    if (template != null && !template.isCardioOnly) {
      final slots = template.slotsForTier(tier);
      for (final (pattern, isCompound) in slots) {
        scheduledPatterns.add(pattern);
        final baseSets = template.setsFor(isCompound, tier);
        final cutSets = (baseSets * setMultiplier).floor().clamp(baseSets == 0 ? 0 : 1, baseSets);

        final trackKey = pattern.name;
        var state = patchedStates[trackKey] ?? ExerciseState(trackKey: trackKey, pattern: pattern);

        // Pain flag lifecycle for this pattern.
        final todayFlag = _flagFor(checkin.pain, pattern);
        state = painEngine.advanceFlagState(
          state,
          activeFlag: todayFlag,
          patternScheduledToday: true,
          sessionRanPainFree: false,
        );
        patchedStates[trackKey] = state;

        // Effective flag = today's tap OR the persisted freeze from a prior
        // day (§7.2: flags decay by rule, not by the user re-tapping the map).
        var flag = todayFlag;
        if (flag == null && state.painFrozen && state.painRegion != null) {
          flag = PainFlag(
            region: state.painRegion!,
            severity: state.painSeverity ?? PainSeverity.sharp,
            flaggedDate: state.painFlaggedDate ?? today,
          );
        }
        final reentryPending = state.painReentryTestOffered && !state.painReentryTestPassed;

        // §7.2 escalation: persistent sharp flag / radiating symptoms — the
        // pattern stays off the plan until the flag is cleared manually.
        if (flag != null && painEngine.isEscalated(flag, today)) {
          fired.add(FiredRule(RuleKey.painFreeze, pattern: pattern.name));
          fired.add(FiredRule(RuleKey.painSubSharp, pattern: pattern.name));
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
        if (action.kind == PainActionKind.substituteNamed && action.substitute != null) {
          final sub = action.substitute!;
          final subState = patchedStates[sub.trackKey] ?? ExerciseState(trackKey: sub.trackKey, pattern: sub.pattern);
          patchedStates[sub.trackKey] = subState;
          substitutedFrom = pattern.name;
          prescriptionState = subState;
          fired.add(const FiredRule(RuleKey.onboardSubstitute));
        } else {
          final resolution = progressionEngine.resolveTodaysPrescription(state, today, input.settings.equipment);
          prescriptionState = resolution.state;
          if (resolution.detrainFired) {
            fired.add(FiredRule(RuleKey.detrainAdjust, pattern: pattern.name));
            // §6.6: the ramp load becomes the working load once actually trained
            persistLoad = loadMultiplier == 1.0;
          }
          if (resolution.painReentryTestFired) {
            fired.add(FiredRule(RuleKey.painReentryTest, pattern: pattern.name));
          }
          if (resolution.deloadActive) {
            // §6.5 deload parameters: 60% load, 50% of sets, RIR >= 4.
            exerciseLoadMultiplier *= 0.6;
            exerciseSets = exerciseSets == 0 ? 0 : (exerciseSets * 0.5).floor().clamp(1, exerciseSets).toInt();
            exerciseRir = Rir.rir3plus;
            fired.add(FiredRule(RuleKey.deloadActive, pattern: pattern.name));
          }

          if (action.kind == PainActionKind.reduceLoadOne) {
            prescriptionState = _reduceLoadOne(prescriptionState, input.settings.equipment);
          } else if (action.kind == PainActionKind.regressLadderAndReduce) {
            prescriptionState = _regressLadderAndReduce(prescriptionState, input.settings.equipment);
          }
        }

        exercises.add(_buildPlannedExercise(
          prescriptionState,
          sets: exerciseSets,
          rirFloor: exerciseRir,
          loadMultiplier: exerciseLoadMultiplier,
          equipmentConfig: input.settings.equipment,
          substitutedFrom: substitutedFrom,
          progressionEligible: progressionEligible,
          persistLoadOnCompletion: persistLoad,
        ));

        if (prescriptionState.ladderStepIndex != state.ladderStepIndex && action.kind == PainActionKind.none) {
          fired.add(FiredRule(RuleKey.capLadderJump, pattern: pattern.name));
        }
      }

      if (template.hasOptionalRehitFinisher && tier == SessionTier.extended) {
        // Surfaced as an optional add-on in the UI; not a hard plan entry.
      }
    }

    final planSessionDef = sessionTypes[effectiveSessionId]!;
    final queueCreditType = redTechnique ? null : _queueCreditType(chosen.id, effectiveSessionId, recovery.bucket);
    final plan = SessionPlan(
      sessionId: effectiveSessionId,
      sessionName: planSessionDef.name,
      tier: tier,
      exercises: exercises,
      estimatedDurationMin: checkin.timeMinutes,
      grantsQueueCredit: queueCreditType != null,
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

  /// Only a same-type completion grants queue credit; RED/YELLOW swaps
  /// (incl. the RED technique session, handled by the caller) and the
  /// S3->S7 time substitution never do (§2.1, §5 Step 6).
  SessionTypeId? _queueCreditType(SessionTypeId chosenId, SessionTypeId effectiveId, ReadinessBucket bucket) {
    if (chosenId != effectiveId) return null;
    return chosenId;
  }

  List<SessionTypeId> _feasibleCandidates(int time) {
    if (time == 20) {
      return [SessionTypeId.s1, SessionTypeId.s5, SessionTypeId.s7];
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
      if (days > bestDays) {
        bestDays = days;
        best = s.pattern;
      }
    }
    return best;
  }

  PainFlag? _flagFor(List<PainFlag> pain, MovementPattern pattern) {
    for (final f in pain) {
      if (f.region.affectedPatterns.contains(pattern)) return f;
    }
    return null;
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

  PlannedExercise _buildPlannedExercise(
    ExerciseState state, {
    required int sets,
    required Rir rirFloor,
    required double loadMultiplier,
    required EquipmentConfig equipmentConfig,
    String? substitutedFrom,
    required bool progressionEligible,
    bool persistLoadOnCompletion = false,
  }) {
    final substitute = substituteRegistry[state.trackKey];
    final step = substitute != null
        ? LadderStep(name: substitute.name, dumbbells: substitute.dumbbells)
        : ladders[state.pattern]!.steps[state.ladderStepIndex.clamp(0, ladders[state.pattern]!.steps.length - 1)];
    final repRange = state.trackKey.startsWith('sub:') ? (8, 15) : state.pattern.repRange;

    double? loadTotal;
    String? loadDisplay;
    if (!step.backpackLoaded && step.dumbbells > 0) {
      loadTotal = state.currentLoad * loadMultiplier;
      final achievable = step.dumbbells == 1
          ? equipmentEngine.singleDbAchievableTotals(equipmentConfig)
          : equipmentEngine.twoDbAchievableTotals(equipmentConfig, allowUneven: !step.unilateral);
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
      repRange: repRange,
      loadTotal: loadTotal,
      loadDisplay: loadDisplay,
      rirTarget: rirFloor,
      substitutedFrom: substitutedFrom,
      persistLoadOnCompletion: persistLoadOnCompletion,
    );
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
