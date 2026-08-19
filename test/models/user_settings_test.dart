import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/models/user_settings.dart';

void main() {
  test('nullable copyWith values retain existing optional settings', () {
    const settings = UserSettings(
      age: 40,
      hrMaxOverride: 190,
      anthropicApiKey: 'secret',
    );

    final retained = settings.copyWith(
      hrMaxOverride: null,
      anthropicApiKey: null,
    );

    expect(retained.hrMaxOverride, 190);
    expect(retained.anthropicApiKey, 'secret');
  });

  test('explicit clear flags restore derived HRmax and remove the API key', () {
    const settings = UserSettings(
      age: 40,
      hrMaxOverride: 190,
      anthropicApiKey: 'secret',
    );

    final cleared = settings.copyWith(
      age: 50,
      clearHrMaxOverride: true,
      clearAnthropicApiKey: true,
    );

    expect(cleared.hrMaxOverride, isNull);
    expect(cleared.hrMax, 208 - 0.7 * 50);
    expect(cleared.anthropicApiKey, isNull);
  });

  test('classic heatmap defaults off and copyWith preserves or changes it', () {
    const settings = UserSettings();

    expect(settings.classicHeatmap, isFalse);
    expect(settings.copyWith().classicHeatmap, isFalse);
    expect(settings.copyWith(classicHeatmap: true).classicHeatmap, isTrue);
  });
}
