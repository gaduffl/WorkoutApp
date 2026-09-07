import '../models/recovery_program.dart';
import '../models/pain.dart';
import '../models/plan.dart';
import '../models/set_log.dart';
import '../models/exercise_metric.dart';
import '../models/movement_pattern.dart';
import '../models/session_type.dart';
import 'strength_duration_engine.dart';
import 'equipment_engine.dart';
import '../models/equipment.dart';

/// Conservative product rules, not validated clinical recovery milestones.
class RecoveryProgramEngine {
  const RecoveryProgramEngine();

  RecoveryProgram flare(RecoveryProgram state, DateTime date, {
    Set<RecoveryExercise> provoking = const {},
  }) => state.copyWith(
    phase: RecoveryPhase.flareUp, flareAt: date, bikePaused: true,
    pausedExercises: {...state.pausedExercises, ...provoking,
      if (provoking.isEmpty) ...state.pendingExercises},
    doses: const {},
    toleratedExposures: 0, clearPending: true, clearAssessment: true,
  );

  RecoveryProgram observe(RecoveryProgram state, RecoveryObservation observation) {
    if (observation.pain < 0 || observation.pain > 10 ||
        observation.sittingMinutes < 0 || observation.sittingMinutes > 1440) {
      throw ArgumentError('Enter pain 0–10 and sitting tolerance 0–1440 minutes.');
    }
    if (state.latest != null && observation.date.isBefore(state.latest!.date)) {
      throw ArgumentError('A symptom check cannot predate the last check.');
    }
    final newSymptoms = observation.symptoms.isNotEmpty;
    final nextDay = state.pendingSession != null &&
        !sameRecoveryDay(state.pendingSession!, observation.date) &&
        observation.date.isAfter(state.pendingSession!);
    final baseline = state.latest;
    final worse = observation.worse || newSymptoms ||
        (baseline != null && observation.pain > baseline.pain);
    final records = [...state.observations, observation];
    var next = state.copyWith(
      observations: records.length > 60 ? records.sublist(records.length - 60) : records,
      reviewRequired: state.reviewRequired || newSymptoms,
    );
    if (worse) {
      final provoking = observation.provoking.isNotEmpty
          ? observation.provoking : state.pendingExercises;
      next = flare(next, observation.date, provoking: provoking);
    } else if (nextDay) {
      final fullTolerated = state.pendingCompleteDose && !state.pendingWorse &&
          observation.function != RecoveryFunction.worse;
      next = next.copyWith(
        toleratedExposures: fullTolerated ? state.toleratedExposures + 1 : 0,
        clearPending: true,
      );
    }
    return next;
  }

  RecoveryProgram complete(RecoveryProgram state, {
    required DateTime date, required bool completeDose, required bool worse,
    Set<RecoveryExercise> exercises = const {},
  }) {
    final sessions = {...state.sessions, DateTime(date.year, date.month, date.day)}.toList()..sort();
    if (worse) return flare(state.copyWith(sessions: sessions), date, provoking: exercises);
    return state.copyWith(
      pendingSession: date, pendingCompleteDose: completeDose,
      pendingWorse: worse, pendingExercises: exercises,
      sessions: sessions.where((d) => date.difference(d).inDays <= 30).toList(),
    );
  }

  bool canAdvance(RecoveryProgram state, DateTime date) =>
      state.checkedToday(date) && !state.trainingBlocked &&
      state.pendingSession == null && state.toleratedExposures >= 2 &&
      state.latest!.function == RecoveryFunction.better && !state.latest!.worse;

  RecoveryProgram recordAssessment(RecoveryProgram state, DateTime date) {
    if (!state.checkedToday(date) || state.latest!.symptoms.isNotEmpty) {
      throw StateError('Record a current symptom check without neurological symptoms first.');
    }
    return state.copyWith(assessedAt: date, reviewRequired: false);
  }

