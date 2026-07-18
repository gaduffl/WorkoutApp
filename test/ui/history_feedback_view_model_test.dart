import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/training_status.dart';
import 'package:morningcoach/models/training_targets.dart';
import 'package:morningcoach/ui/view_models/history_feedback_view_model.dart';

void main() {
  final asOf = DateTime(2026, 7, 15, 18);

  SetLog workSet({
    required String trackKey,
    required MovementPattern pattern,
    required String exerciseName,
  }) =>
      SetLog(
        trackKey: trackKey,
        pattern: pattern,
        exerciseName: exerciseName,
        weight: 20,
        value: 10,
        rir: Rir.rir2,
        timestamp: asOf,
      );

  SessionLog session({
    required String id,
    required SessionTypeId type,
    required DateTime completedAt,
    int durationMinutes = 35,
    Set<FloorCategory> countsAs = const {},
    List<SetLog> sets = const [],
    CardioCompletion? cardioCompletion,
    bool? cardioCompletedAsPrescribed,
  }) =>
      SessionLog(
        id: id,
        templateId: type,
        tier: SessionTier.full,
        date: DateTime(
          completedAt.year,
          completedAt.month,
          completedAt.day,
        ),
        completedAt: completedAt,
        setLogs: sets,
        plannedWorkSets: sets.length,
        completedWorkSets: sets.length,
        durationMinutes: durationMinutes,
        countsAs: countsAs,
        cardioCompletion: cardioCompletion,
        cardioCompletedAsPrescribed: cardioCompletedAsPrescribed,
      );

  test('empty history is safe and exposes every target deficit', () {
    final model = HistoryFeedbackViewModel.fromLogs(
      logs: const [],
      asOf: asOf,
    );

    expect(model.muscles, hasLength(9));
    expect(
      model.muscles.every(
        (row) =>
            row.effectiveSets7d == 0 &&
            row.effectiveSets28d == 0 &&
            row.bandState7d == MuscleTargetBandState.belowMinimum &&
            row.bandState28d == MuscleTargetBandState.belowMinimum,
      ),
      isTrue,
    );
    expect(
      model
          .cardioTarget(AerobicTargetKind.norwegian4x4Anchor)
          .exposureDeficit,
      1,
    );
    expect(
      model
          .cardioTarget(AerobicTargetKind.rehitSeparateDayFallback)
          .distinctDayDeficit,
      2,
    );
    expect(
      model
          .cardioTarget(AerobicTargetKind.rehitSeparateDayFallback)
          .applicable,
      isTrue,
    );
  });

  test('28-day weekly equivalent distinguishes in-band and above-max dose', () {
    final chestSets = [
      for (var i = 0; i < 32; i++)
        workSet(
          trackKey: 'pushHorizontal',
          pattern: MovementPattern.pushHorizontal,
          exerciseName: 'Push-up',
        ),
    ];
    final backSets = [
      for (var i = 0; i < 49; i++)
        workSet(
          trackKey: 'pullHorizontal',
          pattern: MovementPattern.pullHorizontal,
          exerciseName: 'DB row',
        ),
    ];
    final model = HistoryFeedbackViewModel.fromLogs(
      logs: [
        session(
          id: 'strength',
          type: SessionTypeId.s2,
          completedAt: asOf,
          countsAs: const {FloorCategory.strength},
          sets: [...chestSets, ...backSets],
        ),
      ],
      asOf: asOf,
    );

    final chest = model.muscle(MajorMuscleGroup.chest);
    expect(chest.effectiveSets7d, 32);
    expect(chest.effectiveSets28d, 32);
    expect(chest.weeklyEquivalent28d, 8);
    expect(chest.bandState7d, MuscleTargetBandState.aboveMaximum);
    expect(chest.bandState28d, MuscleTargetBandState.inBand);

    final back = model.muscle(MajorMuscleGroup.back);
    expect(back.effectiveSets28d, 49);
    expect(back.weeklyEquivalent28d, 12.25);
    expect(back.bandState7d, MuscleTargetBandState.aboveMaximum);
    expect(back.bandState28d, MuscleTargetBandState.aboveMaximum);
    expect(
      model.muscle(MajorMuscleGroup.quads).bandState7d,
      MuscleTargetBandState.belowMinimum,
    );
    expect(
      model.muscle(MajorMuscleGroup.quads).bandState28d,
      MuscleTargetBandState.belowMinimum,
    );
  });

  test('8/12 weekly and 32/48 over 28 days are inclusive band boundaries', () {
    List<SetLog> sets(
      int count, {
      required String trackKey,
      required MovementPattern pattern,
      required String exerciseName,
    }) =>
        [
          for (var i = 0; i < count; i++)
            workSet(
              trackKey: trackKey,
              pattern: pattern,
              exerciseName: exerciseName,
            ),
        ];

    final model = HistoryFeedbackViewModel.fromLogs(
      logs: [
        session(
          id: 'recent-boundaries',
          type: SessionTypeId.s2,
          completedAt: asOf,
          countsAs: const {FloorCategory.strength},
          sets: [
            ...sets(
              8,
              trackKey: 'pushHorizontal',
              pattern: MovementPattern.pushHorizontal,
              exerciseName: 'Push-up',
            ),
            ...sets(
              12,
              trackKey: 'pullHorizontal',
              pattern: MovementPattern.pullHorizontal,
              exerciseName: 'DB row',
            ),
          ],
        ),
        session(
          id: 'older-boundaries',
          type: SessionTypeId.s2,
          completedAt: asOf.subtract(const Duration(days: 14)),
          countsAs: const {FloorCategory.strength},
          sets: [
            ...sets(
              24,
              trackKey: 'pushHorizontal',
              pattern: MovementPattern.pushHorizontal,
              exerciseName: 'Push-up',
            ),
            ...sets(
              36,
              trackKey: 'pullHorizontal',
              pattern: MovementPattern.pullHorizontal,
              exerciseName: 'DB row',
            ),
          ],
        ),
      ],
      asOf: asOf,
    );

    final minimum = model.muscle(MajorMuscleGroup.chest);
    expect(minimum.effectiveSets7d, 8);
    expect(minimum.effectiveSets28d, 32);
    expect(minimum.bandState7d, MuscleTargetBandState.inBand);
    expect(minimum.bandState28d, MuscleTargetBandState.inBand);

    final maximum = model.muscle(MajorMuscleGroup.back);
    expect(maximum.effectiveSets7d, 12);
    expect(maximum.effectiveSets28d, 48);
    expect(maximum.bandState7d, MuscleTargetBandState.inBand);
    expect(maximum.bandState28d, MuscleTargetBandState.inBand);
  });

  test('legacy Norwegian 4x4 log meets only the 4x4 anchor', () {
    final model = HistoryFeedbackViewModel.fromLogs(
      logs: [
        session(
          id: 'legacy-4x4',
          type: SessionTypeId.s3,
          completedAt: asOf,
          durationMinutes: 35,
          countsAs: const {FloorCategory.intensity},
        ),
      ],
      asOf: asOf,
    );

    expect(
      model.cardioTarget(AerobicTargetKind.norwegian4x4Anchor).met,
      isTrue,
    );
    expect(
      model
          .cardioTarget(AerobicTargetKind.rehitSeparateDayFallback)
          .completedExposures,
      0,
    );
    final fallback = model.cardioTarget(
      AerobicTargetKind.rehitSeparateDayFallback,
    );
    expect(fallback.applicable, isFalse);
    expect(fallback.hasActiveDeficit, isFalse);
    expect(fallback.state, CardioTargetState.notNeeded);
    expect(
      model
          .cardioTarget(AerobicTargetKind.longBaseExposure)
          .completedExposures,
      0,
    );
  });

  test('two same-day legacy REHITs leave the distinct-day fallback deficit', () {
    final model = HistoryFeedbackViewModel.fromLogs(
      logs: [
        session(
          id: 'rehit-am',
          type: SessionTypeId.s7,
          completedAt: DateTime(2026, 7, 15, 9),
          durationMinutes: 10,
          countsAs: const {FloorCategory.intensity},
        ),
        session(
          id: 'rehit-pm',
          type: SessionTypeId.s7,
          completedAt: DateTime(2026, 7, 15, 16),
          durationMinutes: 10,
          countsAs: const {FloorCategory.intensity},
        ),
      ],
      asOf: asOf,
    );
    final fallback = model.cardioTarget(
      AerobicTargetKind.rehitSeparateDayFallback,
    );
    final fourByFour = model.cardioTarget(
      AerobicTargetKind.norwegian4x4Anchor,
    );

    expect(fourByFour.exposureDeficit, 1);
    expect(fourByFour.applicable, isTrue);
    expect(fourByFour.hasActiveDeficit, isTrue);
    expect(fourByFour.state, CardioTargetState.deficit);
    expect(fallback.completedExposures, 2);
    expect(fallback.exposureDeficit, 0);
    expect(fallback.completedDistinctDays, 1);
    expect(fallback.distinctDayDeficit, 1);
    expect(fallback.applicable, isTrue);
    expect(fallback.hasActiveDeficit, isTrue);
    expect(fallback.state, CardioTargetState.deficit);
    expect(fallback.met, isFalse);
  });

  test('two distinct-day REHITs cover the weekly target without rewriting 4x4 history', () {
    final logs = [
      session(
        id: 'rehit-day-one',
        type: SessionTypeId.s7,
        completedAt: DateTime(2026, 7, 14, 9),
        durationMinutes: 10,
        countsAs: const {FloorCategory.intensity},
      ),
      session(
        id: 'rehit-day-two',
        type: SessionTypeId.s7,
        completedAt: DateTime(2026, 7, 15, 9),
        durationMinutes: 10,
        countsAs: const {FloorCategory.intensity},
      ),
    ];
    final covered = HistoryFeedbackViewModel.fromLogs(
      logs: logs,
      asOf: asOf,
    );
    final fourByFour = covered.cardioTarget(
      AerobicTargetKind.norwegian4x4Anchor,
    );
    final fallback = covered.cardioTarget(
      AerobicTargetKind.rehitSeparateDayFallback,
    );

    expect(fourByFour.completedExposures, 0);
    expect(fourByFour.targetExposures, 1);
    expect(fourByFour.exposureDeficit, 1);
    expect(fourByFour.met, isFalse);
    expect(fourByFour.applicable, isFalse);
    expect(fourByFour.hasActiveDeficit, isFalse);
    expect(fourByFour.state, CardioTargetState.notNeeded);
    expect(fallback.completedExposures, 2);
    expect(fallback.completedDistinctDays, 2);
    expect(fallback.met, isTrue);
    expect(fallback.applicable, isTrue);
    expect(fallback.state, CardioTargetState.met);

    final agedOut = HistoryFeedbackViewModel.fromLogs(
      logs: logs,
      asOf: asOf.add(const Duration(days: 8)),
    );
    final dueAgain = agedOut.cardioTarget(
      AerobicTargetKind.norwegian4x4Anchor,
    );
    expect(dueAgain.completedExposures, 0);
    expect(dueAgain.exposureDeficit, 1);
    expect(dueAgain.applicable, isTrue);
    expect(dueAgain.hasActiveDeficit, isTrue);
    expect(dueAgain.state, CardioTargetState.deficit);
  });

  test('history session dose uses structured cardio detail and honest legacy copy', () {
    final fourByFour = session(
      id: 'structured-4x4',
      type: SessionTypeId.s3,
      completedAt: asOf,
      durationMinutes: 35,
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.norwegian4x4,
        completedWorkIntervals: 4,
        completedWorkSeconds: 960,
        completedRecoveryIntervals: 3,
        completedRecoverySeconds: 540,
        completedDurationSeconds: 2100,
      ),
    );
    final base = session(
      id: 'structured-base',
      type: SessionTypeId.s6,
      completedAt: asOf,
      durationMinutes: 20,
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.zone2Base,
        completedWorkIntervals: 1,
        completedWorkSeconds: 1200,
        completedRecoveryIntervals: 0,
        completedRecoverySeconds: 0,
        completedDurationSeconds: 1200,
      ),
    );
    final rehit = session(
      id: 'structured-rehit',
      type: SessionTypeId.s7,
      completedAt: asOf,
      durationMinutes: 10,
      cardioCompletion: const CardioCompletion(
        protocol: CardioProtocol.rehit,
        completedWorkIntervals: 2,
        completedWorkSeconds: 40,
        completedRecoveryIntervals: 1,
        completedRecoverySeconds: 180,
        completedDurationSeconds: 600,
        peakHeartRateBpm: 181,
        rpe: 9.5,
        fitnessScore: 42.5,
        peakPowerWatts: 734.5,
      ),
    );
    final legacy = session(
      id: 'legacy-rehit',
      type: SessionTypeId.s7,
      completedAt: asOf,
      durationMinutes: 10,
    );
    final strength = session(
      id: 'strength',
      type: SessionTypeId.s2,
      completedAt: asOf,
      sets: [
        workSet(
          trackKey: 'pushHorizontal',
          pattern: MovementPattern.pushHorizontal,
          exerciseName: 'Push-up',
        ),
      ],
    );

    expect(
      historySessionDoseSummary(fourByFour),
      '4 work intervals · 16:00 work · 35:00 total',
    );
    expect(historySessionDoseSummary(base), '20:00 continuous');
    expect(
      historySessionDoseSummary(rehit),
      '2 sprints · 0:40 work · 10:00 total · '
          'Fitness Score 42.5 · Peak Power 734.5 W',
    );
    expect(
      historySessionDoseSummary(legacy),
      '10 min logged · legacy cardio details unavailable',
    );
    expect(historySessionDoseSummary(strength), '1/1 sets');
  });

  test('one legacy 60m base exposure leaves the separate short deficit', () {
    final model = HistoryFeedbackViewModel.fromLogs(
      logs: [
        session(
          id: 'base-60',
          type: SessionTypeId.s6,
          completedAt: asOf,
          durationMinutes: 60,
          countsAs: const {FloorCategory.aerobic},
        ),
      ],
      asOf: asOf,
    );

    expect(
      model.cardioTarget(AerobicTargetKind.longBaseExposure).met,
      isTrue,
    );
    expect(
      model.cardioTarget(AerobicTargetKind.shortBaseExposure).exposureDeficit,
      1,
    );
  });

  test('legacy 60m plus 35m base exposures meet both separate targets', () {
    final model = HistoryFeedbackViewModel.fromLogs(
      logs: [
        session(
          id: 'base-60',
          type: SessionTypeId.s6,
          completedAt: asOf.subtract(const Duration(days: 1)),
          durationMinutes: 60,
          countsAs: const {FloorCategory.aerobic},
        ),
        session(
          id: 'base-35',
          type: SessionTypeId.s6,
          completedAt: asOf,
          durationMinutes: 35,
          countsAs: const {FloorCategory.aerobic},
        ),
      ],
      asOf: asOf,
    );

    expect(
      model.cardioTarget(AerobicTargetKind.longBaseExposure).met,
      isTrue,
    );
    expect(
      model.cardioTarget(AerobicTargetKind.shortBaseExposure).met,
      isTrue,
    );
  });
}
