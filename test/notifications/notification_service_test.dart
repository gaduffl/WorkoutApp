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
}
