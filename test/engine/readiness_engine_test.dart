import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/readiness_engine.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';

void main() {
  const engine = ReadinessEngine();
  final today = DateTime(2026, 1, 20);

  List<RecoverySnapshot> baselineHistory({required double hrvMean, required double rhrMean, int nights = 20}) {
    return List.generate(
      nights,
      (i) => RecoverySnapshot(
        date: today.subtract(Duration(days: i + 1)),
        hrvRmssd: hrvMean,
        restingHr: rhrMean,
        sleepScore: 80,
      ),
    );
  }

  /// A history with enough HRV variance (alternating 40/60, mean 50, sd 10)
  /// that a strongly positive HRV trend and near-perfect sleep/RHR are all
  /// simultaneously achievable - used to isolate the subjective overrides
  /// from the objective composite (§4.3).
  List<RecoverySnapshot> maxRecoveryHistory() {
    return List.generate(20, (i) {
      final day = i + 1;
      return RecoverySnapshot(
        date: today.subtract(Duration(days: day)),
        hrvRmssd: day.isEven ? 60 : 40,
        restingHr: 60,
        sleepScore: 80,
      );
    });
  }

  group('§4.2 missing-input renormalization', () {
    test('never imputes a neutral value for missing HRV', () {
      final history = <RecoverySnapshot>[]; // < 14 nights -> HRV & RHR both "missing"
      final result = engine.compute(
        subjective: 5,
        today: RecoverySnapshot(date: today, sleepScore: 100),
        history: history,
        asOf: today,
      );
      expect(result.inputsMissing, containsAll(['hrv', 'rhr']));
      // Renormalized: (0.4*100 + 0.2*100) / 0.6 = 100, NOT the lower value a
      // naive neutral-hrv (z=0 -> 50) imputation would produce ((.4*100+.3*50+.2*100)/1=85).
      expect(result.compositeScore, closeTo(100, 0.01));
      expect(result.bucket, ReadinessBucket.green);
    });

    test('sufficient HRV/RHR history is used once >=14 qualifying nights exist', () {
      final history = baselineHistory(hrvMean: 50, rhrMean: 60, nights: 20);
      final result = engine.compute(
        subjective: 3,
        today: RecoverySnapshot(date: today, hrvRmssd: 50, restingHr: 60, sleepScore: 80),
        history: history,
        asOf: today,
      );
      expect(result.inputsMissing, isEmpty);
      expect(result.hrvZToday, closeTo(0, 0.5));
    });

    test("today's persisted sample is excluded from its own HRV/RHR baselines", () {
      final prior = List.generate(
        20,
        (i) => RecoverySnapshot(
          date: today.subtract(Duration(days: i + 1)),
          hrvRmssd: i.isEven ? 40 : 60, // mean 50, population SD 10
          restingHr: 60,
          sleepScore: 80,
        ),
      );
      final extremeToday = RecoverySnapshot(
        date: today,
        hrvRmssd: 100,
        restingHr: 90,
        sleepScore: 80,
      );
      final result = engine.compute(
        subjective: 3,
        today: extremeToday,
        // Mirrors Repository.loadRecoverySnapshotsSince after today's
        // snapshot has already been saved.
        history: [...prior, extremeToday],
        asOf: today,
      );

      expect(result.hrvZToday, closeTo(5, 0.0001));
      expect(result.rhrDev, closeTo(30, 0.0001));
    });
  });

  group('§4.3 buckets & overrides', () {
    test('illness guard forces RED regardless of everything else', () {
      final history = baselineHistory(hrvMean: 50, rhrMean: 60, nights: 20);
      final result = engine.compute(
        subjective: 5,
        today: RecoverySnapshot(date: today, hrvRmssd: 20, restingHr: 70, sleepScore: 100),
        history: history,
        asOf: today,
      );
      expect(result.illnessGuardFired, isTrue);
      expect(result.bucket, ReadinessBucket.red);
    });

    test('subjective == 1 forces RED even when the objective composite alone would be YELLOW', () {
      final history = maxRecoveryHistory();
      // subjective=1 maps to 0, so even with everything else maxed the
      // objective composite tops out at 0.3+0.2+0.1 = 0.6 * 100 = 60 (YELLOW).
      final result = engine.compute(
        subjective: 1,
        today: RecoverySnapshot(date: today, hrvRmssd: 70, restingHr: 55, sleepScore: 100),
        history: history,
        asOf: today,
      );
      expect(result.subjOverrideDownFired, isTrue);
      expect(result.bucket, ReadinessBucket.red);
    });

    test('subjective <= 2 caps an objective GREEN at YELLOW but never upgrades RED', () {
      final history = maxRecoveryHistory();
      final result = engine.compute(
        subjective: 2,
        today: RecoverySnapshot(date: today, hrvRmssd: 70, restingHr: 55, sleepScore: 100),
        history: history,
        asOf: today,
      );
      expect(result.subjOverrideDownFired, isTrue);
      expect(result.bucket, ReadinessBucket.yellow);
    });

    test('subjective >= 4 lifts objective YELLOW to GREEN unless HRV trend blocks it', () {
      // subjective alone maps to 100 but sleep=20 pulls composite into YELLOW.
      final lifted = engine.compute(
        subjective: 4,
        today: RecoverySnapshot(date: today, sleepScore: 20),
        history: const [],
        asOf: today,
      );
      expect(lifted.bucket, ReadinessBucket.green);
    });

    test('persistent low HRV trend blocks the subjective up-override', () {
      final history = baselineHistory(hrvMean: 50, rhrMean: 60, nights: 20);
      final blocked = engine.compute(
        subjective: 4,
        today: RecoverySnapshot(date: today, hrvRmssd: 20, restingHr: 60, sleepScore: 20),
        history: history,
        asOf: today,
      );
      expect(blocked.subjOverrideUpBlockedFired, isTrue);
      expect(blocked.bucket, ReadinessBucket.yellow);
    });
  });
}