  RecoveryProgram select(RecoveryProgram state, RecoveryExercise exercise, bool enabled) {
    final selected = {...state.selected};
    enabled ? selected.add(exercise) : selected.remove(exercise);
    if (selected.length > 4) throw StateError('Select up to four exercises for a consistent small session. Deselect one first.');
    return state.copyWith(selected: selected, toleratedExposures: 0, clearPending: true);
  }

  RecoveryProgram retrial(RecoveryProgram state, RecoveryExercise exercise, DateTime date) {
    if (!state.checkedToday(date) || state.trainingBlocked || state.latest!.worse || state.pendingSession != null) {
      throw StateError('A re-trial needs a current settled symptom check and no pending feedback.');
    }
    return state.copyWith(
      pausedExercises: {...state.pausedExercises}..remove(exercise),
      doses: {...state.doses, exercise: const RecoveryDose()}, toleratedExposures: 0,
    );
  }

  RecoveryProgram adjustDose(RecoveryProgram state, RecoveryExercise exercise, RecoveryDose dose, DateTime date, {EquipmentConfig equipment = const EquipmentConfig()}) {
    final old = state.dose(exercise);
    if (!dose.load.isFinite || dose.reps < 3 || dose.reps > 12 ||
        dose.load < 0 || dose.load > 200 || dose.rangePercent < 10 || dose.rangePercent > 100 ||
        !exercise.loaded && dose.load != 0) throw ArgumentError('Invalid dose.');
    final changed = (dose.reps != old.reps ? 1 : 0) + (dose.load != old.load ? 1 : 0) + (dose.rangePercent != old.rangePercent ? 1 : 0);
    if (changed == 0) return state;
    if (changed > 1) throw ArgumentError('Change only one variable at a time.');
    if ((dose.reps > old.reps || dose.load > old.load || dose.rangePercent > old.rangePercent) &&
        (!canAdvance(state, date) || state.pausedExercises.contains(exercise))) {
      throw StateError('An increase needs two complete tolerated exposures, improving function and an unpaused exercise.');
    }
    if (dose.load > 0 && state.assessedAt == null &&
        (exercise == RecoveryExercise.deadlift || exercise == RecoveryExercise.gluteBridge)) {
      throw StateError('Record an assessment before loaded hip re-entry.');
    }
    final loads = exercise == RecoveryExercise.floorPress || exercise == RecoveryExercise.deadlift
        ? const EquipmentEngine().twoDbAchievableTotals(equipment, allowUneven: equipment.unevenPairModeEnabled)
        : const EquipmentEngine().singleDbAchievableTotals(equipment);
    if (dose.load != 0 && !loads.contains(dose.load)) throw ArgumentError('Choose an achievable PowerBlock load: ${loads.join(', ')} lb total.');
    final nextLoads = loads.where((w) => w > old.load);
    final nextLoad = nextLoads.isEmpty ? old.load : nextLoads.first;
    if (dose.reps > old.reps + 1 || dose.rangePercent > old.rangePercent + 10 || dose.load > nextLoad) {
      throw ArgumentError('Use a small step: +1 rep/second, +10% range or one available load step.');
    }
    return state.copyWith(doses: {...state.doses, exercise: dose}, toleratedExposures: 0, clearPending: true);
  }

  RecoveryProgram advance(RecoveryProgram state, DateTime date) {
    if (!canAdvance(state, date)) throw StateError('Progression needs two complete tolerated exposures, next-morning feedback and improving daily function.');
    if (state.phase.index >= RecoveryPhase.rebuild.index && state.assessedAt == null) {
      throw StateError('Record a clinical assessment before hinge re-entry.');
    }
    if (state.phase == RecoveryPhase.returnToTraining) throw StateError('End recovery explicitly in Settings.');
    return state.copyWith(
      phase: RecoveryPhase.values[state.phase.index + 1], toleratedExposures: 0,
    );
  }

