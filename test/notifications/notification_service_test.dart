import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/rehit_eligibility_engine.dart';
import 'package:morningcoach/engine/rest_day_rehit_engine.dart';
import 'package:morningcoach/engine/schedule_fit_engine.dart';
import 'package:morningcoach/models/user_settings.dart';
import 'package:morningcoach/notifications/notification_service.dart';

void main() {
  test('second-REHIT nudge names the bike preset without inventing a duration', () {
    expect(secondRehitNudgeTitle, 'Still up for CAROL REHIT Intense?');
    expect(
      secondRehitNudgeBody,
      'The bike-guided CAROL REHIT Intense preset can add one short high-intensity exposure today.',
    );
    expect(secondRehitNudgeBody, isNot(contains('cover')));
    expect(secondRehitNudgeBody, isNot(contains('10-minute')));
    expect(secondRehitNudgeBody, isNot(contains('10 min')));
  });

  RehitEligibilityResult eligibleAt(
    DateTime observedAt, {
    required DateTime? suggestedNudgeTime,
  }) =>
      RehitEligibilityResult(
        closedReasons: const [],
        observedAt: observedAt,
        suggestedNudgeTime: suggestedNudgeTime,
      );

  RehitEligibilityResult closedAt(DateTime observedAt) =>
      RehitEligibilityResult(
        closedReasons: const [RehitClosedReason.readinessNotGreen],
        observedAt: observedAt,
        suggestedNudgeTime: null,
      );

  group('once-per-local-day gate consumes the shared eligibility result', () {
    final now = DateTime(2026, 7, 15, 10);
    final eligible = eligibleAt(
      now,
      suggestedNudgeTime: DateTime(2026, 7, 15, 15),
    );

    test('disabled or closed always cancels', () {
      expect(
        secondRehitNudgeSyncDecision(
          enabled: false,
          eligibility: eligible,
          scheduledDay: '2026-07-15',
        ),
        SecondRehitNudgeSyncDecision.cancel,
      );
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligibility: closedAt(now),
          scheduledDay: '2026-07-15',
        ),
        SecondRehitNudgeSyncDecision.cancel,
      );
    });

    test('an existing marker for the observed local day is kept', () {
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligibility: eligible,
          scheduledDay: '2026-07-15',
        ),
        SecondRehitNudgeSyncDecision.keep,
      );
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligibility: eligibleAt(
            DateTime(2026, 7, 15, 18),
            suggestedNudgeTime: null,
          ),
          scheduledDay: '2026-07-15',
        ),
        SecondRehitNudgeSyncDecision.keep,
        reason: 'reopening after delivery must not create a second reminder',
      );
    });

    test('a prior-day marker allows one new schedule at the supplied target', () {
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligibility: eligible,
          scheduledDay: '2026-07-14',
        ),
        SecondRehitNudgeSyncDecision.schedule,
      );
      expect(eligible.suggestedNudgeTime, DateTime(2026, 7, 15, 15));
    });

    test('eligible result with a suppressed target cancels after cutoff', () {
      final cutoffResult = eligibleAt(
        DateTime(2026, 7, 15, 17),
        suggestedNudgeTime: null,
      );
      expect(cutoffResult.eligible, isTrue);
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligibility: cutoffResult,
          scheduledDay: '2026-07-14',
        ),
        SecondRehitNudgeSyncDecision.cancel,
      );
    });

    test('schedule then cancel clears marker and permits same-day reschedule', () {
      String? marker;
      DateTime? scheduledFor;

      var decision = secondRehitNudgeSyncDecision(
        enabled: true,
        eligibility: eligible,
        scheduledDay: marker,
      );
      var outcome = secondRehitNudgeMarkerTransition(
        decision: decision,
        eligibility: eligible,
        scheduledDay: marker,
        scheduledFor: scheduledFor,
      );
      marker = outcome.scheduledDay;
      scheduledFor = outcome.scheduledFor;
      expect(decision, SecondRehitNudgeSyncDecision.schedule);
      expect(marker, '2026-07-15');
      expect(scheduledFor, DateTime(2026, 7, 15, 15));

      final closed = closedAt(now);
      decision = secondRehitNudgeSyncDecision(
        enabled: true,
        eligibility: closed,
        scheduledDay: marker,
      );
      outcome = secondRehitNudgeMarkerTransition(
        decision: decision,
        eligibility: closed,
        scheduledDay: marker,
        scheduledFor: scheduledFor,
      );
      expect(decision, SecondRehitNudgeSyncDecision.cancel);
      expect(outcome.stateChanged, isTrue);
      marker = outcome.scheduledDay;
      scheduledFor = outcome.scheduledFor;
      expect(marker, isNull);
      expect(scheduledFor, isNull);

      decision = secondRehitNudgeSyncDecision(
        enabled: true,
        eligibility: eligible,
        scheduledDay: marker,
      );
      expect(decision, SecondRehitNudgeSyncDecision.schedule);
    });

    test('settings copy can explicitly clear the internal marker', () {
      const settings = UserSettings(
        secondRehitNudgeScheduledDay: '2026-07-15',
        secondRehitNudgeScheduledFor: null,
      );

      expect(
        settings
            .copyWith(clearSecondRehitNudgeScheduledDay: true)
            .secondRehitNudgeScheduledDay,
        isNull,
      );
      final withTarget = settings.copyWith(
        secondRehitNudgeScheduledFor: DateTime(2026, 7, 15, 15),
      );
      expect(
        withTarget
            .copyWith(clearSecondRehitNudgeScheduledDay: true)
            .secondRehitNudgeScheduledFor,
        isNull,
      );
    });

    test('failed platform cancellation retains the tracked marker', () {
      final closed = closedAt(now);
      final outcome = secondRehitNudgeMarkerTransition(
        decision: SecondRehitNudgeSyncDecision.cancel,
        eligibility: closed,
        scheduledDay: '2026-07-15',
        scheduledFor: DateTime(2026, 7, 15, 15),
        operationSucceeded: false,
      );

      expect(outcome.stateChanged, isFalse);
      expect(outcome.scheduledDay, '2026-07-15');
      expect(outcome.scheduledFor, DateTime(2026, 7, 15, 15));
    });

    test('post-target cancellation retains used-day state and blocks a second nudge', () {
      final target = DateTime(2026, 7, 15, 15);
      final closedAfterTarget = closedAt(target);
      final cancelOutcome = secondRehitNudgeMarkerTransition(
        decision: SecondRehitNudgeSyncDecision.cancel,
        eligibility: closedAfterTarget,
        scheduledDay: '2026-07-15',
        scheduledFor: target,
      );

      expect(cancelOutcome.stateChanged, isFalse);
      expect(cancelOutcome.scheduledDay, '2026-07-15');
      expect(cancelOutcome.scheduledFor, target);

      final eligibleAgain = eligibleAt(
        DateTime(2026, 7, 15, 16),
        suggestedNudgeTime: DateTime(2026, 7, 15, 19),
      );
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligibility: eligibleAgain,
          scheduledDay: cancelOutcome.scheduledDay,
        ),
        SecondRehitNudgeSyncDecision.keep,
      );
    });

    test('legacy day-only marker is retained as already used today', () {
      final outcome = secondRehitNudgeMarkerTransition(
        decision: SecondRehitNudgeSyncDecision.cancel,
        eligibility: closedAt(now),
        scheduledDay: '2026-07-15',
        scheduledFor: null,
      );

      expect(outcome.stateChanged, isFalse);
      expect(outcome.scheduledDay, '2026-07-15');
      expect(outcome.scheduledFor, isNull);
    });
  });

  group('rest-day REHIT reminder copy', () {
    test('claims a usual training time only when one was learned', () {
      expect(
        restDayRehitNudgeBodyFor(
          checkInMissing: false,
          slotSource: ScheduleSlotSource.weekdayHabit,
        ),
        contains('the time you usually train'),
      );
      expect(
        restDayRehitNudgeBodyFor(
          checkInMissing: false,
          slotSource: ScheduleSlotSource.overallHabit,
        ),
        contains('the time you usually train'),
      );
      expect(
        restDayRehitNudgeBodyFor(
          checkInMissing: false,
          slotSource: ScheduleSlotSource.fallback,
        ),
        isNot(contains('usually train')),
      );
      expect(
        restDayRehitNudgeBodyFor(checkInMissing: false, slotSource: null),
        isNot(contains('usually train')),
      );
    });

    test('asks for a check-in when readiness is unknown', () {
      expect(
        restDayRehitNudgeBodyFor(
          checkInMissing: true,
          slotSource: ScheduleSlotSource.weekdayHabit,
        ),
        contains('Check in first'),
      );
      expect(
        restDayRehitNudgeBodyFor(
          checkInMissing: false,
          slotSource: ScheduleSlotSource.weekdayHabit,
        ),
        isNot(contains('Check in first')),
      );
    });

    test('never asserts a duration the CAROL preset does not have', () {
      for (final missing in [true, false]) {
        for (final source in [
          ScheduleSlotSource.weekdayHabit,
          ScheduleSlotSource.fallback,
          null,
        ]) {
          final body = restDayRehitNudgeBodyFor(
            checkInMissing: missing,
            slotSource: source,
          );
          expect(body, isNot(contains('minute')));
          expect(body, contains('CAROL REHIT Intense'));
        }
      }
    });
  });

  group('the rest-day reminder shares the once-per-day gate', () {
    RestDayRehitResult result({
      required bool eligible,
      required DateTime observedAt,
      DateTime? suggestedNudgeTime,
    }) =>
        RestDayRehitResult(
          closedReasons: eligible
              ? const []
              : const [RestDayRehitClosedReason.trainingLoggedToday],
          observedAt: observedAt,
          suggestedNudgeTime: eligible ? suggestedNudgeTime : null,
          slotSource: eligible ? ScheduleSlotSource.weekdayHabit : null,
          checkInMissing: false,
        );

    final observedAt = DateTime(2026, 8, 3, 10);

    test('schedules once, then keeps the same day marker', () {
      final eligible = result(
        eligible: true,
        observedAt: observedAt,
        suggestedNudgeTime: DateTime(2026, 8, 3, 17),
      );
      expect(
        dailyNudgeSyncDecision(
          enabled: true,
          eligibility: eligible,
          scheduledDay: null,
        ),
        DailyNudgeSyncDecision.schedule,
      );
      final outcome = dailyNudgeMarkerTransition(
        decision: DailyNudgeSyncDecision.schedule,
        eligibility: eligible,
        scheduledDay: null,
        scheduledFor: null,
      );
      expect(outcome.stateChanged, isTrue);
      expect(outcome.scheduledDay, '2026-08-03');
      expect(outcome.scheduledFor, DateTime(2026, 8, 3, 17));
      expect(
        dailyNudgeSyncDecision(
          enabled: true,
          eligibility: eligible,
          scheduledDay: outcome.scheduledDay,
        ),
        DailyNudgeSyncDecision.keep,
      );
    });

    test('training logged later in the day cancels a pending reminder', () {
      final closed = result(eligible: false, observedAt: observedAt);
      expect(
        dailyNudgeSyncDecision(
          enabled: true,
          eligibility: closed,
          scheduledDay: '2026-08-03',
        ),
        DailyNudgeSyncDecision.cancel,
      );
      final outcome = dailyNudgeMarkerTransition(
        decision: DailyNudgeSyncDecision.cancel,
        eligibility: closed,
        scheduledDay: '2026-08-03',
        scheduledFor: DateTime(2026, 8, 3, 17),
      );
      expect(outcome.stateChanged, isTrue);
      expect(outcome.scheduledDay, isNull);
    });

    test('disabled always cancels', () {
      expect(
        dailyNudgeSyncDecision(
          enabled: false,
          eligibility: result(
            eligible: true,
            observedAt: observedAt,
            suggestedNudgeTime: DateTime(2026, 8, 3, 17),
          ),
          scheduledDay: null,
        ),
        DailyNudgeSyncDecision.cancel,
      );
    });
  });
}
