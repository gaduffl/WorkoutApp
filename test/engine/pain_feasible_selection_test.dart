import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/training_targets.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  const engine = DecisionEngine();
  final today = DateTime(2026, 1, 20, 7);

  SessionLog cardio(
    String id,
    SessionTypeId sessionId,
    int daysAgo,
    int minutes,
  ) =>
      SessionLog(
        id: id,
        templateId: sessionId,
        tier: SessionTier.full,
        date: today.subtract(Duration(days: daysAgo)),
        setLogs: const [],
        plannedWorkSets: 0,
        completedWorkSets: 0,
        durationMinutes: minutes,
        countsAs: sessionId == SessionTypeId.s6
            ? const {FloorCategory.aerobic}
            : const {FloorCategory.intensity},
      );

  List<SessionLog> cardioTargetsFilled() => [
        cardio('4x4', SessionTypeId.s3, 3, 35),
        cardio('long-base', SessionTypeId.s6, 2, 60),
        cardio('short-base', SessionTypeId.s6, 5, 35),
      ];

  TrainingTargets lowerPriorityTargets() {
    const zero = EffectiveSetTargetBand(
      minimum: 0,
      center: 0,
      maximum: 0,
    );
    const lower = EffectiveSetTargetBand(
      minimum: 8,
      center: 10,
      maximum: 12,
    );
    final bands = {
      for (final muscle in MajorMuscleGroup.values) muscle: zero,
    };
    bands
      ..[MajorMuscleGroup.quads] = lower
      ..[MajorMuscleGroup.glutes] = lower
      ..[MajorMuscleGroup.hamstrings] = lower
      // Keep the compound upper session ahead of the isolation/pump option
      // once lower work is medically unavailable, while the extra lower
      // effective-set projection still makes S1 the natural baseline pick.
      ..[MajorMuscleGroup.chest] = lower
      ..[MajorMuscleGroup.back] = lower;
    return TrainingTargets(hypertrophyTargetBands: bands);
  }

  TrainingTargets quadAndChestTargets() {
    const neutral = EffectiveSetTargetBand(
      minimum: 0,
      center: 0,
      maximum: 100,
    );
    const target = EffectiveSetTargetBand(
      minimum: 8,
      center: 10,
      maximum: 12,
    );
    final bands = {
      for (final muscle in MajorMuscleGroup.values) muscle: neutral,
    };
    bands
      ..[MajorMuscleGroup.quads] = target
      ..[MajorMuscleGroup.chest] = target;
    return TrainingTargets(hypertrophyTargetBands: bands);
  }

  TrainingTargets coreOnlyTargets() {
    const neutral = EffectiveSetTargetBand(
      minimum: 0,
      center: 0,
      maximum: 100,
    );
    const target = EffectiveSetTargetBand(
      minimum: 8,
      center: 10,
      maximum: 12,
    );
    final bands = {
      for (final muscle in MajorMuscleGroup.values) muscle: neutral,
    }..[MajorMuscleGroup.coreGrip] = target;
    return TrainingTargets(hypertrophyTargetBands: bands);
  }

  DecisionEngineInput input({
    int time = 20,
    List<PainFlag> pain = const [],
    Map<String, ExerciseState> states = const {},
    SessionTypeId? forced,
    TrainingTargets? targets,
  }) =>
      DecisionEngineInput(
        checkin: CheckIn(
          date: today,
          timeMinutes: time,
          subjective: 4,
          pain: pain,
          timestamp: today,
        ),
        todaySnapshot: null,
        recoveryHistory: const [],
        checkinHistory: const [],
        sessionLogs: cardioTargetsFilled(),
        exerciseStates: states,
        queueState: const QueueState(pointer: SessionTypeId.s1),
        settings: const UserSettings(),
        today: today,
        trainingTargets: targets ?? lowerPriorityTargets(),
        forcedSessionId: forced,
      );

  ExerciseState escalatedState(
    MovementPattern pattern,
    BodyRegion region,
  ) =>
      ExerciseState(
        trackKey: pattern.name,
        pattern: pattern,
        painFrozen: true,
        painSeverity: PainSeverity.sharp,
        painRegion: region,
        painFlaggedDate: today.subtract(const Duration(days: 8)),
      );

  test(
      'natural persisted lower-back escalation skips zero-work S1 for the highest-ranked viable upper session',
      () {
    final baseline = engine.decide(input());
    expect(baseline.trace.plan!.sessionId, SessionTypeId.s1);

    final output = engine.decide(input(states: {
      MovementPattern.squat.name:
          escalatedState(MovementPattern.squat, BodyRegion.lowerBack),
      MovementPattern.hinge.name:
          escalatedState(MovementPattern.hinge, BodyRegion.lowerBack),
    }));

    expect(output.trace.plan, isNotNull);
    expect(output.trace.plan!.sessionId, SessionTypeId.s2);
    expect(
      output.trace.plan!.exercises
          .where((exercise) => !exercise.isWarmup)
          .every((exercise) =>
              exercise.pattern != MovementPattern.squat &&
              exercise.pattern != MovementPattern.hinge),
      isTrue,
    );
    expect(
      output.trace.firedRules.any((rule) =>
          rule.key.name.startsWith('pain') &&
          (rule.pattern == MovementPattern.squat.name ||
              rule.pattern == MovementPattern.hinge.name)),
      isFalse,
    );
  });

  test(
      'escalated shoulder overrides a forced upper session and selected lower pain rules stay honest',
      () {
    final output = engine.decide(input(
      forced: SessionTypeId.s2,
      pain: [
        PainFlag(
          region: BodyRegion.shoulderLeft,
          severity: PainSeverity.sharp,
          flaggedDate: today,
          tags: const {PainTag.radiating},
        ),
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.mild,
          flaggedDate: today,
        ),
      ],
    ));

    expect(output.trace.plan, isNotNull);
    expect(output.trace.plan!.sessionId, SessionTypeId.s1);
    expect(
      output.trace.firedRuleCodes,
      containsAll([
        'PAIN_SUB_SQUAT_MILD',
        'PAIN_SUB_HINGE_MILD',
      ]),
    );
    expect(
      output.trace.firedRuleCodes.any(
        (code) => code.startsWith('PAIN_MEDICAL_ESCALATION_PUSH') ||
            code.startsWith('PAIN_MEDICAL_ESCALATION_PULL'),
      ),
      isFalse,
    );
    expect(
      output.trace.firedRuleCodes,
      isNot(contains('MANUAL_SESSION_OVERRIDE')),
    );
  });

  test(
      'partial pain scoring removes blocked muscle credit and credits the named substitute profile',
      () {
    final baseline = engine.decide(input(forced: SessionTypeId.s1));
    final output = engine.decide(input(
      forced: SessionTypeId.s1,
      pain: [
        PainFlag(
          region: BodyRegion.kneeLeft,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
    ));

    final baselineScore = baseline.trace.candidates
        .singleWhere((candidate) => candidate.sessionId == SessionTypeId.s1)
        .score;
    final adjustedCandidate = output.trace.candidates
        .singleWhere((candidate) => candidate.sessionId == SessionTypeId.s1);
    final work = output.trace.plan!.exercises
        .where((exercise) => !exercise.isWarmup)
        .toList();
    final muscleRule = output.trace.firedRules.singleWhere(
      (rule) => rule.key.name == 'muscleStimulusDeficit',
    );
    final targeted = muscleRule.params['muscles']!.split(', ').toSet();

    expect(output.trace.plan!.sessionId, SessionTypeId.s1);
    expect(work, hasLength(1));
    expect(work.single.trackKey, bridgeHamstringCurl.trackKey);
    expect(work.single.substitutedFrom, MovementPattern.hinge.name);
    expect(adjustedCandidate.score, lessThan(baselineScore));
    expect(
      adjustedCandidate.scoreTerms.containsKey(painNoSafeWorkScoreTerm),
      isFalse,
    );
    expect(targeted, {MajorMuscleGroup.glutes.name, MajorMuscleGroup.hamstrings.name});
    expect(targeted, isNot(contains(MajorMuscleGroup.quads.name)));
  });

  test('pain-adjusted target score changes the natural recommendation only after removal',
      () {
    final targets = quadAndChestTargets();
    final baseline = engine.decide(input(targets: targets));
    final adjusted = engine.decide(input(
      targets: targets,
      pain: [
        PainFlag(
          region: BodyRegion.kneeLeft,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
    ));
    final adjustedS1 = adjusted.trace.candidates.singleWhere(
      (candidate) => candidate.sessionId == SessionTypeId.s1,
    );

    expect(baseline.trace.plan!.sessionId, SessionTypeId.s1);
    expect(adjusted.trace.plan!.sessionId, SessionTypeId.s2);
    expect(adjustedS1.scoreTerms, isNot(contains('muscleWeeklyDeficit')));
    expect(
      adjustedS1.scoreTerms.containsKey(painNoSafeWorkScoreTerm),
      isFalse,
    );
  });

  test('per-track deload and formal pain re-entry project zero hypertrophy credit',
      () {
    final output = engine.decide(input(
      forced: SessionTypeId.s1,
      states: {
        MovementPattern.squat.name: ExerciseState(
          trackKey: MovementPattern.squat.name,
          pattern: MovementPattern.squat,
          status: ExerciseStatus.deload,
          deloadSessionsRemaining: 2,
        ),
        MovementPattern.hinge.name: ExerciseState(
          trackKey: MovementPattern.hinge.name,
          pattern: MovementPattern.hinge,
          painFrozen: true,
          painSeverity: PainSeverity.sharp,
          painRegion: BodyRegion.lowerBack,
          painFlaggedDate: today,
          painReentryTestOffered: true,
          painReentryTestPassed: false,
        ),
      },
    ));
    final candidate = output.trace.candidates.singleWhere(
      (value) => value.sessionId == SessionTypeId.s1,
    );
    final work = output.trace.plan!.exercises.where(
      (exercise) => !exercise.isWarmup,
    );

    expect(work, isNotEmpty);
    expect(work.every((exercise) => exercise.rirTarget.name == 'rir4plus'),
        isTrue);
    expect(candidate.scoreTerms, isNot(contains('muscleWeeklyDeficit')));
    expect(candidate.scoreTerms, isNot(contains('muscle28dMinimumDeficit')));
    expect(candidate.scoreTerms, isNot(contains('muscle28dCenterDeficit')));
    expect(
      candidate.scoreTerms.containsKey(painNoSafeWorkScoreTerm),
      isFalse,
    );
    expect(
      output.trace.firedRuleCodes,
      isNot(contains('MUSCLE_STIMULUS_DEFICIT')),
    );
  });

  test('time-removed accessory work is absent from the final muscle rationale',
      () {
    final output = engine.decide(input(
      time: 35,
      forced: SessionTypeId.s2,
      targets: coreOnlyTargets(),
    ));
    final work = output.trace.plan!.exercises.where(
      (exercise) => !exercise.isWarmup,
    );

    expect(output.trace.plan!.sessionId, SessionTypeId.s2);
    expect(
      work.any((exercise) => exercise.pattern == MovementPattern.coreGrip),
      isFalse,
    );
    expect(
      output.trace.firedRuleCodes,
      isNot(contains('MUSCLE_STIMULUS_DEFICIT')),
    );
  });

  test('when every strength family is escalated the existing rest outcome remains',
      () {
    final output = engine.decide(input(
      pain: [
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.tingling},
        ),
        PainFlag(
          region: BodyRegion.shoulderLeft,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.numbness},
        ),
        PainFlag(
          region: BodyRegion.elbow,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.radiating},
        ),
      ],
    ));

    expect(output.trace.plan, isNull);
    expect(output.trace.restReason, contains('No pain-free work'));
    final unavailable = output.trace.candidates.singleWhere(
      (candidate) => candidate.sessionId == SessionTypeId.s1,
    );
    expect(
      unavailable.scoreTerms.containsKey(painNoSafeWorkScoreTerm),
      isTrue,
    );
    expect(
      output.trace.firedRuleCodes,
      containsAll([
        'PAIN_MEDICAL_ESCALATION_SQUAT',
        'PAIN_MEDICAL_ESCALATION_HINGE',
      ]),
    );
    expect(
      output.trace.firedRuleCodes.any(
        (code) => code.startsWith('PAIN_MEDICAL_ESCALATION_PUSH') ||
            code.startsWith('PAIN_MEDICAL_ESCALATION_PULL'),
      ),
      isFalse,
    );
    expect(
      output.trace.firedRuleCodes,
      isNot(contains('MANUAL_SESSION_OVERRIDE')),
    );
  });
}
