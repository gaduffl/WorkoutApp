import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/notifications/notification_service.dart';

void main() {
  test('morning REHIT eligibility schedules at 15:00 local', () {
    final now = DateTime(2026, 7, 15, 9);
    expect(secondRehitNudgeTime(now), DateTime(2026, 7, 15, 15));
  });

  test('16:00 REHIT eligibility schedules three hours later', () {
    final now = DateTime(2026, 7, 15, 16);
    expect(secondRehitNudgeTime(now), DateTime(2026, 7, 15, 19));
  });

  test('17:00 REHIT eligibility is too late for a nudge', () {
    final now = DateTime(2026, 7, 15, 17);
    expect(secondRehitNudgeTime(now), isNull);
  });

  group('once-per-local-day gate', () {
    final now = DateTime(2026, 7, 15, 10);

    test('disabled or ineligible always cancels', () {
      expect(
        secondRehitNudgeSyncDecision(
          enabled: false,
          eligible: true,
          now: now,
          scheduledDay: '2026-07-15',
        ),
        SecondRehitNudgeSyncDecision.cancel,
      );
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligible: false,
          now: now,
          scheduledDay: '2026-07-15',
        ),
        SecondRehitNudgeSyncDecision.cancel,
      );
    });

    test('an existing marker for today keeps the pending state untouched', () {
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligible: true,
          now: now,
          scheduledDay: '2026-07-15',
        ),
        SecondRehitNudgeSyncDecision.keep,
      );
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligible: true,
          now: DateTime(2026, 7, 15, 18),
          scheduledDay: '2026-07-15',
        ),
        SecondRehitNudgeSyncDecision.keep,
        reason: 'reopening after delivery must not create a second reminder',
      );
    });

    test('a prior-day marker allows one new schedule today', () {
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligible: true,
          now: now,
          scheduledDay: '2026-07-14',
        ),
        SecondRehitNudgeSyncDecision.schedule,
      );
    });

    test('a first sync at 17:00 cancels instead of scheduling too late', () {
      expect(
        secondRehitNudgeSyncDecision(
          enabled: true,
          eligible: true,
          now: DateTime(2026, 7, 15, 17),
          scheduledDay: '2026-07-14',
        ),
        SecondRehitNudgeSyncDecision.cancel,
      );
    });
  });
}
