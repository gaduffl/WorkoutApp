import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/engine/fallback_templates.dart';
import 'package:morningcoach/models/rule_key.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  test('CAROL REHIT rules describe the fixed bike preset without a made-up duration', () {
    const rules = <RuleKey>[
      RuleKey.rehitFallbackDue,
      RuleKey.s7TimeSub,
      RuleKey.s7SecondSessionOffer,
      RuleKey.yellow4x4ToRehit,
      RuleKey.timeCompress60_35,
    ];

    for (final language in AppLanguage.values) {
      for (final key in rules) {
        final copy = fallbackText(FiredRule(key), language);
        expect(copy, contains('CAROL REHIT Intense'), reason: '$key $language');
        expect(copy, isNot(contains('10-min')), reason: '$key $language');
        expect(copy, isNot(contains('10 min')), reason: '$key $language');
        expect(copy, isNot(contains('10-Minuten')), reason: '$key $language');
      }
    }

    expect(
      fallbackText(const FiredRule(RuleKey.s7TimeSub), AppLanguage.en),
      contains('bike-guided'),
    );
    expect(
      fallbackText(const FiredRule(RuleKey.s7TimeSub), AppLanguage.de),
      contains('vom CAROL-Bike geführte'),
    );
  });

  test('sharp-pain narration does not invent a named substitute', () {
    const rule = FiredRule(
      RuleKey.painSubSharp,
      pattern: 'squat',
      params: {'substitute': 'Bridge hamstring curl'},
    );

    final english = fallbackText(rule, AppLanguage.en);
    final german = fallbackText(rule, AppLanguage.de);

    expect(english, contains('modified, replaced, or removed'));
    expect(english, isNot(contains('Bridge hamstring curl')));
    expect(german, contains('angepasst, ersetzt oder entfernt'));
    expect(german, isNot(contains('Bridge hamstring curl')));
  });
}
