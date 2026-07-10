import 'dart:math' as math;

import '../models/decision_trace.dart';
import '../models/recovery_snapshot.dart';

class ReadinessResult {
  final ReadinessBucket bucket;
  final double compositeScore;
  final double? hrvZToday;
  final double? hrvTrend3;
  final double? rhrDev;
  final int? sleepScore;
  final List<String> inputsMissing;
  final bool illnessGuardFired;
  final bool subjOverrideDownFired;
  final bool subjOverrideUpBlockedFired;

  const ReadinessResult({
    required this.bucket,
    required this.compositeScore,
    required this.hrvZToday,
    required this.hrvTrend3,
    required this.rhrDev,
    required this.sleepScore,
    required this.inputsMissing,
    required this.illnessGuardFired,
    required this.subjOverrideDownFired,
    required this.subjOverrideUpBlockedFired,
  });
}

/// §4: readiness computation. Pure function over a caller-supplied history
/// window - no hidden clock or I/O.
class ReadinessEngine {
  const ReadinessEngine();

  static const int minQualifyingNights = 14;
  static const int baselineWindowDays = 60;

  double _clampedLinear(double x, double x0, double y0, double x1, double y1) {
    if (x1 == x0) return y0;
    final t = ((x - x0) / (x1 - x0)).clamp(0.0, 1.0);
    return y0 + t * (y1 - y0);
  }

  DateTime _day(DateTime date) => DateTime(date.year, date.month, date.day);

  List<RecoverySnapshot> _windowed(List<RecoverySnapshot> history, DateTime asOf, int days) {
    final end = _day(asOf);
    final cutoff = end.subtract(Duration(days: days - 1));
    return history.where((s) {
      final date = _day(s.date);
      return !date.isBefore(cutoff) && !date.isAfter(end);
    }).toList();
  }

  /// The baseline is formed only from nights before [asOf]. The controller
  /// persists today's explicit sample before loading history, so allowing the
  /// as-of day into this window would make the observation influence the mean
  /// and standard deviation used to score itself.
  List<RecoverySnapshot> _baselineWindow(List<RecoverySnapshot> history, DateTime asOf) {
    final endExclusive = _day(asOf);
    final cutoff = endExclusive.subtract(const Duration(days: baselineWindowDays));
    return history.where((s) {
      final date = _day(s.date);
      return !date.isBefore(cutoff) && date.isBefore(endExclusive);
    }).toList();
  }

  (double, double)? _hrvBaselineAndSd(List<RecoverySnapshot> window) {
    final values = window.map((s) => s.hrvRmssd).whereType<double>().toList();
    if (values.length < minQualifyingNights) return null;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / values.length;
    final sd = variance <= 0 ? 0.0001 : math.sqrt(variance);
    return (mean, sd);
  }

  double? _rhrBaseline(List<RecoverySnapshot> window) {
    final values = window.map((s) => s.restingHr).whereType<double>().toList();
    if (values.length < minQualifyingNights) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  ReadinessResult compute({
    required int subjective,
    required RecoverySnapshot? today,
    required List<RecoverySnapshot> history,
    required DateTime asOf,
  }) {
    final window = _baselineWindow(history, asOf);
    final baselineStats = _hrvBaselineAndSd(window);
    final rhrBaseline = _rhrBaseline(window);

    final hrvMissing = baselineStats == null || today?.hrvRmssd == null;
    final rhrMissing = rhrBaseline == null || today?.restingHr == null;
    final sleepMissing = today?.sleepScore == null;

    double? hrvZToday;
    double? hrvTrend3;
    double? rhrDev;

    if (!hrvMissing) {
      final mean = baselineStats.$1;
      final sd = baselineStats.$2 <= 0 ? 0.0001 : baselineStats.$2;
      hrvZToday = (today!.hrvRmssd! - mean) / sd;

      // Last 3 nights = today (explicit z above) + the two prior nights
      // from history - `today` need not also appear inside `history`.
      final priorTwo = _windowed(history, asOf.subtract(const Duration(days: 1)), 2);
      final priorZs = priorTwo.map((s) => s.hrvRmssd).whereType<double>().map((v) => (v - mean) / sd);
      final zs = [hrvZToday, ...priorZs];
      hrvTrend3 = zs.reduce((a, b) => a + b) / zs.length;
    }
    if (!rhrMissing) {
      rhrDev = today!.restingHr! - rhrBaseline;
    }

    final inputsMissing = <String>[];
    if (hrvMissing) inputsMissing.add('hrv');
    if (rhrMissing) inputsMissing.add('rhr');
    if (sleepMissing) inputsMissing.add('sleep');

    // §4.2 composite with missing-input renormalization.
    final subjectiveMapped = _clampedLinear(subjective.toDouble(), 1, 0, 5, 100);
    final hrvMapped = hrvTrend3 == null ? null : _clampedLinear(hrvTrend3, -1.5, 0, 0.5, 100);
    final sleepMapped = sleepMissing ? null : today!.sleepScore!.toDouble().clamp(0, 100);
    final rhrMapped = rhrDev == null ? null : _clampedLinear(rhrDev, 0, 100, 5, 0);

    const weights = {'subjective': 0.4, 'hrv': 0.3, 'sleep': 0.2, 'rhr': 0.1};
    final values = {'subjective': subjectiveMapped, 'hrv': hrvMapped, 'sleep': sleepMapped, 'rhr': rhrMapped};
    final present = values.entries.where((e) => e.value != null).toList();
    final totalWeight = present.fold(0.0, (s, e) => s + weights[e.key]!);
    final composite = totalWeight == 0
        ? subjectiveMapped
        : present.fold(0.0, (s, e) => s + weights[e.key]! * e.value!) / totalWeight;

    var bucket = composite >= 65
        ? ReadinessBucket.green
        : (composite >= 40 ? ReadinessBucket.yellow : ReadinessBucket.red);

    var subjDown = false;
    var subjUpBlocked = false;

    // Subjective override up: subjective >=4 with objective YELLOW -> GREEN
    // unless HRV_trend3 <= -1.5 (persistent suppression blocks the upgrade).
    if (subjective >= 4 && bucket == ReadinessBucket.yellow) {
      if (hrvTrend3 != null && hrvTrend3 <= -1.5) {
        subjUpBlocked = true;
      } else {
        bucket = ReadinessBucket.green;
      }
    }

    // Subjective override down: <=2 caps at YELLOW (never upgrades RED);
    // ==1 forces RED outright. The human always wins downward.
    if (subjective == 1) {
      if (bucket != ReadinessBucket.red) subjDown = true;
      bucket = ReadinessBucket.red;
    } else if (subjective <= 2) {
      if (bucket == ReadinessBucket.green) {
        subjDown = true;
        bucket = ReadinessBucket.yellow;
      }
    }

    // Illness guard: highest precedence, forces RED regardless of the above.
    final illnessGuard = !hrvMissing && !rhrMissing && rhrDev! >= 7 && hrvZToday! <= -2;
    if (illnessGuard) {
      bucket = ReadinessBucket.red;
    }

    return ReadinessResult(
      bucket: bucket,
      compositeScore: composite,
      hrvZToday: hrvZToday,
      hrvTrend3: hrvTrend3,
      rhrDev: rhrDev,
      sleepScore: today?.sleepScore,
      inputsMissing: inputsMissing,
      illnessGuardFired: illnessGuard,
      subjOverrideDownFired: subjDown,
      subjOverrideUpBlockedFired: subjUpBlocked,
    );
  }
}
