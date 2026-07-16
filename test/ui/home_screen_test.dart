import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/ui/screens/home_screen.dart';

void main() {
  test('home copy treats a partial workout as a saved attempt', () {
    expect(
      homeTodayStatus(
        hasTrace: true,
        sessionLogged: true,
        sessionDone: false,
      ),
      "Today's workout attempt is saved.",
    );
    expect(
      homeTodayActionLabel(
        hasTrace: true,
        sessionLogged: true,
        sessionDone: false,
      ),
      "View today's summary",
    );
  });

  test('home copy preserves check-in, ready, and completed states', () {
    expect(
      homeTodayStatus(
        hasTrace: false,
        sessionLogged: false,
        sessionDone: false,
      ),
      'No check-in yet today.',
    );
    expect(
      homeTodayActionLabel(
        hasTrace: false,
        sessionLogged: false,
        sessionDone: false,
      ),
      'Morning check-in',
    );

    expect(
      homeTodayStatus(
        hasTrace: true,
        sessionLogged: false,
        sessionDone: false,
      ),
      "Today's plan is ready.",
    );
    expect(
      homeTodayActionLabel(
        hasTrace: true,
        sessionLogged: false,
        sessionDone: false,
      ),
      "View today's plan",
    );

    expect(
      homeTodayStatus(
        hasTrace: true,
        sessionLogged: true,
        sessionDone: true,
      ),
      "Today's session is done ✅",
    );
    expect(
      homeTodayActionLabel(
        hasTrace: true,
        sessionLogged: true,
        sessionDone: true,
      ),
      "View today's summary",
    );
  });
}
