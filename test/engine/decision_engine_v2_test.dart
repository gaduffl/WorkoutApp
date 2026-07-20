import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/ai/ai_explainer.dart';
import 'package:morningcoach/engine/cardio_engine.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/engine/progression_engine.dart';
import 'package:morningcoach/engine/stimulus_ledger_engine.dart';
import 'package:morningcoach/engine/training_status_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/rule_key.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/training_targets.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  const engine = DecisionEngine();
  final today = DateTime(2026, 5, 29, 9);

  DecisionEngineInput input({
    required int time,
    int subjective = 4,
    DateTime? asOf,
    List<SessionLog> logs = const [],
    QueueState queue = const QueueState(),
    SessionTypeId? forced,
    UserSettings settings = const UserSettings(),
    List<CheckIn> checkinHistory = const [],
    List<PainFlag> pain = const [],
    Map<String, ExerciseState> exerciseStates = const {},
  }) {
    final date = asOf ?? today;
    return DecisionEngineInput(
      checkin: CheckIn(
        date: DateTime(date.year, date.month, date.day),
        timeMinutes: time,
        subjective: subjective,
        pain: pain,
        timestamp: date,
      ),
      todaySnapshot: null,
      recoveryHistory: const [],
      checkinHistory: checkinHistory,
      sessionLogs: logs,
      exerciseStates: exerciseStates,
      queueState: queue,
      settings: settings,
      today: DateTime(date.year, date.month, date.day),
      forcedSessionId: forced,
    );
  }

  SessionLog cardio(
    SessionTypeId id,
    DateTime completedAt,
    int minutes,
  ) {
    final FloorCategory category;
    switch (id) {
      case SessionTypeId.s3:
      case SessionTypeId.s7:
        category = FloorCategory.intensity;
      case SessionTypeId.s6:
        category = FloorCategory.aerobic;
      default:
        throw ArgumentError.value(id);
    }
    return SessionLog(
      id: '${id.name}-${completedAt.toIso8601String()}',
      templateId: id,
      tier: SessionTier.full,
      date: DateTime(
        completedAt.year,
        completedAt.month,
        completedAt.day,
      ),
      completedAt: completedAt,
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: minutes,
      countsAs: {category},
    );
  }

  SessionLog partialStructuredRehit(DateTime completedAt) => SessionLog(
        id: 'partial-rehit-${completedAt.toIso8601String()}',
        templateId: SessionTypeId.s7,
        tier: SessionTier.compressed,
        date: DateTime(
          completedAt.year,
          completedAt.month,
          completedAt.day,
        ),
        completedAt: completedAt,
        setLogs: const [],
        plannedWorkSets: 0,
        completedWorkSets: 0,
        durationMinutes: 1,
        countsAs: const {},
        cardioCompletion: const CardioCompletion(
          protocol: CardioProtocol.rehit,
          completedWorkIntervals: 1,
          completedWorkSeconds: 10,
          completedRecoveryIntervals: 0,
          completedRecoverySeconds: 0,
          completedDurationSeconds: 60,
        ),
      );

  SetLog workSet(
    MovementPattern pattern,
    DateTime at, {
    String? trackKey,
    String? name,
  }) =>
      SetLog(
        trackKey: trackKey ?? pattern.name,
        pattern: pattern,
        exerciseName: name ?? pattern.name,
        weight: 0,
        value: 8,
        rir: Rir.rir2,
        timestamp: at,
      );

  List<SetLog> repeatedPatterns(
    List<MovementPattern> patterns,
    int repetitions,
    DateTime at,
  ) =>
      [
        for (var index = 0; index < repetitions; index++)
          for (final pattern in patterns) workSet(pattern, at),
      ];

  SessionLog strength(
    String id,
    DateTime at,
    List<SetLog> sets,
  ) =>
      SessionLog(
        id: id,
        templateId: SessionTypeId.s4,
        tier: SessionTier.full,
        date: DateTime(at.year, at.month, at.day),
        completedAt: at,
        setLogs: sets,
        plannedWorkSets: sets.length,
        completedWorkSets: sets.length,
        durationMinutes: 35,
        countsAs: const {FloorCategory.strength},
      );

  List<SessionLog> cardioTargetsFilled(DateTime date) => [
        cardio(
          SessionTypeId.s3,
          date.subtract(const Duration(days: 2)),
          35,
        ),
        cardio(
          SessionTypeId.s7,
          date.subtract(const Duration(days: 3)),
          10,
        ),
        cardio(
          SessionTypeId.s7,
          date.subtract(const Duration(days: 4)),
          10,
        ),
        cardio(SessionTypeId.s6, date.subtract(const Duration(days: 5)), 60),
      ];

  test('GREEN 35+ makes a missing Norwegian 4x4 the top anchor', () {
    final output = engine.decide(input(time: 35));

    expect(output.trace.plan!.sessionId, SessionTypeId.s3);
    expect(output.trace.firedRuleCodes, contains('NORWEGIAN_4X4_DUE'));
    expect(
      output.trace.candidates
          .firstWhere((value) => value.sessionId == SessionTypeId.s3)
          .scoreTerms,
      contains('norwegian4x4Due'),
    );
  });

  test('partial intensity blocks a due 4x4 through the inclusive 48h guard',
      () {
    final blocked = engine.decide(input(
      time: 35,
      logs: [
        partialStructuredRehit(
          today.subtract(const Duration(hours: 48)),
        ),
      ],
    ));
    final allowed = engine.decide(input(
      time: 35,
      logs: [
        partialStructuredRehit(
          today.subtract(const Duration(hours: 48, seconds: 1)),
        ),
      ],
    ));

    expect(blocked.trace.plan!.sessionId, isNot(SessionTypeId.s3));
    expect(
      blocked.trace.candidates
          .firstWhere((candidate) => candidate.sessionId == SessionTypeId.s3)
          .scoreTerms,
      contains('surplusIntensitySuppressed'),
    );
    expect(allowed.trace.plan!.sessionId, SessionTypeId.s3);
    expect(allowed.trace.firedRuleCodes, contains('NORWEGIAN_4X4_DUE'));
  });

  test('forced intensity cannot bypass the inclusive 48h safety boundary',
      () {
    final atBoundary = engine.decide(input(
      time: 35,
      forced: SessionTypeId.s3,
      logs: [
        cardio(
          SessionTypeId.s3,
          today.subtract(const Duration(days: 4)),
          35,
        ),
        partialStructuredRehit(today.subtract(const Duration(hours: 48))),
      ],
    ));
    final outsideBoundary = engine.decide(input(
      time: 35,
      forced: SessionTypeId.s3,
      logs: [
        cardio(
          SessionTypeId.s3,
          today.subtract(const Duration(days: 4)),
          35,
        ),
        partialStructuredRehit(
          today.subtract(const Duration(hours: 48, microseconds: 1)),
        ),
      ],
    ));

    expect(atBoundary.trace.plan!.sessionId, SessionTypeId.s6);
    expect(
      atBoundary.trace.plan!.cardioPrescription!.protocol.type,
      CardioProtocolType.zone2Base,
    );
    expect(
      atBoundary.trace.firedRuleCodes,
      contains('RECOVERY_SWAP_EASY_CARDIO'),
    );
    expect(
      atBoundary.trace.firedRuleCodes,
      isNot(contains('NORWEGIAN_4X4_DUE')),
    );
    expect(
      atBoundary.trace.firedRuleCodes,
      isNot(contains('REHIT_FALLBACK_DUE')),
    );

    // The 4x4 target is already satisfied by the four-day-old qualifying
    // row, but an explicit surplus override remains possible once the newer
    // partial attempt has aged outside the hard 48-hour recovery gate.
    expect(outsideBoundary.trace.plan!.sessionId, SessionTypeId.s3);
    expect(
      outsideBoundary.trace.firedRuleCodes,
      isNot(contains('NORWEGIAN_4X4_DUE')),
    );
  });

  test('GREEN persisted global and active pattern deloads force S3/S7 to S6', () {
    final automatic = engine.decide(input(
      time: 35,
      forced: SessionTypeId.s3,
      exerciseStates:
          const ProgressionEngine().forceGlobalDeloadForBuiltInTracks({}),
    ));
    final manual = engine.decide(input(
      time: 20,
      forced: SessionTypeId.s7,
      exerciseStates: {
        'squat': ExerciseState(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          status: ExerciseStatus.deload,
          deloadSessionsRemaining: 1,
        ),
      },
    ));

    for (final output in [automatic, manual]) {
      expect(output.trace.recovery.bucket, ReadinessBucket.green);
      expect(output.trace.plan!.sessionId, SessionTypeId.s6);
      expect(
        output.trace.firedRuleCodes,
        contains('RECOVERY_SWAP_EASY_CARDIO'),
      );
      expect(
        output.trace.firedRuleCodes,
        isNot(contains('NORWEGIAN_4X4_DUE')),
      );
      expect(
        output.trace.firedRuleCodes,
        isNot(contains('REHIT_FALLBACK_DUE')),
      );
    }
  });

  test('current, persisted, and escalating pain block forced S7', () {
    final currentKnee = engine.decide(input(
      time: 20,
      forced: SessionTypeId.s7,
      pain: [
        PainFlag(
          region: BodyRegion.kneeLeft,
          severity: PainSeverity.mild,
          flaggedDate: today,
        ),
      ],
    ));
    final persistedKnee = engine.decide(input(
      time: 20,
      forced: SessionTypeId.s7,
      exerciseStates: {
        'squat': ExerciseState(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          painFrozen: true,
          painSeverity: PainSeverity.mild,
          painRegion: BodyRegion.kneeRight,
          painFlaggedDate: today.subtract(const Duration(days: 1)),
        ),
      },
    ));
    final escalation = engine.decide(input(
      time: 20,
      forced: SessionTypeId.s7,
      pain: [
        PainFlag(
          region: BodyRegion.shoulderLeft,
          severity: PainSeverity.mild,
          flaggedDate: today,
          tags: const {PainTag.radiating},
        ),
      ],
    ));
    final forcedFourByFourHip = engine.decide(input(
      time: 35,
      forced: SessionTypeId.s3,
      pain: [
        PainFlag(
          region: BodyRegion.hip,
          severity: PainSeverity.sharp,
          flaggedDate: today,
        ),
      ],
    ));

    for (final output in [
      currentKnee,
      persistedKnee,
      escalation,
    ]) {
      expect(output.trace.plan!.sessionId, SessionTypeId.s6);
      expect(
        output.trace.firedRuleCodes,
        contains('RECOVERY_SWAP_EASY_CARDIO'),
      );
      expect(
        output.trace.firedRuleCodes,
        isNot(contains('REHIT_FALLBACK_DUE')),
      );
    }
    expect(
      forcedFourByFourHip.trace.plan!.sessionId,
      anyOf(SessionTypeId.s2, SessionTypeId.s5),
    );
    expect(
      forcedFourByFourHip.trace.firedRuleCodes,
      contains('PAIN_SUB_HIP_SESSION_SWAP_SHARP'),
    );
    expect(
      forcedFourByFourHip.trace.firedRuleCodes,
      isNot(contains('RECOVERY_SWAP_EASY_CARDIO')),
    );
  });

  test('one or many same-day REHITs count as only one distinct high-intensity day', () {
    final rehitDay = today.subtract(const Duration(days: 3));
    final logs = [
      cardio(SessionTypeId.s7, rehitDay, 10),
      cardio(
        SessionTypeId.s7,
        rehitDay.add(const Duration(hours: 4)),
        10,
      ),
    ];
    final output = engine.decide(input(time: 20, logs: logs));

    expect(output.trace.plan!.sessionId, SessionTypeId.s7);
    expect(output.trace.firedRuleCodes, contains('REHIT_FALLBACK_DUE'));
  });

  test('REHIT uses an inclusive exact 48-hour recovery guard', () {
    final blockedAt475959 = engine.decide(input(
      time: 20,
      logs: [
        cardio(
          SessionTypeId.s7,
          today.subtract(
            const Duration(hours: 47, minutes: 59, seconds: 59),
          ),
          10,
        ),
      ],
    ));
    final blockedAt48 = engine.decide(input(
      time: 20,
      logs: [
        cardio(
          SessionTypeId.s7,
          today.subtract(const Duration(hours: 48)),
          10,
        ),
      ],
    ));
    final allowedAfter48 = engine.decide(input(
      time: 20,
      logs: [
        cardio(
          SessionTypeId.s7,
          today.subtract(const Duration(hours: 48, seconds: 1)),
          10,
        ),
      ],
    ));

    expect(blockedAt475959.trace.plan!.sessionId, isNot(SessionTypeId.s7));
    expect(blockedAt48.trace.plan!.sessionId, isNot(SessionTypeId.s7));
    expect(allowedAfter48.trace.plan!.sessionId, SessionTypeId.s7);
  });

  test('multi-day fallback never schedules intensity within 48 hours', () {
    final logs = <SessionLog>[];
    final intensityTimes = <DateTime>[];
    for (var day = 0; day < 8; day++) {
      final at = today.add(Duration(days: day));
      final output = engine.decide(input(
        time: 20,
        asOf: at,
        logs: logs,
      ));
      if (output.trace.plan!.sessionId != SessionTypeId.s7) continue;
      intensityTimes.add(at);
      logs.add(cardio(SessionTypeId.s7, at, 10));
    }

    expect(intensityTimes, hasLength(3));
    expect(
      intensityTimes[1].difference(intensityTimes[0]),
      greaterThan(const Duration(hours: 48)),
    );
  });

  test('20-minute slot can select a third REHIT while the three-day target is due', () {
    final logs = [
      cardio(
        SessionTypeId.s7,
        today.subtract(const Duration(days: 3)),
        10,
      ),
      cardio(
        SessionTypeId.s7,
        today.subtract(const Duration(days: 6)),
        10,
      ),
    ];
    final output = engine.decide(input(time: 20, logs: logs));

    expect(output.trace.plan!.sessionId, SessionTypeId.s7);
    expect(
      output.trace.candidates
          .firstWhere((value) => value.sessionId == SessionTypeId.s7)
          .scoreTerms,
          contains('rehitFallbackDue'),
    );
  });

  test('a REHIT already today cannot advance a distinct-day fallback', () {
    final logs = [
      cardio(
        SessionTypeId.s7,
        today.subtract(const Duration(hours: 1)),
        10,
      ),
    ];
    final output = engine.decide(input(time: 20, logs: logs));
    expect(output.trace.plan!.sessionId, isNot(SessionTypeId.s7));
  });

  test('two REHIT days prioritize 4x4 at 35 and 60 minutes',
      () {
    final completedFallback = [
      cardio(
        SessionTypeId.s7,
        today.subtract(const Duration(days: 3)),
        10,
      ),
      cardio(
        SessionTypeId.s7,
        today.subtract(const Duration(days: 5)),
        10,
      ),
    ];

    for (final time in const [35, 60]) {
      final output = engine.decide(input(
        time: time,
        logs: completedFallback,
      ));
      final fourByFourCandidate = output.trace.candidates.firstWhere(
        (candidate) => candidate.sessionId == SessionTypeId.s3,
      );

      expect(
        output.trace.plan!.sessionId,
        SessionTypeId.s3,
        reason: '$time-minute natural recommendation',
      );
      expect(
        fourByFourCandidate.scoreTerms,
        contains('norwegian4x4Due'),
      );
      expect(
        output.trace.firedRuleCodes,
        contains('NORWEGIAN_4X4_DUE'),
      );
    }
  });

  test('three REHIT days satisfy frequency and suppress a fourth natural intensity', () {
    final logs = [
      cardio(SessionTypeId.s7, today.subtract(const Duration(days: 3)), 10),
      cardio(SessionTypeId.s7, today.subtract(const Duration(days: 5)), 10),
      cardio(SessionTypeId.s7, today.subtract(const Duration(days: 7)), 10),
    ];
    final output = engine.decide(input(time: 20, logs: logs));
    final rehit = output.trace.candidates.firstWhere(
      (candidate) => candidate.sessionId == SessionTypeId.s7,
    );

    expect(output.trace.plan!.sessionId, isNot(SessionTypeId.s7));
    expect(rehit.scoreTerms, contains('surplusIntensitySuppressed'));
  });

  test('preference-met frequency deficit uses REHIT only at 20 and preserves longer strength slots', () {
    final logs = [
      cardio(SessionTypeId.s3, today.subtract(const Duration(days: 7)), 35),
      cardio(SessionTypeId.s7, today.subtract(const Duration(days: 4)), 10),
    ];

    for (final time in const [35, 60]) {
      final output = engine.decide(input(time: time, logs: logs));
      expect(output.trace.plan!.sessionId, isNot(SessionTypeId.s7));
      expect(
        output.trace.candidates
            .firstWhere((candidate) => candidate.sessionId == SessionTypeId.s7)
            .scoreTerms,
        contains('surplusIntensitySuppressed'),
      );
    }

    final twenty = engine.decide(input(time: 20, logs: logs));
    expect(twenty.trace.plan!.sessionId, SessionTypeId.s7);
    expect(twenty.trace.firedRuleCodes, contains('REHIT_FALLBACK_DUE'));
  });

  test('extended S2 reserves its optional REHIT finisher only while a distinct day is due', () {
    final twoDistinctDays = [
      cardio(SessionTypeId.s3, today.subtract(const Duration(days: 7)), 35),
      cardio(SessionTypeId.s7, today.subtract(const Duration(days: 4)), 10),
    ];
    final due = engine.decide(input(
      time: 60,
      forced: SessionTypeId.s2,
      logs: twoDistinctDays,
    ));
    expect(due.trace.plan!.sessionId, SessionTypeId.s2);
    expect(due.trace.plan!.tier, SessionTier.extended);
    expect(due.trace.plan!.optionalRehitFinisherReserved, isTrue);

    final complete = engine.decide(input(
      time: 60,
      forced: SessionTypeId.s2,
      logs: [
        ...twoDistinctDays,
        cardio(SessionTypeId.s7, today.subtract(const Duration(days: 3)), 10),
      ],
    ));
    expect(complete.trace.plan!.sessionId, SessionTypeId.s2);
    expect(complete.trace.plan!.tier, SessionTier.extended);
    expect(complete.trace.plan!.optionalRehitFinisherReserved, isFalse);
  });

  test('an incomplete high-intensity frequency target keeps a feasible 4x4 preferred', () {
    final output = engine.decide(input(
      time: 35,
      logs: [
        cardio(
          SessionTypeId.s7,
          today.subtract(const Duration(days: 3)),
          10,
        ),
      ],
    ));

    expect(output.trace.plan!.sessionId, SessionTypeId.s3);
    expect(output.trace.firedRuleCodes, contains('NORWEGIAN_4X4_DUE'));
  });

  test('manual 4x4 remains available after two REHIT days',
      () {
    final output = engine.decide(input(
      time: 35,
      forced: SessionTypeId.s3,
      logs: [
        cardio(
          SessionTypeId.s7,
          today.subtract(const Duration(days: 3)),
          10,
        ),
        cardio(
          SessionTypeId.s7,
          today.subtract(const Duration(days: 5)),
          10,
        ),
      ],
    ));

    expect(output.trace.plan!.sessionId, SessionTypeId.s3);
    expect(output.trace.firedRuleCodes, contains('MANUAL_SESSION_OVERRIDE'));
    expect(
      output.trace.firedRuleCodes,
      contains('NORWEGIAN_4X4_DUE'),
    );
  });

  test('4x4 remains preferred while a two-REHIT history is still short of three days',
      () {
    final fallbackLogs = [
      cardio(
        SessionTypeId.s7,
        today.subtract(const Duration(days: 3)),
        10,
      ),
      cardio(
        SessionTypeId.s7,
        today.subtract(const Duration(days: 5)),
        10,
      ),
    ];
    final later = today.add(const Duration(days: 3));
    final output = engine.decide(input(
      time: 35,
      asOf: later,
      logs: fallbackLogs,
    ));

    expect(output.trace.plan!.sessionId, SessionTypeId.s3);
    expect(output.trace.firedRuleCodes, contains('NORWEGIAN_4X4_DUE'));
  });

  test('60-minute strength deficits outrank a missing base exposure', () {
    final anchor = cardio(
      SessionTypeId.s3,
      today.subtract(const Duration(days: 2)),
      35,
    );
    final longDue = engine.decide(input(
      time: 60,
      logs: [
        anchor,
        cardio(
          SessionTypeId.s6,
          today.subtract(const Duration(days: 3)),
          35,
        ),
      ],
    ));
    expect(longDue.trace.plan!.sessionId, isNot(SessionTypeId.s6));
    expect(longDue.trace.firedRuleCodes, isNot(contains('BASE_LONG_DEFICIT')));
    expect(
      longDue.trace.candidates
          .firstWhere((candidate) => candidate.sessionId == SessionTypeId.s6)
          .scoreTerms,
      isNot(contains('baseLongDeficit')),
    );

  });

  test('weekly and 28-day muscle deficits dominate the queue tie-break', () {
    final filled = cardioTargetsFilled(today);
    final upper = <SetLog>[
      for (var i = 0; i < 8; i++)
        workSet(
          MovementPattern.pushHorizontal,
          today.subtract(const Duration(days: 3)),
        ),
      for (var i = 0; i < 8; i++)
        workSet(
          MovementPattern.pullHorizontal,
          today.subtract(const Duration(days: 3)),
        ),
    ];
    final logs = [
      ...filled,
      strength('upper', today.subtract(const Duration(days: 3)), upper),
    ];
    final output = engine.decide(input(
      time: 20,
      logs: logs,
      queue: const QueueState(pointer: SessionTypeId.s2),
    ));
    final s1 = output.trace.candidates
        .firstWhere((value) => value.sessionId == SessionTypeId.s1);
    final s2 = output.trace.candidates
        .firstWhere((value) => value.sessionId == SessionTypeId.s2);

    expect(s1.score, greaterThan(s2.score));
    expect(s1.scoreTerms, contains('muscleWeeklyDeficit'));
  });

  test('28-day maximum and today/yesterday work demote projected stimulus', () {
    final atMax = <SetLog>[
      for (var i = 0; i < 48; i++)
        workSet(
          MovementPattern.squat,
          today.subtract(const Duration(days: 2)),
        ),
      for (var i = 0; i < 48; i++)
        workSet(
          MovementPattern.hinge,
          today.subtract(const Duration(days: 2)),
        ),
    ];
    final recent = <SetLog>[
      workSet(
        MovementPattern.pushHorizontal,
        today.subtract(const Duration(days: 1)),
      ),
      workSet(
        MovementPattern.pullHorizontal,
        today.subtract(const Duration(days: 1)),
      ),
    ];
    final output = engine.decide(input(
      time: 20,
      logs: [
        ...cardioTargetsFilled(today),
        strength('lower-max', today.subtract(const Duration(days: 2)), atMax),
        strength('upper-recent', today.subtract(const Duration(days: 1)), recent),
      ],
    ));
    final s1 = output.trace.candidates
        .firstWhere((value) => value.sessionId == SessionTypeId.s1);
    final s2 = output.trace.candidates
        .firstWhere((value) => value.sessionId == SessionTypeId.s2);

    expect(s1.scoreTerms, contains('muscleOverMaxDemotion'));
    expect(s2.scoreTerms, contains('muscleRecoveryDemotion'));
  });

  test('over-maximum demotion starts on the projected crossing portion', () {
    Map<String, int> s1TermsAt(int observedSets) {
      final historicalAt = today.subtract(const Duration(days: 14));
      final lower = <SetLog>[
        for (var i = 0; i < observedSets; i++)
          workSet(
            MovementPattern.squat,
            historicalAt,
          ),
        for (var i = 0; i < observedSets; i++)
          workSet(
            MovementPattern.hinge,
            historicalAt,
          ),
      ];
      return engine
          .decide(input(
            time: 20,
            logs: [
              ...cardioTargetsFilled(today),
              strength(
                'lower-$observedSets',
                historicalAt,
                lower,
              ),
            ],
          ))
          .trace
          .candidates
          .firstWhere((candidate) => candidate.sessionId == SessionTypeId.s1)
          .scoreTerms;
    }

    final justBelowPenalty =
        s1TermsAt(47)['muscleOverMaxDemotion']!;
    final atMaximumPenalty =
        s1TermsAt(48)['muscleOverMaxDemotion']!;

    expect(justBelowPenalty, lessThan(0));
    expect(atMaximumPenalty, lessThan(justBelowPenalty));
  });

  test('weekly maximum demotion penalizes only projected crossing sets', () {
    Map<String, int> s1TermsAt(int observedSets) {
      final recentAt = today.subtract(const Duration(days: 2));
      final lower = <SetLog>[
        for (var i = 0; i < observedSets; i++)
          workSet(MovementPattern.squat, recentAt),
        for (var i = 0; i < observedSets; i++)
          workSet(MovementPattern.hinge, recentAt),
      ];
      return engine
          .decide(input(
            time: 20,
            logs: [
              ...cardioTargetsFilled(today),
              strength('weekly-lower-$observedSets', recentAt, lower),
            ],
          ))
          .trace
          .candidates
          .firstWhere((candidate) => candidate.sessionId == SessionTypeId.s1)
          .scoreTerms;
    }

    // S1 projects two sets each to quads, hamstrings, and glutes. At 11,
    // only one of those two projected sets crosses the weekly maximum for
    // each muscle; at 12, both do.
    expect(s1TermsAt(10), isNot(contains('muscleOverMaxDemotion')));
    expect(s1TermsAt(11)['muscleOverMaxDemotion'], -540);
    expect(s1TermsAt(12)['muscleOverMaxDemotion'], -1080);
  });

  test('automatic global deload projects no qualifying muscle stimulus', () {
    final output = engine.decide(input(
      time: 20,
      logs: cardioTargetsFilled(today),
      exerciseStates:
          const ProgressionEngine().forceGlobalDeloadForBuiltInTracks({}),
    ));
    final plan = output.trace.plan!;
    final strengthCandidate = output.trace.candidates.firstWhere(
      (candidate) => candidate.sessionId == plan.sessionId,
    );
    final work = plan.exercises.where((exercise) => !exercise.isWarmup);

    expect(plan.grantsQueueCredit, isTrue);
    expect(work, isNotEmpty);
    expect(
      work.every((exercise) => exercise.rirTarget == Rir.rir4plus),
      isTrue,
    );
    expect(
      strengthCandidate.scoreTerms.keys,
      isNot(contains('muscleWeeklyDeficit')),
    );
    expect(
      strengthCandidate.scoreTerms.keys,
      isNot(contains('muscle28dMinimumDeficit')),
    );
    expect(
      strengthCandidate.scoreTerms.keys,
      isNot(contains('muscle28dCenterDeficit')),
    );
    expect(
      output.trace.firedRuleCodes,
      isNot(contains('MUSCLE_STIMULUS_DEFICIT')),
    );
  });

  test('missing 60m base wins when every deficit-bearing strength option is recovery-demoted', () {
    final recoveryDemotedStrength = strength(
      'recent-all-patterns',
      today.subtract(const Duration(days: 1)),
      repeatedPatterns(
        const [
          MovementPattern.squat,
          MovementPattern.hinge,
          MovementPattern.pushHorizontal,
          MovementPattern.pullHorizontal,
          MovementPattern.pushVertical,
          MovementPattern.pullVertical,
          MovementPattern.coreGrip,
        ],
        1,
        today.subtract(const Duration(days: 1)),
      ),
    );
    final output = engine.decide(input(
      time: 60,
      logs: [
        cardio(SessionTypeId.s3, today.subtract(const Duration(days: 7)), 35),
        cardio(SessionTypeId.s7, today.subtract(const Duration(days: 4)), 10),
        cardio(SessionTypeId.s7, today.subtract(const Duration(days: 2)), 10),
        recoveryDemotedStrength,
      ],
    ));

    expect(output.trace.plan!.sessionId, SessionTypeId.s6);
    expect(output.trace.firedRuleCodes, contains('BASE_LONG_DEFICIT'));
    expect(
      output.trace.candidates
          .firstWhere((candidate) => candidate.sessionId == SessionTypeId.s6)
          .scoreTerms['baseLongDeficit'],
      15000,
    );
  });

  test('all four strength families emit real work at 20 minutes', () {
    final logs = cardioTargetsFilled(today);
    for (final id in [
      SessionTypeId.s1,
      SessionTypeId.s2,
      SessionTypeId.s4,
      SessionTypeId.s5,
    ]) {
      final output = engine.decide(input(
        time: 20,
        logs: logs,
        forced: id,
      ));
      final work = output.trace.plan!.exercises
          .where((value) => !value.isWarmup)
          .toList();
      expect(output.trace.plan!.sessionId, id);
      expect(work.length, 2, reason: id.name);
      expect(work.every((value) => value.sets == 2), isTrue);
    }
  });

  test('S6 is recovery-only at 20 minutes and can fill missing 60m base after strength is saturated',
      () async {
    final saturatedStrength = strength(
      'all-muscles-above-weekly-max',
      today.subtract(const Duration(days: 2)),
      repeatedPatterns(
        const [
          MovementPattern.squat,
          MovementPattern.hinge,
          MovementPattern.pushHorizontal,
          MovementPattern.pullHorizontal,
          MovementPattern.pushVertical,
          MovementPattern.pullVertical,
          MovementPattern.coreGrip,
        ],
        48,
        today.subtract(const Duration(days: 2)),
      ),
    );
    final natural = engine.decide(input(
      time: 20,
      logs: [...cardioTargetsFilled(today), saturatedStrength],
    ));
    final natural35 = engine.decide(input(
      time: 35,
      logs: [...cardioTargetsFilled(today), saturatedStrength],
    ));
    final output = engine.decide(input(
      time: 20,
      logs: [...cardioTargetsFilled(today), saturatedStrength],
      forced: SessionTypeId.s6,
    ));
    final plan = output.trace.plan!;
    final candidate = output.trace.candidates.firstWhere(
      (value) => value.sessionId == SessionTypeId.s6,
    );
    final completion = const CardioEngine().completionFromEntry(
      prescription: plan.cardioPrescription!,
      completedWorkIntervals: 1,
      completedDurationMinutes: 20,
    );

    expect(natural.trace.plan!.sessionId, SessionTypeId.s6);
    expect(natural35.trace.plan!.sessionId, SessionTypeId.s6);
    expect(plan.sessionId, SessionTypeId.s6);
    expect(plan.estimatedDurationMin, 20);
    expect(plan.cardioPrescription!.plannedDurationSeconds, 20 * 60);
    expect(candidate.scoreTerms, isNot(contains('baseLongDeficit')));
    expect(completion.meetsCreditableDose, isFalse);
    expect(
      natural.trace.firedRuleCodes,
      contains('EASY_RECOVERY_CARDIO'),
    );
    expect(
      natural35.trace.firedRuleCodes,
      contains('EASY_RECOVERY_CARDIO'),
    );
    expect(natural.trace.firedRuleCodes, isNot(contains('QUEUE_NEXT')));
    expect(
      natural.trace.firedRuleCodes,
      isNot(contains('BASE_LONG_DEFICIT')),
    );

    final baseAfterStrength = engine.decide(input(
      time: 60,
      logs: [
        cardio(SessionTypeId.s3, today.subtract(const Duration(days: 2)), 35),
        cardio(SessionTypeId.s7, today.subtract(const Duration(days: 4)), 10),
        cardio(SessionTypeId.s7, today.subtract(const Duration(days: 6)), 10),
        saturatedStrength,
      ],
    ));
    expect(baseAfterStrength.trace.plan!.sessionId, SessionTypeId.s6);
    expect(
      baseAfterStrength.trace.firedRuleCodes,
      contains('BASE_LONG_DEFICIT'),
    );
    final explanation = await const AiExplainer().dailyExplanation(
      natural.trace,
      const UserSettings(),
    );
    expect(explanation, contains('Easy continuous cardio'));
    expect(explanation, isNot(contains('queue')));
    expect(
      explanation,
      contains('no current base-aerobic deficit drove the recommendation'),
    );
    final completion35 = const CardioEngine().completionFromEntry(
      prescription: natural35.trace.plan!.cardioPrescription!,
      completedWorkIntervals: 1,
      completedDurationMinutes: 35,
    );
    expect(completion35.meetsCreditableDose, isTrue);
    final explanation35 = await const AiExplainer().dailyExplanation(
      natural35.trace,
      const UserSettings(),
    );
    expect(explanation35, isNot(contains('no base-target credit')));
  });

  test('forced surplus and strength alternatives record manual override',
      () async {
    final targetsFilledOutsideRecoveryWindow = [
      cardio(
        SessionTypeId.s3,
        today.subtract(const Duration(days: 3)),
        35,
      ),
      cardio(
        SessionTypeId.s6,
        today.subtract(const Duration(days: 3)),
        60,
      ),
      cardio(
        SessionTypeId.s6,
        today.subtract(const Duration(days: 4)),
        35,
      ),
    ];
    final outputs = <SessionTypeId, DecisionEngineOutput>{
      SessionTypeId.s3: engine.decide(input(
        time: 35,
        logs: targetsFilledOutsideRecoveryWindow,
        forced: SessionTypeId.s3,
      )),
      SessionTypeId.s6: engine.decide(input(
        time: 35,
        logs: targetsFilledOutsideRecoveryWindow,
        forced: SessionTypeId.s6,
      )),
      SessionTypeId.s2: engine.decide(input(
        time: 35,
        logs: targetsFilledOutsideRecoveryWindow,
        queue: const QueueState(pointer: SessionTypeId.s1),
        forced: SessionTypeId.s2,
      )),
    };

    for (final entry in outputs.entries) {
      final trace = entry.value.trace;
      expect(trace.plan!.sessionId, entry.key);
      expect(trace.firedRuleCodes, contains('MANUAL_SESSION_OVERRIDE'));
      expect(trace.firedRuleCodes, isNot(contains('QUEUE_NEXT')));
      final override = trace.firedRules.singleWhere(
        (rule) => rule.key == RuleKey.manualSessionOverride,
      );
      expect(override.params['session'], sessionTypes[entry.key]!.name);
      final explanation = await const AiExplainer().dailyExplanation(
        trace,
        const UserSettings(),
      );
      expect(explanation, contains('explicitly chose'));
      expect(explanation, isNot(contains('Next in queue')));
    }
  });

  test('internal forced-session preservation does not claim a manual swap', () {
    final output = engine.decide(DecisionEngineInput(
      checkin: CheckIn(
        date: today,
        timeMinutes: 35,
        subjective: 4,
        timestamp: today,
      ),
      todaySnapshot: null,
      recoveryHistory: const [],
      checkinHistory: const [],
      sessionLogs: const [],
      exerciseStates: const {},
      queueState: const QueueState(pointer: SessionTypeId.s1),
      settings: const UserSettings(),
      today: today,
      forcedSessionId: SessionTypeId.s1,
      forcedSessionProvenance: ForcedSessionProvenance.internalRefresh,
    ));

    expect(output.trace.plan!.sessionId, SessionTypeId.s1);
    expect(
      output.trace.firedRuleCodes,
      isNot(contains('MANUAL_SESSION_OVERRIDE')),
    );
  });

  test('decision rejects every time outside the immutable hard windows', () {
    for (final invalid in const [-1, 1, 19, 21, 30, 34, 36, 59, 61]) {
      expect(
        () => engine.decide(input(time: invalid)),
        throwsArgumentError,
        reason: '$invalid minutes must fail before candidate selection',
      );
    }
  });

  test('GREEN travel mode excludes CAROL-only intensity at 20 and 35', () {
    for (final time in const [20, 35]) {
      final output = engine.decide(input(
        time: time,
        settings: const UserSettings(travelMode: true),
      ));

      expect(
        output.trace.plan!.sessionId,
        isNot(anyOf(SessionTypeId.s3, SessionTypeId.s7)),
        reason: '$time-minute primary plan',
      );
      expect(
        output.trace.candidates.map((candidate) => candidate.sessionId),
        isNot(contains(SessionTypeId.s3)),
        reason: '$time-minute alternatives',
      );
      expect(
        output.trace.candidates.map((candidate) => candidate.sessionId),
        isNot(contains(SessionTypeId.s7)),
        reason: '$time-minute alternatives',
      );
    }
  });

  test('S2 compressed pair alternates horizontally/vertically by deficit', () {
    List<MovementPattern> workPatterns(List<SessionLog> logs) => engine
        .decide(input(
          time: 20,
          logs: [...cardioTargetsFilled(today), ...logs],
          forced: SessionTypeId.s2,
        ))
        .trace
        .plan!
        .exercises
        .where((value) => !value.isWarmup)
        .map((value) => value.pattern)
        .toList();

    final deltsAtMax = strength(
      'delts-max',
      today.subtract(const Duration(days: 2)),
      [
        for (var i = 0; i < 48; i++)
          workSet(
            MovementPattern.pushVertical,
            today.subtract(const Duration(days: 2)),
          ),
      ],
    );
    expect(
      workPatterns([deltsAtMax]),
      [MovementPattern.pushHorizontal, MovementPattern.pullHorizontal],
    );

    final chestAtMax = strength(
      'chest-max',
      today.subtract(const Duration(days: 2)),
      [
        for (var i = 0; i < 48; i++)
          workSet(
            MovementPattern.pushHorizontal,
            today.subtract(const Duration(days: 2)),
          ),
      ],
    );
    expect(
      workPatterns([chestAtMax]),
      [MovementPattern.pushVertical, MovementPattern.pullVertical],
    );
  });

  test('S4 compressed pair alternates lower/upper by deficit', () {
    List<MovementPattern> workPatterns(List<SetLog> dose) => engine
        .decide(input(
          time: 20,
          logs: [
            ...cardioTargetsFilled(today),
            strength(
              'dose',
              today.subtract(const Duration(days: 2)),
              dose,
            ),
          ],
          forced: SessionTypeId.s4,
        ))
        .trace
        .plan!
        .exercises
        .where((value) => !value.isWarmup)
        .map((value) => value.pattern)
        .toList();

    expect(
      workPatterns(repeatedPatterns(
        const [
          MovementPattern.pushHorizontal,
          MovementPattern.pullHorizontal,
        ],
        48,
        today.subtract(const Duration(days: 2)),
      )),
      [MovementPattern.squat, MovementPattern.hinge],
    );
    expect(
      workPatterns(repeatedPatterns(
        const [MovementPattern.squat, MovementPattern.hinge],
        48,
        today.subtract(const Duration(days: 2)),
      )),
      [MovementPattern.pushHorizontal, MovementPattern.pullHorizontal],
    );
  });

  test('S5 compressed picks the two highest-need explicit isolation slots', () {
    final atMax = <SetLog>[
      for (var i = 0; i < 48; i++)
        workSet(
          MovementPattern.coreGrip,
          today.subtract(const Duration(days: 2)),
          trackKey: 'sub:coreGrip:db_curl',
          name: 'DB curl',
        ),
      for (var i = 0; i < 48; i++)
        workSet(
          MovementPattern.pushVertical,
          today.subtract(const Duration(days: 2)),
          trackKey: 'sub:pushVertical:lateral_raise',
          name: 'Lateral raise',
        ),
    ];
    final output = engine.decide(input(
      time: 20,
      logs: [
        ...cardioTargetsFilled(today),
        strength('isolation-max', today.subtract(const Duration(days: 2)), atMax),
      ],
      forced: SessionTypeId.s5,
    ));
    final work = output.trace.plan!.exercises
        .where((value) => !value.isWarmup)
        .toList();

    expect(work.map((value) => value.trackKey), [
      'sub:pushVertical:overhead_triceps',
      MovementPattern.coreGrip.name,
    ]);
  });

  test('YELLOW never prescribes REHIT and RED@20 stays inside the window', () {
    final yellow = engine.decide(input(time: 20, subjective: 3));
    expect(yellow.trace.recovery.bucket.name, 'yellow');
    expect(yellow.trace.plan!.sessionId, SessionTypeId.s6);
    expect(yellow.trace.firedRuleCodes, contains('RECOVERY_SWAP_EASY_CARDIO'));
    expect(yellow.trace.firedRuleCodes, isNot(contains('YELLOW_4X4_TO_REHIT')));

    final red = engine.decide(input(time: 20, subjective: 1));
    expect(red.trace.plan!.sessionId, SessionTypeId.s6);
    expect(red.trace.plan!.estimatedDurationMin, 20);
  });

  test('14/28-day simulations are deterministic and never exceed a window', () {
    final first = _simulate(28);
    final second = _simulate(28);

    expect(
      first.days.map((value) => value.planKey),
      second.days.map((value) => value.planKey),
    );
    expect(
      first.days.every((value) => value.duration <= value.window),
      isTrue,
    );
    expect(
      first.days
          .take(14)
          .any((value) => value.sessionId == SessionTypeId.s3),
      isTrue,
    );
    expect(
      first.days
          .skip(14)
          .any((value) => value.sessionId == SessionTypeId.s3),
      isTrue,
    );

    final firedRuleCodes = first.days
        .expand((value) => value.firedRuleCodes)
        .toSet();
    expect(firedRuleCodes, contains('NORWEGIAN_4X4_DUE'));
    expect(firedRuleCodes, contains('BASE_LONG_DEFICIT'));

    final intensityTimes = first.logs
        .where(
          (log) =>
              log.templateId == SessionTypeId.s3 ||
              log.templateId == SessionTypeId.s7,
        )
        .map((log) => log.completedAt)
        .toList()
      ..sort();
    for (var index = 1; index < intensityTimes.length; index++) {
      expect(
        intensityTimes[index].difference(intensityTimes[index - 1]),
        greaterThan(const Duration(hours: 48)),
      );
    }

    final targets = TrainingTargets();
    final ledger = const StimulusLedgerEngine().buildFromSessionLogs(
      logs: first.logs,
      asOf: first.asOf,
    );
    final status = const TrainingStatusEngine().build(
      targets: targets,
      ledger: ledger,
    );

    // Six effective sets is the largest single-session increment to one
    // muscle (the two pull slots in an extended upper session). That is the
    // only tolerated granularity above the 28-day maximum.
    const maximumDiscreteOvershoot = 6.0;
    for (final muscle in status.muscle) {
      expect(
        muscle.deficitToMinimumEffectiveSets,
        greaterThanOrEqualTo(0),
        reason: '${muscle.muscleGroup.name} represented deficit',
      );
      expect(
        muscle.completedEffectiveSets,
        lessThanOrEqualTo(
          muscle.maximumTargetEffectiveSets + maximumDiscreteOvershoot,
        ),
        reason: '${muscle.muscleGroup.name} maximum',
      );
    }
    expect(
      status.muscle.any(
        (muscle) => muscle.deficitToMinimumEffectiveSets > 0,
      ),
      isTrue,
      reason: 'The mixed window sequence is intentionally capacity-limited',
    );
    expect(
      first.days.skip(14).any(
            (day) =>
                day.firedRuleCodes.contains('MUSCLE_STIMULUS_DEFICIT'),
          ),
      isTrue,
      reason: 'Represented deficits must continue to steer feasible strength',
    );
  });
}

