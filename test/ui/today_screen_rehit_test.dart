import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/ui/screens/today_screen.dart';

void main() {
  SessionPlan plan(SessionTypeId id, SessionTier tier) => SessionPlan(
        sessionId: id,
        sessionName: 'Test',
        tier: tier,
        exercises: const [],
        estimatedDurationMin: 60,
      );

  test('optional REHIT hint matches the logger eligibility and copy', () {
    expect(
      optionalRehitFinisherHint(plan(SessionTypeId.s2, SessionTier.extended)),
      optionalRehitFinisherMessage,
    );
    expect(
      optionalRehitFinisherMessage,
      'Optional finisher: 8-min REHIT after the strength work. Completing it earns intensity credit.',
    );
    expect(
      optionalRehitFinisherHint(plan(SessionTypeId.s2, SessionTier.full)),
      isNull,
    );
    expect(
      optionalRehitFinisherHint(plan(SessionTypeId.s1, SessionTier.extended)),
      isNull,
    );
  });
}
