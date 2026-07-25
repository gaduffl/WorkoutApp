import 'dart:math' as math;

import '../models/equipment.dart';

/// A resolved load: the total plus which physical dumbbell(s) produce it,
/// per §2.5 load semantics and §2.6 rule 1 (display must name the blocks).
class ResolvedLoad {
  final double total;
  final double perDumbbellA;
  final double? perDumbbellB;
  final bool uneven;

  const ResolvedLoad({
    required this.total,
    required this.perDumbbellA,
    this.perDumbbellB,
    this.uneven = false,
  });

  bool get isSingleDb => perDumbbellB == null;
}

/// §2.6: derives achievable load sets from the equipment table, applies
/// rounding, the increment guard, and pair-family/uneven-pair display naming.
/// Pure and deterministic - every method takes its config explicitly.
class EquipmentEngine {
  const EquipmentEngine();

  static const double unevenMaxDiff = 5;
  static const double incrementGuardFraction = 0.10;

  List<double> _sortedUnique(Iterable<double> values) {
    final set = values.toSet().toList()..sort();
    return set;
  }

  /// Union of every block's per-dumbbell steps - also the single-DB
  /// achievable total set (§2.6: single-DB total = that dumbbell's weight).
  List<double> allPerDumbbellSteps(EquipmentConfig cfg) {
    return _sortedUnique(cfg.blocks.expand((b) => b.perDumbbellSteps));
  }

  List<double> singleDbAchievableTotals(EquipmentConfig cfg) => allPerDumbbellSteps(cfg);

  List<double> matchedTwoDbTotals(EquipmentConfig cfg) {
    return _sortedUnique(cfg.blocks.expand((b) => b.perDumbbellSteps.map((s) => s * 2)));
  }

  /// Uneven totals: any two achievable per-dumbbell weights (same or
  /// different block) with |a - b| <= 5 lb, a != b (§2.6 rule 3).
  List<double> unevenTwoDbTotals(EquipmentConfig cfg) {
    final steps = allPerDumbbellSteps(cfg);
    final totals = <double>{};
    for (var i = 0; i < steps.length; i++) {
      for (var j = i + 1; j < steps.length; j++) {
        final diff = (steps[j] - steps[i]).abs();
        if (diff > 0 && diff <= unevenMaxDiff) {
          totals.add(steps[i] + steps[j]);
        }
      }
    }
    return _sortedUnique(totals);
  }

  /// The achievable total set for a 2-DB exercise, honoring uneven-pair
  /// mode when enabled and permitted for this exercise.
  List<double> twoDbAchievableTotals(EquipmentConfig cfg, {required bool allowUneven}) {
    final matched = matchedTwoDbTotals(cfg);
    if (!allowUneven || !cfg.unevenPairModeEnabled) return matched;
    return _sortedUnique([...matched, ...unevenTwoDbTotals(cfg)]);
  }

  /// §2.5: "one increment" = the next achievable total above/below current.
  double roundDownToAchievable(double value, List<double> achievableSorted) {
    if (achievableSorted.isEmpty) return value;
    double best = achievableSorted.first;
    for (final a in achievableSorted) {
      if (a <= value) {
        best = a;
      } else {
        break;
      }
    }
    return best;
  }

  double nextAchievableAbove(double current, List<double> achievableSorted) {
    for (final a in achievableSorted) {
      if (a > current) return a;
    }
    return current;
  }

  double nextAchievableBelow(double current, List<double> achievableSorted) {
    double best = current;
    for (final a in achievableSorted) {
      if (a < current) {
        best = a;
      } else {
        break;
      }
    }
    return best;
  }

  /// §2.6 rule 2: guard fires when the next achievable total exceeds the
  /// current load by more than 10%.
  bool incrementExceedsGuard(double currentLoad, double nextLoad) {
    if (currentLoad <= 0) return false;
    return (nextLoad - currentLoad) / currentLoad > incrementGuardFraction;
  }

  /// Resolves a single-DB total to the physical dumbbell (picks the
  /// smallest block that offers the weight, so light single-DB work stays
  /// on the fine-grained small block where possible).
  ResolvedLoad resolveSingleDb(double total, EquipmentConfig cfg) {
    return ResolvedLoad(total: total, perDumbbellA: total);
  }

  /// Resolves a 2-DB total to a matched pair if possible, otherwise (when
  /// uneven mode is enabled) to the closest-matched uneven pair.
  ResolvedLoad resolveTwoDb(double total, EquipmentConfig cfg, {required bool allowUneven}) {
    final steps = allPerDumbbellSteps(cfg);
    if (total % 2 == 0 && steps.contains(total / 2)) {
      final half = total / 2;
      return ResolvedLoad(total: total, perDumbbellA: half, perDumbbellB: half);
    }
    if (allowUneven && cfg.unevenPairModeEnabled) {
      (double, double)? best;
      double bestDiff = double.infinity;
      for (final a in steps) {
        final b = total - a;
        if (b < a || !steps.contains(b)) continue;
        final diff = b - a;
        if (diff > 0 && diff <= unevenMaxDiff && diff < bestDiff) {
          bestDiff = diff;
          best = (a, b);
        }
      }
      if (best != null) {
        return ResolvedLoad(total: total, perDumbbellA: best.$1, perDumbbellB: best.$2, uneven: true);
      }
    }
    // Fallback: nearest matched pair below the target.
    final matched = matchedTwoDbTotals(cfg);
    final rounded = roundDownToAchievable(total, matched);
    final half = rounded / 2;
    return ResolvedLoad(total: rounded, perDumbbellA: half, perDumbbellB: half);
  }

  String _blockLabelFor(double perDumbbellWeight, EquipmentConfig cfg) {
    for (final b in cfg.blocks) {
      if (b.perDumbbellSteps.contains(perDumbbellWeight)) return b.label;
    }
    return '';
  }

  /// §2.6 rule 1: display names the physical setup, including how many
  /// dumbbells are loaded, rather than presenting a two-DB total as though
  /// it were one dumbbell.
  ///
  /// When [setNumber] is provided for an uneven pair, the L/R assignment
  /// alternates: odd sets show L=lo/R=hi, even sets show L=hi/R=lo.
  String describeLoad(ResolvedLoad load, EquipmentConfig cfg, {int? setNumber}) {
    if (load.isSingleDb) {
      final block = _blockLabelFor(load.perDumbbellA, cfg);
      return '1 × ${_fmt(load.perDumbbellA)} lb ($block dumbbell)';
    }
    if (load.uneven) {
      final lo = math.min(load.perDumbbellA, load.perDumbbellB!);
      final hi = math.max(load.perDumbbellA, load.perDumbbellB!);
      final showLo = (setNumber == null || setNumber.isOdd) ? lo : hi;
      final showHi = (setNumber == null || setNumber.isOdd) ? hi : lo;
      return 'L: ${_fmt(showLo)} / R: ${_fmt(showHi)} '
          '(${_fmt(load.total)} lb total), swap after each set';
    }
    final block = _blockLabelFor(load.perDumbbellA, cfg);
    return '2 × ${_fmt(load.perDumbbellA)} lb '
        '(${_fmt(load.total)} lb total; $block pair)';
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
