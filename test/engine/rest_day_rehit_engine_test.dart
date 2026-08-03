import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/intensity_recovery_policy.dart';
import 'package:morningcoach/engine/rest_day_rehit_engine.dart';
import 'package:morningcoach/engine/schedule_fit_engine.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  const engine = RestDayRehitEngine();
  final now = DateTime(2026, 8, 3, 13);
  final slot = ScheduleSlot(
    at: DateTime(2026, 8, 3, 17),
    source: ScheduleSlotSource.weekdayHabit,
    sampleCount: 4,
  );

  RestDayRehitInput input({
    bool trainingLoggedToday = false,
    ReadinessBucket? readinessBucket = ReadinessBucket.green,
    bool illnessGuardActive = false,
    bool contraindicatingPainActive = false,
    bool painEscalationActive = false,
    bool deloadActive = false,
    bool intensityWithinTrailingWindow = false,
    bool rehitUnavailableDueToTravel = false,
    bool highIntensityTargetDue = true,
    ScheduleSlot? scheduleSlot,
    bool noSlot = false,
  }) =>
      RestDayRehitInput(
        trainingLoggedToday: trainingLoggedToday,
        readinessBucket: readinessBucket,
        illnessGuardActive: illnessGuardActive,
        contraindicatingPainActive: contraindicatingPainActive,
        painEscalationActive: painEscalationActive,
        deloadActive: deloadActive,
        intensityWithinTrailingWindow: intensityWithinTrailingWindow,
        rehitUnavailableDueToTravel: rehitUnavailableDueToTravel,
        highIntensityTargetDue: highIntensityTargetDue,
        scheduleSlot: noSlot ? null : (scheduleSlot ?? slot),
        nowLocal: now,
      );

  test('an untrained GREEN day with a slot is eligible', () {
    final result = engine.evaluate(input());
    expect(result.eligible, isTrue);
    expect(result.suggestedNudgeTime, DateTime(2026, 8, 3, 17));
    expect(result.slotSource, ScheduleSlotSource.weekdayHabit);
    expect(result.checkInMissing, isFalse);
  });

  test('a day with no check-in is still eligible but flagged as such', () {
    final result = engine.evaluate(input(readinessBucket: null));
    expect(result.eligible, isTrue);
    expect(result.checkInMissing, isTrue);
  });

  test('any training already logged today closes it', () {
    final result = engine.evaluate(input(trainingLoggedToday: true));
    expect(result.eligible, isFalse);
    expect(
      result.closedReasons,
      contains(RestDayRehitClosedReason.trainingLoggedToday),
    );
    expect(result.suggestedNudgeTime, isNull);
  });

  test('YELLOW and RED readiness close it', () {
    for (final bucket in [ReadinessBucket.yellow, ReadinessBucket.red]) {
      final result = engine.evaluate(input(readinessBucket: bucket));
      expect(
        result.closedReasons,
        contains(RestDayRehitClosedReason.readinessNotGreen),
        reason: bucket.name,
      );
    }
  });

  test('every hard safety gate closes it independently', () {
    final cases = <RestDayRehitClosedReason, RestDayRehitInput>{
      RestDayRehitClosedReason.illnessGuardActive:
          input(illnessGuardActive: true),
      RestDayRehitClosedReason.contraindicatingPainActive:
          input(contraindicatingPainActive: true),
      RestDayRehitClosedReason.painEscalationActive:
          input(painEscalationActive: true),
      RestDayRehitClosedReason.deloadActive: input(deloadActive: true),
      RestDayRehitClosedReason.intensityWithinTrailing48Hours:
          input(intensityWithinTrailingWindow: true),
      RestDayRehitClosedReason.rehitUnavailableDueToTravel:
          input(rehitUnavailableDueToTravel: true),
      RestDayRehitClosedReason.highIntensityTargetMet:
          input(highIntensityTargetDue: false),
    };
    cases.forEach((reason, value) {
      final result = engine.evaluate(value);
      expect(result.eligible, isFalse, reason: reason.name);
      expect(result.closedReasons, contains(reason));
    });
  });

  test('no fitting slot closes it without inventing a time', () {
    final result = engine.evaluate(input(noSlot: true));
    expect(
      result.closedReasons,
      contains(RestDayRehitClosedReason.noScheduleSlotToday),
    );
    expect(result.suggestedNudgeTime, isNull);
    expect(result.slotSource, isNull);
  });

  test('inputFromSafety mirrors the shared high-intensity gate', () {
    const safety = HighIntensitySafetyStatus(
      intensityRecoveryActive: true,
      contraindicatingPainActive: false,
      painEscalationActive: false,
      deloadActive: true,
      travelUnavailable: false,
    );
    final result = engine.evaluate(
      engine.inputFromSafety(
        safety: safety,
        trainingLoggedToday: false,
        readinessBucket: ReadinessBucket.green,
        illnessGuardActive: false,
        highIntensityTargetDue: true,
        scheduleSlot: slot,
        nowLocal: now,
      ),
    );
    expect(
      result.closedReasons,
      containsAll(const [
        RestDayRehitClosedReason.deloadActive,
        RestDayRehitClosedReason.intensityWithinTrailing48Hours,
      ]),
    );
  });

  group('hasTrainingOn', () {
    SessionLog logOn(DateTime day) => SessionLog(
          id: 'log-${day.toIso8601String()}',
          templateId: SessionTypeId.s1,
          tier: SessionTier.full,
          date: day,
          setLogs: const [],
          plannedWorkSets: 0,
          completedWorkSets: 0,
          durationMinutes: 30,
          countsAs: const {FloorCategory.strength},
        );

    test('matches by calendar day only', () {
      final logs = [logOn(DateTime(2026, 8, 2))];
      expect(
        RestDayRehitEngine.hasTrainingOn(logs, DateTime(2026, 8, 2, 23, 59)),
        isTrue,
      );
      expect(
        RestDayRehitEngine.hasTrainingOn(logs, DateTime(2026, 8, 3, 0, 1)),
        isFalse,
      );
    });
  });
}