  void validateExit(RecoveryProgram state, DateTime date, {required bool alternative}) {
    if (state.phase != RecoveryPhase.returnToTraining || !canAdvance(state, date) || state.assessedAt == null) {
      throw StateError('Complete the gradual return phase with improving function and recorded assessment before ending recovery.');
    }
    final required = alternative
        ? {RecoveryExercise.gluteBridge, RecoveryExercise.hamstringCurl}
        : {RecoveryExercise.deadlift};
    if (required.any((e) => !state.selected.contains(e) || state.pausedExercises.contains(e))) {
      throw StateError('First include and tolerate the selected hinge alternative or deadlift in your gradual return work.');
    }
    if (!alternative && (state.dose(RecoveryExercise.deadlift).rangePercent < 100 || state.dose(RecoveryExercise.deadlift).load <= 0)) {
      throw StateError('Normal deadlifts require a tolerated full comfortable range and individually chosen load. Keep recovery active or choose the deadlift alternatives.');
    }
  }

  bool due(RecoveryProgram state, DateTime date) {
    if (!state.checkedToday(date) || state.trainingBlocked || state.pendingSession != null) return false;
    final day = DateTime(date.year, date.month, date.day);
    final recent = state.sessions.where((d) => !d.isBefore(day.subtract(const Duration(days: 6))) && !d.isAfter(day)).toList()..sort();
    if (state.phase == RecoveryPhase.flareUp) return !recent.any((d) => sameRecoveryDay(d, day));
    return recent.length < 2 && (recent.isEmpty || day.difference(recent.last).inDays >= 2);
  }

  bool allowed(RecoveryProgram state, RecoveryExercise e, {required bool alternative, bool travel = false}) {
    if (state.pausedExercises.contains(e) || !state.selected.contains(e)) return false;
    if (state.phase == RecoveryPhase.flareUp) return e == RecoveryExercise.abdominalActivation;
    if (travel && (e.loaded || e == RecoveryExercise.extensionHold || e == RecoveryExercise.pullUp || e == RecoveryExercise.dip || e == RecoveryExercise.hamstringCurl)) return false;
    if (e == RecoveryExercise.deadlift && (alternative || state.phase.index < RecoveryPhase.hingeReturn.index)) return false;
    if (e.needsAssessment && state.assessedAt == null) return false;
    if (e == RecoveryExercise.gluteBridge && state.dose(e).load > 0 &&
        (state.assessedAt == null || state.phase.index < RecoveryPhase.hingeReturn.index)) return false;
    return true;
  }

