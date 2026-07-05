import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/equipment_engine.dart';
import 'package:morningcoach/models/equipment.dart';

void main() {
  const engine = EquipmentEngine();
  const cfg = EquipmentConfig();
  const cfgUneven = EquipmentConfig(unevenPairModeEnabled: true);

  group('§2.6 derived achievable-load sets', () {
    test('single-DB union matches the spec list exactly', () {
      expect(
        engine.singleDbAchievableTotals(cfg),
        [6, 9, 10, 12, 15, 18, 20, 21, 24, 25, 30, 35, 40, 45, 50],
      );
    });

    test('matched small pair totals', () {
      const smallOnly = EquipmentConfig(blocks: [smallPowerBlock]);
      expect(engine.matchedTwoDbTotals(smallOnly), [12, 18, 24, 30, 36, 42, 48]);
    });

    test('combined 2-DB total set (matched pairs only) matches the spec list', () {
      expect(
        engine.matchedTwoDbTotals(cfg),
        [12, 18, 20, 24, 30, 36, 40, 42, 48, 50, 60, 70, 80, 90, 100],
      );
    });

    test('uneven totals include the heavy-range fillers from the spec (55-95)', () {
      final uneven = engine.unevenTwoDbTotals(cfg);
      expect(uneven, containsAll([55, 65, 75, 85, 95]));
    });

    test('uneven totals include the below-50 fillers named in the spec (39,44,45,46,49)', () {
      final uneven = engine.unevenTwoDbTotals(cfg);
      expect(uneven, containsAll([39, 44, 45, 46, 49]));
    });
  });

  group('§2.6 rule 1: pair-family switching', () {
    test('48 (2x24 small) steps up to 50 (2x25 large)', () {
      final matched = engine.matchedTwoDbTotals(cfg);
      expect(engine.nextAchievableAbove(48, matched), 50);
    });

    test('describeLoad names the actual blocks', () {
      final at48 = engine.resolveTwoDb(48, cfg, allowUneven: false);
      expect(engine.describeLoad(at48, cfg), '2x small @ 24 lb');
      final at50 = engine.resolveTwoDb(50, cfg, allowUneven: false);
      expect(engine.describeLoad(at50, cfg), '2x large @ 25 lb');
    });
  });

  group('§2.6 rule 2: increment guard', () {
    test('30 -> 40 press jump is +33%, exceeds the 10% guard', () {
      expect(engine.incrementExceedsGuard(30, 40), isTrue);
    });

    test('45 -> 50 single-DB jump is +11%, exceeds the 10% guard', () {
      expect(engine.incrementExceedsGuard(45, 50), isTrue);
    });

    test('a <=10% jump does not trigger the guard', () {
      expect(engine.incrementExceedsGuard(100, 109), isFalse);
    });
  });

  group('§2.6 rule 3: uneven-pair mode', () {
    test('uneven totals are absent unless the mode is enabled', () {
      expect(engine.twoDbAchievableTotals(cfg, allowUneven: true), isNot(contains(55)));
      expect(engine.twoDbAchievableTotals(cfgUneven, allowUneven: true), contains(55));
    });

    test('disallowed for unilateral exercises even when the mode is on', () {
      expect(engine.twoDbAchievableTotals(cfgUneven, allowUneven: false), isNot(contains(55)));
    });

    test('resolves the closest-diff uneven pair for a total', () {
      final resolved = engine.resolveTwoDb(49, cfgUneven, allowUneven: true);
      expect(resolved.uneven, isTrue);
      expect({resolved.perDumbbellA, resolved.perDumbbellB}, {24, 25});
    });
  });

  group('§2.6 rule 4: concrete rounding assertions', () {
    test('60% deload of a 90-lb DB deadlift (54) rounds down to 50 in matched-only mode', () {
      final matched = engine.matchedTwoDbTotals(cfg);
      expect(engine.roundDownToAchievable(54, matched), 50);
    });

    test('24+25=49 is a valid uneven-mode floor target below 54', () {
      final unevenSet = engine.unevenTwoDbTotals(cfg);
      expect(unevenSet, contains(49));
      final resolved = engine.resolveTwoDb(49, cfgUneven, allowUneven: true);
      expect(resolved.perDumbbellA + (resolved.perDumbbellB ?? 0), 49);
    });

    test('90% detraining re-entry from 100 is an exact match', () {
      final matched = engine.matchedTwoDbTotals(cfg);
      expect(engine.roundDownToAchievable(100 * 0.9, matched), 90);
    });
  });
}
