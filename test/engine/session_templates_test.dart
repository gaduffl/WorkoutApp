import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/session_templates.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  test('every template with a compressed tier prescribes actual work sets', () {
    for (final entry in sessionTemplates.entries) {
      final template = entry.value;
      if (template.isCardioOnly) continue;
      final slots = template.slotsForTier(SessionTier.compressed);
      if (slots.isEmpty) continue; // no slots at all is a separate concern
      for (final (pattern, isCompound) in slots) {
        final sets = template.setsFor(isCompound, SessionTier.compressed);
        expect(sets, greaterThan(0),
            reason: '${entry.key} compressed-tier slot for $pattern prescribed 0 sets');
      }
    }
  });

  test('§2.5 regression: S5 (no compound-bucketed patterns) still gets 2 sets at compressed tier', () {
    final template = sessionTemplates[SessionTypeId.s5]!;
    final slots = template.slotsForTier(SessionTier.compressed);
    expect(slots, isNotEmpty);
    for (final (_, isCompound) in slots) {
      expect(template.setsFor(isCompound, SessionTier.compressed), 2);
    }
  });
}
