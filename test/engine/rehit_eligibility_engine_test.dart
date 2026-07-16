import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/rehit_eligibility_engine.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  const engine = RehitEligibilityEngine();
  final now = DateTime(2026, 7, 15, 10);

  const qualifyingStrength = RehitFirstSessionFacts(
    completed: true,
    qualifiesAsStrength: true,
    plannedWorkSets: 8,
    completedWorkSets: 8,
  );

  SessionLog intensityLog(DateTime completedAt) => SessionLog(
        id: 'rehit-${completedAt.toIso8601String()}',
        templateId: SessionTypeId.s7,
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
        durationMinutes: 10,
        countsAs: const {FloorCategory.intensity},
      );

  RehitEligibilityInput eligibleInput({
    ReadinessBucket readinessBucket = ReadinessBucket.green,
    bool illnessGuardActive = false,
    RehitFirstSessionFacts? firstSession,
    bool noFirstSession = false,
    bool contraindicatingPainActive = false,
    bool painEscalationActive = false,
    bool globalDeloadActive = false,
    bool patternDeloadActive = false,
    List<SessionLog> sessionLogsForRecovery = const [],
    bool rehitAlreadyCompletedToday = false,
    bool rehitUnavailableDueToTravel = false,
    DateTime? nowLocal,
    int nudgeCutoffHour = 20,
  }) {
    return RehitEligibilityInput(
      readinessBucket: readinessBucket,
      illnessGuardActive: illnessGuardActive,
      firstSession: noFirstSession ? null : firstSession ?? qualifyingStrength,
      contraindicatingPainActive: contraindicatingPainActive,
      painEscalationActive: painEscalationActive,
      globalDeloadActive: globalDeloadActive,
      patternDeloadActive: patternDeloadActive,
      sessionLogsForRecovery: sessionLogsForRecovery,
      rehitAlreadyCompletedToday: rehitAlreadyCompletedToday,
      rehitUnavailableDueToTravel: rehitUnavailableDueToTravel,
      nowLocal: nowLocal ?? now,
      nudgeCutoffHour: nudgeCutoffHour,
    );
  }

  void expectClosed(
    RehitEligibilityInput input,
    RehitClosedReason reason,
  ) {
    final result = engine.evaluate(input);
    expect(result.eligible, isFalse);
    expect(result.closedReasons, contains(reason));
    expect(result.suggestedNudgeTime, isNull);
  }

  test('qualifying completed strength session on GREEN is eligible', () {
    final result = engine.evaluate(eligibleInput());

    expect(result.eligible, isTrue);
    expect(result.closedReasons, isEmpty);
    expect(result.suggestedNudgeTime, DateTime(2026, 7, 15, 15));
  });

  group('readiness and illness gates', () {
    test('YELLOW is closed', () {
      expectClosed(
        eligibleInput(readinessBucket: ReadinessBucket.yellow),
        RehitClosedReason.readinessNotGreen,
      );
    });

    test('RED is closed', () {
      expectClosed(
        eligibleInput(readinessBucket: ReadinessBucket.red),
        RehitClosedReason.readinessNotGreen,
      );
    });

    test('illness guard closes an otherwise GREEN day', () {
      expectClosed(
        eligibleInput(illnessGuardActive: true),
        RehitClosedReason.illnessGuardActive,
      );
    });
  });

  group('first-session qualification', () {
    test('requires a first-session log', () {
      final result = engine.evaluate(eligibleInput(noFirstSession: true));

      expect(result.closedReasons, [RehitClosedReason.noFirstSession]);
      expect(result.eligible, isFalse);
    });

    test('requires the session to have been completed', () {
      expectClosed(
        eligibleInput(
          firstSession: const RehitFirstSessionFacts(
            completed: false,
            qualifiesAsStrength: true,
            plannedWorkSets: 8,
            completedWorkSets: 8,
          ),
        ),
        RehitClosedReason.firstSessionNotCompleted,
      );
    });

    test('requires a strength session', () {
      expectClosed(
        eligibleInput(
          firstSession: const RehitFirstSessionFacts(
            completed: true,
            qualifiesAsStrength: false,
            plannedWorkSets: 8,
            completedWorkSets: 8,
          ),
        ),
        RehitClosedReason.firstSessionNotStrength,
      );
    });

    test('49% completion is closed', () {
      expectClosed(
        eligibleInput(
          firstSession: const RehitFirstSessionFacts(
            completed: true,
            qualifiesAsStrength: true,
            plannedWorkSets: 100,
            completedWorkSets: 49,
          ),
        ),
        RehitClosedReason.firstSessionBelowMinimumCompletion,
      );
    });

    test('exactly 50% completion qualifies', () {
      final result = engine.evaluate(
        eligibleInput(
          firstSession: const RehitFirstSessionFacts(
            completed: true,
            qualifiesAsStrength: true,
            plannedWorkSets: 8,
            completedWorkSets: 4,
          ),
        ),
      );

      expect(result.eligible, isTrue);
    });

    test('empty or invalid work-set prescription fails closed', () {
      expectClosed(
        eligibleInput(
          firstSession: const RehitFirstSessionFacts(
            completed: true,
            qualifiesAsStrength: true,
            plannedWorkSets: 0,
            completedWorkSets: 0,
          ),
        ),
        RehitClosedReason.firstSessionBelowMinimumCompletion,
      );
    });

    test('pain during the strength session closes eligibility', () {
      expectClosed(
        eligibleInput(
          firstSession: const RehitFirstSessionFacts(
            completed: true,
            qualifiesAsStrength: true,
            plannedWorkSets: 8,
            completedWorkSets: 8,
            hadPainEvent: true,
          ),
        ),
        RehitClosedReason.firstSessionPainEvent,
      );
    });

    test('early abort closes eligibility even at >=50% completion', () {
      expectClosed(
        eligibleInput(
          firstSession: const RehitFirstSessionFacts(
            completed: true,
            qualifiesAsStrength: true,
            plannedWorkSets: 8,
            completedWorkSets: 6,
            earlyAbort: true,
          ),
        ),
        RehitClosedReason.firstSessionEarlyAbort,
      );
    });
  });

  group('pain, deload, and travel gates', () {
    test('active contraindicating pain closes eligibility', () {
      expectClosed(
        eligibleInput(contraindicatingPainActive: true),
        RehitClosedReason.contraindicatingPainActive,
      );
    });

    test('active pain escalation closes eligibility', () {
      expectClosed(
        eligibleInput(painEscalationActive: true),
        RehitClosedReason.painEscalationActive,
      );
    });

    test('global deload closes eligibility', () {
      expectClosed(
        eligibleInput(globalDeloadActive: true),
        RehitClosedReason.globalDeloadActive,
      );
    });

    test('pattern deload closes eligibility', () {
      expectClosed(
        eligibleInput(patternDeloadActive: true),
        RehitClosedReason.patternDeloadActive,
      );
    });

    test('travel only closes when it actually makes REHIT unavailable', () {
      expect(engine.evaluate(eligibleInput()).eligible, isTrue);
      expectClosed(
        eligibleInput(rehitUnavailableDueToTravel: true),
        RehitClosedReason.rehitUnavailableDueToTravel,
      );
    });
  });

  group('exact trailing-48-hour intensity gate', () {
    test('one second inside the window closes eligibility', () {
      expectClosed(
        eligibleInput(
          sessionLogsForRecovery: [
            intensityLog(now.subtract(
              const Duration(hours: 47, minutes: 59, seconds: 59),
            )),
          ],
        ),
        RehitClosedReason.intensityWithinTrailing48Hours,
      );
    });

    test('exactly 48 hours ago is included', () {
      expectClosed(
        eligibleInput(
          sessionLogsForRecovery: [
            intensityLog(now.subtract(const Duration(hours: 48))),
          ],
        ),
        RehitClosedReason.intensityWithinTrailing48Hours,
      );
    });

    test('one microsecond beyond 48 hours is ignored', () {
      final result = engine.evaluate(
        eligibleInput(
          sessionLogsForRecovery: [
            intensityLog(now.subtract(
              const Duration(hours: 48, microseconds: 1),
            )),
          ],
        ),
      );

      expect(result.eligible, isTrue);
    });

    test('future timestamps are ignored instead of corrupting the gate', () {
      final result = engine.evaluate(
        eligibleInput(
          sessionLogsForRecovery: [
            intensityLog(now.add(const Duration(minutes: 1))),
          ],
        ),
      );

      expect(result.eligible, isTrue);
    });
  });

  group('same-day duplicate prevention', () {
    test('explicit completed-today marker closes with an empty recent-log cache', () {
      final result = engine.evaluate(
        eligibleInput(rehitAlreadyCompletedToday: true),
      );

      expect(result.eligible, isFalse);
      expect(
        result.closedReasons,
        contains(RehitClosedReason.rehitAlreadyCompletedToday),
      );
      expect(result.suggestedNudgeTime, isNull);
    });

    test('same-day log and duplicate marker report both independent blockers', () {
      final result = engine.evaluate(
        eligibleInput(
          sessionLogsForRecovery: [
            intensityLog(now.subtract(const Duration(hours: 1))),
          ],
          rehitAlreadyCompletedToday: true,
        ),
      );

      expect(
        result.closedReasons,
        containsAll([
          RehitClosedReason.intensityWithinTrailing48Hours,
          RehitClosedReason.rehitAlreadyCompletedToday,
        ]),
      );
    });
  });

  group('nudge-time boundaries', () {
    test('before noon uses 15:00', () {
      final result = engine.evaluate(
        eligibleInput(nowLocal: DateTime(2026, 7, 15, 11, 59, 59)),
      );

      expect(result.suggestedNudgeTime, DateTime(2026, 7, 15, 15));
    });

    test('exactly noon still resolves to 15:00', () {
      final result = engine.evaluate(
        eligibleInput(nowLocal: DateTime(2026, 7, 15, 12)),
      );

      expect(result.suggestedNudgeTime, DateTime(2026, 7, 15, 15));
    });

    test('after noon uses exactly three hours later', () {
      final result = engine.evaluate(
        eligibleInput(nowLocal: DateTime(2026, 7, 15, 16, 30)),
      );

      expect(result.suggestedNudgeTime, DateTime(2026, 7, 15, 19, 30));
    });

    test('one microsecond before cutoff is allowed', () {
      final result = engine.evaluate(
        eligibleInput(
          nowLocal: DateTime(2026, 7, 15, 16, 59, 59, 999, 999),
        ),
      );

      expect(
        result.suggestedNudgeTime,
        DateTime(2026, 7, 15, 19, 59, 59, 999, 999),
      );
    });

    test('a nudge exactly at 20:00 is suppressed while the offer remains eligible', () {
      final result = engine.evaluate(
        eligibleInput(nowLocal: DateTime(2026, 7, 15, 17)),
      );

      expect(result.eligible, isTrue);
      expect(result.closedReasons, isEmpty);
      expect(result.suggestedNudgeTime, isNull);
    });

    test('a target after 20:00 is suppressed', () {
      final result = engine.evaluate(
        eligibleInput(nowLocal: DateTime(2026, 7, 15, 19)),
      );

      expect(result.eligible, isTrue);
      expect(result.suggestedNudgeTime, isNull);
    });

    test('caller-supplied cutoff controls suppression', () {
      final result = engine.evaluate(
        eligibleInput(
          nowLocal: DateTime(2026, 7, 15, 16),
          nudgeCutoffHour: 19,
        ),
      );

      expect(result.eligible, isTrue);
      expect(result.suggestedNudgeTime, isNull);
    });
  });

  test('all simultaneous safety failures are returned in stable enum order', () {
    final result = engine.evaluate(
      eligibleInput(
        readinessBucket: ReadinessBucket.red,
        illnessGuardActive: true,
        firstSession: const RehitFirstSessionFacts(
          completed: false,
          qualifiesAsStrength: false,
          plannedWorkSets: 8,
          completedWorkSets: 2,
          hadPainEvent: true,
          earlyAbort: true,
        ),
        contraindicatingPainActive: true,
        painEscalationActive: true,
        globalDeloadActive: true,
        patternDeloadActive: true,
        sessionLogsForRecovery: [
          intensityLog(now.subtract(const Duration(hours: 2))),
        ],
        rehitAlreadyCompletedToday: true,
        rehitUnavailableDueToTravel: true,
      ),
    );

    expect(result.eligible, isFalse);
    expect(result.suggestedNudgeTime, isNull);
    expect(
      result.closedReasons,
      RehitClosedReason.values
          .where((reason) => reason != RehitClosedReason.noFirstSession)
          .toList(),
    );
  });
}