  SessionPlan? plan(RecoveryProgram state, {
    required DateTime date, required int minutes, required bool alternative,
    required List<PainFlag> pain, bool travel = false,
  }) {
    if (!due(state, date) || minutes <= 0) return null;
    final exercises = <PlannedExercise>[];
    for (final e in RecoveryExercise.values) {
      if (!allowed(state, e, alternative: alternative, travel: travel)) continue;
      final pattern = patternFor(e);
      if (pain.any((p) => p.tags.isNotEmpty ||
          p.region.affectedPatterns.contains(pattern) && p.severity == PainSeverity.sharp)) continue;
      final dose = state.dose(e);
      final lowerBody = const {RecoveryExercise.gluteBridge, RecoveryExercise.hamstringCurl,
        RecoveryExercise.deadlift, RecoveryExercise.extensionHold}.contains(e);
      if (lowerBody && pain.any((p) => p.region == BodyRegion.lowerBack && p.severity == PainSeverity.sharp)) continue;
      exercises.add(PlannedExercise(
        trackKey: e.trackKey, pattern: pattern, name: e.label,
        sets: e.timed ? 5 : 1,
        metric: e.timed ? ExerciseMetric.seconds : ExerciseMetric.reps,
        targetRange: (dose.reps, dose.reps), suggestedValue: dose.reps,
        loadTotal: e.loaded ? dose.load : null,
        loadDisplay: e.loaded ? '${dose.load} lb total · individually selected load' : null,
        loadSteps: e.loaded ? [dose.load] : null,
        rirTarget: Rir.rir4plus, progressionEligible: false,
        instruction: '${instructionFor(e)} Keep effort easy (4+ reps in reserve). '
          'Stop for increasing back pain or any leg symptoms. Check again later today and tomorrow morning.'
          '${e == RecoveryExercise.deadlift ? ' Selected comfortable range: ${dose.rangePercent}%; no forced depth.' : ''}',
      ));
    }
    // Do not fill the available window. Each optional exercise gets a small
    // standalone dose and no normal stimulus-deficit volume is added.
    final count = ((minutes - 1) ~/ 3).clamp(0, 4);
    final chosen = exercises.take(count).toList();
    if (chosen.isEmpty) return null;
    final prepared = [
      PlannedExercise(
        trackKey: 'recovery:v2:prep', pattern: MovementPattern.coreGrip,
        name: 'Comfortable movement preparation', sets: 1,
        metric: ExerciseMetric.minutes, targetRange: const (1, 1),
        rirTarget: Rir.rir4plus, isWarmup: true, progressionEligible: false,
        instruction: 'Easy breathing and comfortable shoulder, elbow and ankle movement. '
          'No jumping, forced bending or backbends. Skip any provoking movement.',
      ),
      ...chosen,
    ];
    const estimator = StrengthDurationEstimator();
    while (prepared.length > 1 && estimator.estimateMinutes(prepared) > minutes) {
      prepared.removeLast();
    }
    if (prepared.length == 1) return null;
    return SessionPlan(
      sessionId: SessionTypeId.s1, sessionName: state.phaseLabel,
      tier: SessionTier.compressed,
      exercises: prepared,
      estimatedDurationMin: estimator.estimateMinutes(prepared),
      grantsQueueCredit: false, lowerBackRecoveryMode: true,
    );
  }

  static MovementPattern patternFor(RecoveryExercise e) => switch (e) {
    RecoveryExercise.floorPress => MovementPattern.pushHorizontal,
    RecoveryExercise.supportedRow => MovementPattern.pullHorizontal,
    RecoveryExercise.pullUp => MovementPattern.pullVertical,
    RecoveryExercise.dip || RecoveryExercise.lateralRaise => MovementPattern.pushVertical,
    RecoveryExercise.curl || RecoveryExercise.abdominalActivation => MovementPattern.coreGrip,
    _ => MovementPattern.hinge,
  };
  static String instructionFor(RecoveryExercise e) => switch (e) {
    RecoveryExercise.abdominalActivation => 'Lie comfortably, knees bent. Gently tighten the abdomen while breathing normally; do not flatten or arch the back.',
    RecoveryExercise.floorPress => 'Back supported on the floor; no lifting arch. Getting into and out of position must also be comfortable.',
    RecoveryExercise.supportedRow => 'Use a stable chest support throughout. Do not lift the torso or arch the back.',
    RecoveryExercise.curl || RecoveryExercise.lateralRaise => 'Use stable seated or standing support without leaning or swinging.',
    RecoveryExercise.pullUp => 'Use assistance as needed. No added weight, swinging or forced arch.',
    RecoveryExercise.dip => 'Bodyweight only; no forced arch. Getting onto and off the bars must be comfortable.',
    RecoveryExercise.gluteBridge => 'Start on the floor. Lift through a comfortable hip range without arching at the top. Any load must be padded and securely controlled.',
    RecoveryExercise.hamstringCurl => 'Use suitable sliders or towels on a compatible surface. Keep the range short and trunk comfortable; do not force the hips up.',
    RecoveryExercise.extensionHold => 'Optional after assessment. Use a stable setup and near-neutral position. The app has not inspected or certified the apparatus.',
    RecoveryExercise.deadlift => 'Only the explicitly selected load and comfortable range. Do not derive the load from your previous deadlift record.',
  };
}