_SimulationResult _simulate(int days) {
  const engine = DecisionEngine();
  const queueEngine = QueueEngine();
  final start = DateTime(2026, 6, 1, 9);
  const windows = [20, 35, 60, 20, 35, 60, 20];
  final logs = <SessionLog>[];
  final result = <_SimulationDay>[];
  var queue = const QueueState();

  for (var index = 0; index < days; index++) {
    final at = start.add(Duration(days: index));
    final window = windows[index % windows.length];
    final output = engine.decide(DecisionEngineInput(
      checkin: CheckIn(
        date: DateTime(at.year, at.month, at.day),
        timeMinutes: window,
        subjective: 4,
        timestamp: at,
      ),
      todaySnapshot: null,
      recoveryHistory: const [],
      checkinHistory: const [],
      sessionLogs: logs,
      exerciseStates: const <String, ExerciseState>{},
      queueState: queue,
      settings: const UserSettings(),
      today: DateTime(at.year, at.month, at.day),
    ));
    final plan = output.trace.plan!;
    result.add(_SimulationDay(
      window: window,
      duration: plan.estimatedDurationMin,
      sessionId: plan.sessionId,
      firedRuleCodes: output.trace.firedRuleCodes,
      planKey: '${plan.sessionId.name}:'
          '${plan.exercises.where((value) => !value.isWarmup).map((value) => value.trackKey).join(',')}',
    ));

    final sets = <SetLog>[
      for (final exercise in plan.exercises.where((value) => !value.isWarmup))
        for (var setIndex = 0;
            setIndex < exercise.sets;
            setIndex += 1)
          SetLog(
            trackKey: exercise.trackKey,
            pattern: exercise.pattern,
            exerciseName: exercise.name,
            weight: exercise.loadTotal ?? 0,
            value: exercise.targetRange.$1,
            metric: exercise.metric,
            rir: Rir.rir2,
            timestamp: at,
          ),
    ];
    logs.add(SessionLog(
      id: 'simulation-$index',
      templateId: plan.sessionId,
      tier: plan.tier,
      date: DateTime(at.year, at.month, at.day),
      completedAt: at,
      setLogs: sets,
      plannedWorkSets: plan.plannedWorkSets,
      completedWorkSets: sets.length,
      durationMinutes: plan.estimatedDurationMin,
      countsAs: sessionTypes[plan.sessionId]!.countsAs,
    ));
    if (plan.grantsQueueCredit) {
      queue = queueEngine.advance(queue, plan.sessionId);
    }
  }
  return _SimulationResult(
    days: result,
    logs: logs,
    asOf: start.add(Duration(days: days - 1)),
  );
}

class _SimulationResult {
  final List<_SimulationDay> days;
  final List<SessionLog> logs;
  final DateTime asOf;

  _SimulationResult({
    required List<_SimulationDay> days,
    required List<SessionLog> logs,
    required this.asOf,
  })  : days = List<_SimulationDay>.unmodifiable(days),
        logs = List<SessionLog>.unmodifiable(logs);
}

class _SimulationDay {
  final int window;
  final int duration;
  final SessionTypeId sessionId;
  final List<String> firedRuleCodes;
  final String planKey;

  _SimulationDay({
    required this.window,
    required this.duration,
    required this.sessionId,
    required List<String> firedRuleCodes,
    required this.planKey,
  }) : firedRuleCodes = List<String>.unmodifiable(firedRuleCodes);
}
