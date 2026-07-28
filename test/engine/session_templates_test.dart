import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/session_templates.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  test('all strength families are feasible in the hard 20-minute window', () {
    for (final id in [
      SessionTypeId.s1,
      SessionTypeId.s2,
      SessionTypeId.s4,
      SessionTypeId.s5,
    ]) {
      expect(sessionTypes[id]!.minDurationMin, lessThanOrEqualTo(20));
    }
  });

  test('duration metadata matches executable hard-window contracts', () {
    expect(sessionTypes[SessionTypeId.s5]!.minDurationMin, 20);
    expect(sessionTypes[SessionTypeId.s3]!.fullDurationMin, 30);
    expect(sessionTypes[SessionTypeId.s3]!.minDurationMin, isNull);
    expect(sessionTypes[SessionTypeId.s7]!.fullDurationMin, 9);
    expect(sessionTypes[SessionTypeId.s7]!.minDurationMin, 5);
    expect(
      sessionTypes[SessionTypeId.s6]!.minDurationMin,
      30,
      reason: 'S6 metadata is its base-credit threshold; 20m is recovery only',
    );
  });

  test('every template with a compressed tier prescribes actual work sets', () {
    for (final entry in sessionTemplates.entries) {
      final template = entry.value;
      if (template.isCardioOnly) continue;
      final slots = template.slotsForTier(SessionTier.compressed);
      if (slots.isEmpty) continue; // no slots at all is a separate concern
      for (final (pattern, isCompound, _) in slots) {
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
    for (final (_, isCompound, _) in slots) {
      expect(template.setsFor(isCompound, SessionTier.compressed), 2);
    }
  });

  test('§2.1: S5 trains direct arm work (curls/raises/triceps), not push/pull proxies', () {
    final template = sessionTemplates[SessionTypeId.s5]!;
    final full = template.slotsForTier(SessionTier.full);
    final names = full.map((s) => s.$3?.name).whereType<String>().toList();
    expect(names, containsAll(['Alternating DB curl', 'Alternating lateral raise', 'Weighted dip (DB between feet)']));
    // compressed keeps the first two named accessories as the hard pair
    final compressed = template.slotsForTier(SessionTier.compressed);
    expect(compressed.length, 2);
    expect(compressed.first.$3?.name, 'Alternating DB curl');
  });
}
