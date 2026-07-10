import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/pain_engine.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';

void main() {
  const engine = PainEngine();
  final today = DateTime(2026, 1, 20);

  group('§7.1 / §5 worked example: sharp lower back', () {
    test('hinge is substituted with bridge hamstring curl', () {
      final action = engine.resolve(BodyRegion.lowerBack, PainSeverity.sharp, MovementPattern.hinge);
      expect(action.kind, PainActionKind.substituteNamed);
      expect(action.substitute, bridgeHamstringCurl);
    });

    test('squat load is capped at -1 increment (not substituted)', () {
      final action = engine.resolve(BodyRegion.lowerBack, PainSeverity.sharp, MovementPattern.squat);
      expect(action.kind, PainActionKind.reduceLoadOne);
    });
  });

  test('sharp knee pain removes the squat pattern entirely', () {
    final action = engine.resolve(BodyRegion.kneeLeft, PainSeverity.sharp, MovementPattern.squat);
    expect(action.kind, PainActionKind.removePattern);
  });

  test('sharp hip pain has no per-exercise action - it is a session-level swap', () {
    final action = engine.resolve(BodyRegion.hip, PainSeverity.sharp, MovementPattern.squat);
    expect(action.kind, PainActionKind.none);
    expect(engine.hipSharpActive([PainFlag(region: BodyRegion.hip, severity: PainSeverity.sharp, flaggedDate: today)]), isTrue);
  });

  group('§7.2 escalation rule', () {
    test('sharp flag persisting > 7 days escalates', () {
      final flag = PainFlag(region: BodyRegion.lowerBack, severity: PainSeverity.sharp, flaggedDate: today.subtract(const Duration(days: 8)));
      expect(engine.isEscalated(flag, today), isTrue);
    });

    test('radiating/numbness/tingling tags escalate immediately regardless of duration', () {
      final flag = PainFlag(
        region: BodyRegion.lowerBack,
        severity: PainSeverity.mild,
        flaggedDate: today,
        tags: const {PainTag.tingling},
      );
      expect(engine.isEscalated(flag, today), isTrue);
    });
  });

  group('§7.2 flag lifecycle', () {
    test('sharp flag offers the re-entry test only after 2 scheduled sessions', () {
      var state = ExerciseState(trackKey: 'hinge', pattern: MovementPattern.hinge, currentLoad: 90);
      final flag = PainFlag(region: BodyRegion.lowerBack, severity: PainSeverity.sharp, flaggedDate: today);

      state = engine.advanceFlagState(
        state,
        activeFlag: flag,
        patternScheduledToday: true,
        sessionRanPainFree: false,
        today: today,
      );
      expect(state.painReentryTestOffered, isFalse);

      state = engine.advanceFlagState(
        state,
        activeFlag: flag,
        patternScheduledToday: true,
        sessionRanPainFree: false,
        today: today.add(const Duration(days: 1)),
      );
      expect(state.painReentryTestOffered, isTrue);
      expect(state.prePainLoad, 90);
    });

    test('same-day recommendation recomputations increment the counter only once', () {
      var state = ExerciseState(
        trackKey: 'hinge',
        pattern: MovementPattern.hinge,
        currentLoad: 90,
      );
      final flag = PainFlag(
        region: BodyRegion.lowerBack,
        severity: PainSeverity.sharp,
        flaggedDate: today,
      );

      state = engine.advanceFlagState(
        state,
        activeFlag: flag,
        patternScheduledToday: true,
        sessionRanPainFree: false,
        today: today,
      );
      state = engine.advanceFlagState(
        state,
        activeFlag: flag,
        patternScheduledToday: true,
        sessionRanPainFree: false,
        today: today.add(const Duration(hours: 8)),
      );

      expect(state.sessionsScheduledWhileFlagged, 1);
      expect(state.painReentryTestOffered, isFalse);
      expect(state.lastPainScheduledDate, DateTime(2026, 1, 20));
    });

    test('mild flag decays after 1 pain-free session', () {
      var state = ExerciseState(trackKey: 'squat', pattern: MovementPattern.squat);
      final flag = PainFlag(region: BodyRegion.kneeLeft, severity: PainSeverity.mild, flaggedDate: today);
      state = engine.advanceFlagState(
        state,
        activeFlag: flag,
        patternScheduledToday: true,
        sessionRanPainFree: false,
        today: today,
      );
      expect(state.painFrozen, isTrue);

      state = engine.advanceFlagState(
        state,
        activeFlag: null,
        patternScheduledToday: true,
        sessionRanPainFree: true,
        today: today.add(const Duration(days: 1)),
      );
      expect(state.painFrozen, isFalse);
    });
  });
}
